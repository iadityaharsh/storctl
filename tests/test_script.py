"""Tests for the standalone curl-runnable shell script.

The script keeps per-mount ``.conf`` files as its source of truth, mirrors them
to ``state.json`` and regenerates a marked ``/etc/fstab`` block.  These tests
run it against a scratch root (``STORCTL_ROOT``) so nothing on the host is
touched.
"""

from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

try:
    import pexpect
except ImportError:  # pragma: no cover
    pexpect = None

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "storctl.sh"


class ScriptEnv(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "etc").mkdir(parents=True, exist_ok=True)
        (self.root / "etc" / "fstab").write_text(
            "/dev/sda1 / ext4 defaults 0 1\n", encoding="utf-8"
        )

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def run_script(self, *args: str, env: dict[str, str] | None = None):
        full_env = os.environ.copy()
        full_env.update(
            {
                "TERM": "xterm-256color",
                "LC_ALL": "C.UTF-8",
                "LANG": "C.UTF-8",
                "STORCTL_ROOT": str(self.root),
            }
        )
        if env:
            full_env.update(env)
        return subprocess.run(
            ["bash", str(SCRIPT), *args],
            cwd=str(ROOT),
            env=full_env,
            capture_output=True,
            text=True,
            timeout=60,
        )

    def source(self, body: str, extra_env: dict[str, str] | None = None):
        env = {
            **os.environ,
            "SCRIPT_FILE": str(SCRIPT),
            "STORCTL_ROOT": str(self.root),
            "LC_ALL": "C.UTF-8",
            "LANG": "C.UTF-8",
        }
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            ["bash", "-c", f'source "$SCRIPT_FILE"\n{body}'],
            cwd=str(ROOT),
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
        )


class SyntaxTests(ScriptEnv):
    def test_bash_syntax(self) -> None:
        proc = subprocess.run(
            ["bash", "-n", str(SCRIPT)], capture_output=True, text=True
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_version_and_help(self) -> None:
        version = self.run_script("--version")
        self.assertEqual(version.returncode, 0)
        self.assertIn("storctl", version.stdout)
        help_out = self.run_script("--help")
        self.assertEqual(help_out.returncode, 0)
        self.assertIn("--check", help_out.stdout)
        self.assertIn("curl", help_out.stdout)

    def test_check(self) -> None:
        proc = self.run_script("--check")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        for protocol in ("cifs", "nfs", "iscsi", "nvmeof"):
            self.assertIn(protocol, proc.stdout)
        self.assertIn("0 configured", proc.stdout)
        self.assertIn("managed     : no", proc.stdout)
        self.assertIn("settings    :", proc.stdout)
        self.assertIn("defaults    : smb=3.1.1 nfs=4.2 automount=boot", proc.stdout)
        self.assertIn("iSCSI       : port 3260, lun 0", proc.stdout)
        self.assertIn("NVMe-oF     : tcp, port 4420", proc.stdout)
        self.assertIn(f"creds dir   : {self.root}/etc/storctl/credentials", proc.stdout)

    def test_summary_without_mounts(self) -> None:
        proc = self.run_script("--summary")
        self.assertEqual(proc.returncode, 0)
        self.assertIn("Mounts: none configured", proc.stdout)

    def test_refuses_non_interactive(self) -> None:
        proc = self.run_script()
        self.assertEqual(proc.returncode, 2)
        self.assertIn("interactive terminal", proc.stderr)


class HelperTests(ScriptEnv):
    def test_slugify_and_unique_names(self) -> None:
        proc = self.source(
            'slugify "192.168.1.30"; echo\n'
            'slugify "My Share!"; echo\n'
            'mkdir -p "$MOUNTS_DIR"; : > "$MOUNTS_DIR/media.conf"\n'
            'unique_name "media"'
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip().splitlines(), ["192-168-1-30", "my-share", "media-2"])

    def test_filesystem_formatters(self) -> None:
        proc = self.source(
            "NAME=media-archive\n"
            'printf "%s|%s|%s|%s|%s|%s\\n" '
            '"$(format_tool ext4)" "$(format_tool btrfs)" '
            '"$(format_label ext4)" "$(format_label xfs)" '
            '"$(format_label vfat)" "$(format_label ntfs)"'
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(
            proc.stdout.strip(),
            "mkfs.ext4|mkfs.btrfs|media-archive|media-archiv|media-archi|media-archive",
        )

    def test_saved_credentials_loader(self) -> None:
        proc = self.source(
            'mkdir -p "$CREDS_DIR"\n'
            'printf "username=alice\\npassword=s3cret\\ndomain=LAB\\n" > "$CREDS_DIR/media.cred"\n'
            'load_cred_values "$CREDS_DIR/media.cred"\n'
            'printf "%s|%s|%s" "$SAVED_USERNAME" "$SAVED_PASSWORD" "$SAVED_DOMAIN"'
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), "alice|s3cret|LAB")

    def test_browse_parsers(self) -> None:
        proc = self.source(
            'printf "Sharename       Type      Comment\\n'
            '---------       ----      -------\\n'
            'media           Disk      Media library\\n'
            'IPC$            IPC       IPC Service\\n" | parse_smb_shares\n'
            'printf "Export list for nas:\\n'
            '/volume1/media *\\n'
            '/backup 10.0.0.0/24\\n" | parse_nfs_exports'
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(
            proc.stdout.strip().splitlines(),
            ["media", "/volume1/media", "/backup"],
        )

    def test_validators(self) -> None:
        proc = self.source(
            'v_host "bad host" && echo "host-ok" || echo "host:$VALIDATION_ERROR"\n'
            'v_host "192.168.1.5" && echo "ip-ok"\n'
            'v_mountpoint "relative" || echo "mp:$VALIDATION_ERROR"\n'
            'v_mountpoint "/mnt/x" && echo "mp-ok"\n'
            'v_name "Bad Name" || echo "name:$VALIDATION_ERROR"\n'
            'v_export "media" || echo "export:$VALIDATION_ERROR"\n'
            'v_creds_dir "/etc" || echo "creds:$VALIDATION_ERROR"\n'
            'v_creds_dir "/srv/creds" && echo "creds-ok"\n'
        )
        out = proc.stdout
        self.assertIn("host:no spaces or commas", out)
        self.assertIn("ip-ok", out)
        self.assertIn("mp:must be an absolute path", out)
        self.assertIn("mp-ok", out)
        self.assertIn("name:lowercase", out)
        self.assertIn("export:must start with /", out)
        self.assertIn("creds:choose a dedicated", out)
        self.assertIn("creds-ok", out)

    def test_fstab_lines(self) -> None:
        proc = self.source(
            "reset_mount_vars\n"
            "PROTOCOL=nfs NAME=media TARGET=/mnt/media SOURCE=nas.lan:/exports/media\n"
            "AUTOMOUNT=access READ_ONLY=0 EXTRA_OPTS=\n"
            "OPT_SERVER=nas.lan OPT_EXPORT=/exports/media OPT_VERS=4.2 OPT_PORT=\n"
            'build_fstab_line; echo\n'
            "reset_mount_vars\n"
            "PROTOCOL=cifs NAME=docs TARGET=/mnt/docs SOURCE=//nas/docs\n"
            "AUTOMOUNT=boot READ_ONLY=1 EXTRA_OPTS=noexec\n"
            "OPT_SERVER=nas OPT_SHARE=docs OPT_USERNAME=alice OPT_DOMAIN=LAB\n"
            "OPT_VERS=3.0 OPT_UID=1000 OPT_GID=1000 OPT_GUEST=0\n"
            'CRED_FILE=/etc/storctl/credentials/docs.cred\n'
            'build_fstab_line; echo\n'
        )
        lines = proc.stdout.strip().splitlines()
        self.assertEqual(
            lines[0],
            "nas.lan:/exports/media /mnt/media nfs4 "
            "hard,timeo=600,retrans=2,noatime,vers=4.2,rw,_netdev,nofail,"
            "x-systemd.automount,x-systemd.idle-timeout=60 0 0",
        )
        self.assertIn("credentials=/etc/storctl/credentials/docs.cred", lines[1])
        self.assertIn(",ro,_netdev,nofail,x-systemd.device-timeout=30s,noexec ", lines[1])


class PersistenceTests(ScriptEnv):
    def test_conf_state_fstab_roundtrip(self) -> None:
        proc = self.source(
            "reset_mount_vars\n"
            "PROTOCOL=nfs NAME=media TARGET=/mnt/media SOURCE=nas.lan:/exports/media\n"
            "AUTOMOUNT=boot READ_ONLY=0 EXTRA_OPTS=\n"
            "OPT_SERVER=nas.lan OPT_EXPORT=/exports/media OPT_VERS=4.2 OPT_PORT=\n"
            "write_conf\n"
            "reset_mount_vars\n"
            "PROTOCOL=cifs NAME=docs TARGET=/mnt/docs SOURCE=//nas/docs\n"
            "AUTOMOUNT=manual READ_ONLY=1 EXTRA_OPTS=\n"
            "OPT_SERVER=nas OPT_SHARE=docs OPT_USERNAME=alice OPT_DOMAIN=LAB\n"
            "OPT_VERS=3.0 OPT_UID=1000 OPT_GID=1000 OPT_GUEST=0\n"
            'CRED_FILE="$ROOT/etc/storctl/credentials/docs.cred"\n'
            "write_creds\n"
            'echo "CREDS_MODE=$(stat -c %a "$CRED_FILE")"\n'
            'cat "$CRED_FILE"\n'
            "write_conf\n"
            "sync_state\n"
            "sync_fstab\n"
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("CREDS_MODE=600", proc.stdout)
        self.assertIn("username=alice", proc.stdout)
        self.assertIn("password=", proc.stdout)

        creds = self.root / "etc" / "storctl" / "credentials" / "docs.cred"
        self.assertEqual(stat.S_IMODE(creds.stat().st_mode), 0o600)

        state = json.loads(
            (self.root / "etc" / "storctl" / "state.json").read_text()
        )
        names = {m["name"]: m for m in state["mounts"]}
        self.assertEqual(set(names), {"media", "docs"})
        self.assertEqual(names["docs"]["automount"], "manual")
        self.assertTrue(names["docs"]["read_only"])
        self.assertFalse(names["docs"]["options"]["guest"])
        self.assertEqual(names["docs"]["options"]["uid"], 1000)

        fstab = (self.root / "etc" / "fstab").read_text()
        self.assertIn("# >>> storctl managed block (do not edit) >>>", fstab)
        self.assertIn("# <<< storctl managed block <<<", fstab)
        self.assertIn("nas.lan:/exports/media /mnt/media nfs4", fstab)
        self.assertIn("//nas/docs /mnt/docs cifs", fstab)
        self.assertIn("noauto", fstab)
        self.assertTrue((self.root / "etc" / "fstab.storctl.bak").exists())

    def test_removing_conf_removes_fstab_entry(self) -> None:
        self.source(
            "reset_mount_vars\n"
            "PROTOCOL=nfs NAME=media TARGET=/mnt/media SOURCE=nas:/media\n"
            "AUTOMOUNT=boot READ_ONLY=0 EXTRA_OPTS=\n"
            "OPT_SERVER=nas OPT_EXPORT=/media OPT_VERS=4.2 OPT_PORT=\n"
            "write_conf; sync_state; sync_fstab\n"
        )
        fstab = self.root / "etc" / "fstab"
        self.assertIn("nas:/media", fstab.read_text())
        proc = self.source(
            'as_root rm -f "$(conf_file_for media)"; sync_state; sync_fstab'
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        text = fstab.read_text()
        self.assertNotIn("nas:/media", text)
        self.assertNotIn("storctl managed block", text)
        state = json.loads(
            (self.root / "etc" / "storctl" / "state.json").read_text()
        )
        self.assertEqual(state["mounts"], [])


class SettingsTests(ScriptEnv):
    def write_settings(self, text: str) -> Path:
        path = self.root / "etc" / "storctl" / "settings.conf"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def test_save_and_reload(self) -> None:
        proc = self.source(
            "SMB_VERSION=3.0\n"
            "NFS_VERSION=3\n"
            "ISCSI_PORT=3261\n"
            "ISCSI_LUN=2\n"
            "NVME_TRANSPORT=rdma\n"
            "NVME_PORT=4421\n"
            "DEFAULT_AUTOMOUNT=access\n"
            "MOUNT_ROOT=/srv\n"
            'CREDS_DIR="$ROOT/srv/creds"\n'
            "save_settings\n"
            'echo "file=$SETTINGS_FILE"\n'
            'cat "$SETTINGS_FILE"\n'
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("SMB_VERSION=3.0", proc.stdout)
        self.assertIn("NFS_VERSION=3", proc.stdout)
        self.assertIn("ISCSI_PORT=3261", proc.stdout)
        self.assertIn("ISCSI_LUN=2", proc.stdout)
        self.assertIn("NVME_TRANSPORT=rdma", proc.stdout)
        self.assertIn("NVME_PORT=4421", proc.stdout)
        self.assertIn("DEFAULT_AUTOMOUNT=access", proc.stdout)
        self.assertIn("MOUNT_ROOT=/srv", proc.stdout)
        self.assertIn("CREDS_DIR=", proc.stdout)

        reloaded = self.source(
            "printf '%s|%s|%s|%s|%s|%s|%s|%s|%s' \"$SMB_VERSION\" \"$NFS_VERSION\" "
            "\"$DEFAULT_AUTOMOUNT\" \"$MOUNT_ROOT\" \"$CREDS_DIR\" "
            "\"$ISCSI_PORT\" \"$ISCSI_LUN\" \"$NVME_TRANSPORT\" \"$NVME_PORT\""
        )
        self.assertEqual(reloaded.returncode, 0, reloaded.stderr)
        self.assertEqual(
            reloaded.stdout.strip(),
            f"3.0|3|access|/srv|{self.root}/srv/creds|3261|2|rdma|4421",
        )

    def test_invalid_values_fall_back_to_latest(self) -> None:
        self.write_settings(
            "SMB_VERSION=1.5\n"
            "NFS_VERSION=nope\n"
            "ISCSI_PORT=abc\n"
            "ISCSI_LUN=-1\n"
            "NVME_TRANSPORT=fc\n"
            "NVME_PORT=99999\n"
            "DEFAULT_AUTOMOUNT=whenever\n"
            "MOUNT_ROOT=relative\n"
            "CREDS_DIR=/\n"
            "UNKNOWN=1\n"
        )
        proc = self.source(
            "printf '%s|%s|%s|%s|%s|%s|%s|%s|%s' \"$SMB_VERSION\" \"$NFS_VERSION\" "
            "\"$DEFAULT_AUTOMOUNT\" \"$MOUNT_ROOT\" \"$CREDS_DIR\" "
            "\"$ISCSI_PORT\" \"$ISCSI_LUN\" \"$NVME_TRANSPORT\" \"$NVME_PORT\""
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(
            proc.stdout.strip(),
            f"3.1.1|4.2|boot|/mnt|{self.root}/etc/storctl/credentials|3260|0|tcp|4420",
        )

    def test_credentials_directory_is_used(self) -> None:
        proc = self.source(
            'CREDS_DIR="$ROOT/custom/creds"\n'
            "OPT_USERNAME=alice OPT_PASSWORD=s3cret OPT_DOMAIN=LAB\n"
            'CRED_FILE="$CREDS_DIR/docs.cred"\n'
            "write_creds\n"
            'echo "$CRED_FILE"\n'
            'stat -c %a "$CRED_FILE"'
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        cred = self.root / "custom" / "creds" / "docs.cred"
        self.assertTrue(cred.exists(), proc.stdout)
        self.assertEqual(stat.S_IMODE(cred.stat().st_mode), 0o600)
        self.assertIn("password=s3cret", cred.read_text())

    def test_settings_file_lives_in_home_by_default(self) -> None:
        proc = subprocess.run(
            ["bash", "-c", f'source "{SCRIPT}"; printf "%s" "$SETTINGS_FILE"'],
            cwd=str(ROOT),
            env={
                **os.environ,
                "HOME": str(self.root / "home"),
                "XDG_CONFIG_HOME": str(self.root / "home" / ".config"),
                "LC_ALL": "C.UTF-8",
                "LANG": "C.UTF-8",
            },
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(
            proc.stdout.strip(),
            str(self.root / "home" / ".config" / "storctl" / "settings.conf"),
        )

    def _without_root_env(self, home: Path, xdg: Path | None = None) -> dict[str, str]:
        env = {
            **os.environ,
            "HOME": str(home),
            "LC_ALL": "C.UTF-8",
            "LANG": "C.UTF-8",
        }
        env.pop("STORCTL_ROOT", None)
        env.pop("STORCTL_SETTINGS", None)
        if xdg is None:
            env.pop("XDG_CONFIG_HOME", None)
        else:
            env["XDG_CONFIG_HOME"] = str(xdg)
        return env

    def test_config_dir_defaults_to_home(self) -> None:
        home = self.root / "home"
        proc = subprocess.run(
            ["bash", "-c",
             f'source "{SCRIPT}"; printf "%s|%s|%s|%s" '
             '"$CONFIG_DIR" "$MOUNTS_DIR" "$STATE_FILE" "$SETTINGS_FILE"'],
            cwd=str(ROOT),
            env=self._without_root_env(home),
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        base = home / ".config" / "storctl"
        self.assertEqual(
            proc.stdout.strip(),
            f"{base}|{base}/mounts|{base}/state.json|{base}/settings.conf",
        )

    def test_config_dir_respects_xdg_config_home(self) -> None:
        home = self.root / "home"
        xdg = self.root / "xdg"
        proc = subprocess.run(
            ["bash", "-c", f'source "{SCRIPT}"; printf "%s|%s" "$CONFIG_DIR" "$SETTINGS_FILE"'],
            cwd=str(ROOT),
            env=self._without_root_env(home, xdg),
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        base = xdg / "storctl"
        self.assertEqual(proc.stdout.strip(), f"{base}|{base}/settings.conf")

    def test_config_dir_can_be_overridden_in_settings(self) -> None:
        home = self.root / "home"
        settings = home / ".config" / "storctl" / "settings.conf"
        settings.parent.mkdir(parents=True, exist_ok=True)
        custom = self.root / "srv" / "drive-config"
        settings.write_text(f"CONFIG_DIR={custom}\n", encoding="utf-8")
        proc = subprocess.run(
            ["bash", "-c",
             f'source "{SCRIPT}"; printf "%s|%s|%s|%s" '
             '"$CONFIG_DIR" "$MOUNTS_DIR" "$STATE_FILE" "$SETTINGS_FILE"'],
            cwd=str(ROOT),
            env=self._without_root_env(home),
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(
            proc.stdout.strip(),
            f"{custom}|{custom}/mounts|{custom}/state.json|{home}/.config/storctl/settings.conf",
        )

    def test_invalid_config_dir_falls_back_to_home(self) -> None:
        home = self.root / "home"
        settings = home / ".config" / "storctl" / "settings.conf"
        settings.parent.mkdir(parents=True, exist_ok=True)
        settings.write_text("CONFIG_DIR=/\n", encoding="utf-8")
        proc = subprocess.run(
            ["bash", "-c", f'source "{SCRIPT}"; printf "%s" "$CONFIG_DIR"'],
            cwd=str(ROOT),
            env=self._without_root_env(home),
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), str(home / ".config" / "storctl"))


class RollbackTests(ScriptEnv):
    def test_error_runs_registered_rollback(self) -> None:
        fakebin = self.root / "bin"
        fakebin.mkdir()
        log = self.root / "umount.log"
        umount = fakebin / "umount"
        umount.write_text(
            f'#!/bin/sh\necho "umount $*" >> "{log}"\nexit 0\n',
            encoding="utf-8",
        )
        umount.chmod(0o755)
        proc = self.source(
            "begin_apply\n"
            'register_rollback "umount|/mnt/test"\n'
            'register_rollback "rm-creds|$ROOT/etc/storctl/credentials/x.cred"\n'
            "false\n",
            extra_env={"PATH": f"{fakebin}:{os.environ['PATH']}"},
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("rolling back", proc.stderr)
        self.assertIn("umount /mnt/test", log.read_text())
        self.assertIn("setup failed", proc.stderr)


@unittest.skipIf(pexpect is None or shutil.which("whiptail") is None,
                 "pexpect and whiptail are required")
class InteractiveTests(ScriptEnv):
    def spawn(self):
        env = os.environ.copy()
        env.update(
            {
                "TERM": "xterm-256color",
                "LC_ALL": "C.UTF-8",
                "LANG": "C.UTF-8",
                "STORCTL_ROOT": str(self.root),
                "STORCTL_DRY_RUN": "1",
            }
        )
        child = pexpect.spawn(
            "bash",
            [str(SCRIPT)],
            cwd=str(ROOT),
            env=env,
            dimensions=(40, 120),
            timeout=25,
            encoding="utf-8",
            codec_errors="replace",
        )
        child.delaybeforesend = 0.02
        return child

    def test_cancel_returns_to_menu(self) -> None:
        child = self.spawn()
        try:
            child.expect("What do you want to do")
            child.send("\r")
            child.expect("Choose a protocol")
            child.send("\r")
            child.expect("Server name or IP address")
            child.send("\x1b")  # cancel the input box
            child.expect("What do you want to do")  # still alive
            child.send("\x1b[B" * 3 + "\r")  # quit
            child.expect("session summary")
            child.expect(pexpect.EOF)
        finally:
            child.close(force=True)
        self.assertEqual(child.exitstatus, 0)

    def test_main_menu_escape_stays_in_menu(self) -> None:
        child = self.spawn()
        try:
            child.expect("What do you want to do")
            child.send("\x1b")
            child.expect("What do you want to do")
            child.send("\x1b[B" * 3 + "\r")  # Exit
            child.expect("session summary")
            child.expect(pexpect.EOF)
        finally:
            child.close(force=True)
        self.assertEqual(child.exitstatus, 0)

    def test_cifs_back_navigates_step_by_step(self) -> None:
        child = self.spawn()
        try:
            child.expect("What do you want to do")
            child.send("\r")
            child.expect("Choose a protocol")
            child.send("\r")  # CIFS
            child.expect("Server name or IP address")
            child.send("192.168.1.50\r")
            child.expect("How does the server authenticate")
            child.send("\r")  # guest
            child.expect("Share name")
            child.send("\x1b")  # back to credentials
            child.expect("How does the server authenticate")
            child.send("\x1b")  # back to server
            child.expect("Server name or IP address")
            child.send("\x1b")  # back to main menu
            child.expect("What do you want to do")
            child.send("\x1b[B" * 3 + "\r")  # Exit
            child.expect("session summary")
            child.expect(pexpect.EOF)
        finally:
            child.close(force=True)
        self.assertEqual(child.exitstatus, 0)

    def test_options_persist_smb_default(self) -> None:
        child = self.spawn()
        try:
            child.expect("What do you want to do")
            child.send("\x1b[B\x1b[B\r")  # Options
            child.expect("Saved in:")
            child.send("\r")  # default SMB version
            child.expect("Used for new CIFS")
            child.send("\x1b[B\r")  # SMB 3.0
            child.expect("Default SMB version is now 3.0")
            child.send("\r")
            child.expect("Saved in:")
            child.send("\x1b")  # back to main menu
            child.expect("What do you want to do")
            child.send("\x1b[B" * 3 + "\r")  # quit
            child.expect("session summary")
            child.expect(pexpect.EOF)
        finally:
            child.close(force=True)
        self.assertEqual(child.exitstatus, 0)
        settings = (
            self.root / "etc" / "storctl" / "settings.conf"
        ).read_text()
        self.assertIn("SMB_VERSION=3.0", settings)
        self.assertIn("NFS_VERSION=4.2", settings)

    def test_saved_defaults_are_preselected(self) -> None:
        settings = self.root / "etc" / "storctl"
        settings.mkdir(parents=True, exist_ok=True)
        (settings / "settings.conf").write_text(
            "SMB_VERSION=3.0\n"
            "NFS_VERSION=3\n"
            "DEFAULT_AUTOMOUNT=access\n"
            "MOUNT_ROOT=/srv\n"
            f"CREDS_DIR={settings}/creds\n",
            encoding="utf-8",
        )
        child = self.spawn()
        try:
            child.expect("What do you want to do")
            child.send("\r")
            child.expect("Choose a protocol")
            child.send("\r")  # CIFS
            child.expect("Server name or IP address")
            child.send("192.168.1.50\r")
            child.expect("How does the server authenticate")
            child.send("\r")
            child.expect("Share name")
            child.send("media\r")
            child.expect("Short name for this mount")
            child.send("\r")
            child.expect("Directory to mount at")
            child.send("\r")  # saved mount root = /srv
            child.expect("When should this mount come back")
            child.send("\r")  # saved default = access
            child.expect("Mount this read-only")
            child.expect("Yes")
            child.send("\t\r")  # No
            child.expect("Additional mount options")
            child.send("\r")
            child.expect("Apply now")
            child.expect("/srv/media")
            child.expect("vers=3.0")
            child.send("\r")  # Yes
            child.expect("would be mounted at")
            child.expect("on first access")
            child.send("\r")
            child.expect("What do you want to do")
            child.send("\x1b[B" * 3 + "\r")
            child.expect("session summary")
            child.expect(pexpect.EOF)
        finally:
            child.close(force=True)
        self.assertEqual(child.exitstatus, 0)

    def test_cifs_dry_run(self) -> None:
        child = self.spawn()
        try:
            child.expect("What do you want to do")
            child.send("\r")
            child.expect("Choose a protocol")
            child.send("\r")  # CIFS is first
            child.expect("Server name or IP address")
            child.send("192.168.1.50\r")
            child.expect("How does the server authenticate")
            child.send("\r")  # guest
            child.expect("Share name")
            child.send("media\r")
            child.expect("Short name for this mount")
            child.send("\r")  # media
            child.expect("Directory to mount at")
            child.send("\r")  # /mnt/media
            child.expect("When should this mount come back")
            child.send("\r")  # at boot
            child.expect("Mount this read-only")
            child.expect("Yes")
            child.send("\t\r")  # No
            child.expect("Additional mount options")
            child.send("\r")
            child.expect("Apply now")
            child.send("\r")  # Yes
            child.expect("would be mounted at")
            child.send("\r")  # dismiss the success box
            child.expect("What do you want to do")
            child.send("\x1b[B" * 3 + "\r")  # quit
            child.expect("session summary")
            child.expect(pexpect.EOF)
        finally:
            child.close(force=True)
        self.assertEqual(child.exitstatus, 0)
        # dry-run must not persist anything
        self.assertFalse((self.root / "etc" / "storctl" / "state.json").exists())
        self.assertNotIn(
            "storctl managed block",
            (self.root / "etc" / "fstab").read_text(),
        )


if __name__ == "__main__":
    unittest.main()
