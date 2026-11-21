<div align="center">

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/storctl-logo-on-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/images/storctl-logo-on-light.svg">
    <img src="docs/images/storctl-logo-on-light.svg" alt="storctl" width="420">
  </picture>
</p>

# storctl

**Mount SMB/CIFS, NFS, iSCSI and NVMe-oF storage on Linux with one curl-runnable script.**

No install. No Python. No daemon. No binary.

[Quick start](#quick-start) · [Supported protocols](#supported-protocols) · [Documentation](https://iadityaharsh.github.io/storctl/) · [FAQ](#faq)

[![CI](https://github.com/iadityaharsh/storctl/actions/workflows/ci.yml/badge.svg)](https://github.com/iadityaharsh/storctl/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Bash 4.3+](https://img.shields.io/badge/bash-4.3%2B-4EAA25?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Platform: Linux](https://img.shields.io/badge/platform-Linux-FCC624?logo=linux&logoColor=black)](https://kernel.org/)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

</div>

`storctl` is a single Bash script for Linux that attaches network and fabric storage:
Windows/Samba shares (**SMB/CIFS**), **NFS** exports, **iSCSI** LUNs and **NVMe-oF**
namespaces. It detects and installs the client packages it needs, asks for the
connection details in `whiptail` dialogs, mounts and verifies the storage, then
persists it across reboots with `/etc/fstab` or `systemd`. Re-run the same
command to inspect, mount, unmount or remove it.

If you have searched for **how to mount an SMB share on Linux**, **mount NFS at
boot**, **connect an iSCSI target on Ubuntu**, or **connect NVMe-oF over TCP**,
`storctl` is the shortest path from a fresh machine to a working, persistent
mount.

## Quick start

Run the script straight from GitHub Pages:

```sh
bash -c "$(curl -fsSL https://iadityaharsh.github.io/storctl/storctl.sh)"
```

Then choose **Add storage**, pick a protocol and follow the prompts.

Run it from a checkout instead:

```sh
chmod +x storctl.sh
./storctl.sh
./storctl.sh --check
```

> `storctl` is a local root-level storage tool. Cloudflare Workers, containers
> and serverless platforms can serve the script, but they cannot run it — the
> mount happens on the Linux machine.

## Supported protocols

| Protocol | What it mounts | Package installed on demand | Default |
| --- | --- | --- | --- |
| **SMB / CIFS** | Windows shares, Samba, NAS appliances | `cifs-utils` (+ `smbclient` for share discovery) | SMB 3.1.1 |
| **NFS** | Unix exports from NAS boxes and Linux servers | `nfs-common` / `nfs-utils` | NFS 4.2 |
| **iSCSI** | Block storage from SAN/NAS targets | `open-iscsi` | protocol 1.0, port 3260 |
| **NVMe-oF** | NVMe over TCP or RDMA namespaces | `nvme-cli` | TCP, port 4420 |

Package installation works on **apt, dnf, pacman and zypper**, so the script
runs on Debian, Ubuntu, Fedora, Arch, openSUSE, Raspberry Pi OS, Proxmox VE and
other common Linux distributions.

## Filesystem formatting

If an iSCSI LUN or NVMe-oF namespace has no filesystem, the policy can be:

| Format | Tool installed on demand | Notes |
| --- | --- | --- |
| **ext4** | `e2fsprogs` | general-purpose Linux default |
| **xfs** | `xfsprogs` | large files, many writers |
| **btrfs** | `btrfs-progs` | snapshots and checksums |
| **f2fs** | `f2fs-tools` | flash-friendly |
| **FAT32 (vfat)** | `dosfstools` | cross-platform, 4 GB file limit |
| **exFAT** | `exfatprogs` | large files, cross-platform |
| **NTFS** | `ntfs-3g` | Windows compatibility |

The default policy is **Ask me at mount time**. Formatting always requires
typing `ERASE`. After formatting, `storctl` detects the new UUID, mounts the
filesystem immediately and persists it with the selected boot mode. Existing
filesystems are mounted without formatting.

`storctl` does not create partition tables, LVM volumes, RAID arrays, swap or
ZFS pools; those are separate device-management operations.

## What `storctl` does

1. **Checks privileges** — asks for sudo once, then runs privileged commands
   non-interactively. Nothing is stored on disk.
2. **Validates input** — host, share/export, IQN/NQN, mount point and names are
   checked in the dialogs themselves. For SMB, you can reuse a saved
   credential, enter a new one, or connect as guest.
3. **Installs missing dependencies** — with confirmation, using the native
   package manager, and lists SMB shares or NFS exports for selection when the
   server allows it.
4. **Mounts live** — creates the mount point, connects iSCSI/NVMe-oF targets,
   prepares the filesystem if needed, mounts, then verifies with `findmnt`.
5. **Persists** — writes a per-mount config, syncs `state.json`, adds an entry
   to a marked block in `/etc/fstab`, and enables the boot mechanism:
   - **at boot** — fstab entry with `nofail` and a 30 s device timeout
   - **on first access** — `x-systemd.automount` with a 60 s idle timeout
   - **manual only** — `noauto`
6. **Rolls back on failure** — unmounts, disconnects targets, removes partial
   credentials, units and configuration.

The terminal UI uses a dark `whiptail` theme with orange borders and title bars,
orange highlighted menu rows, high-contrast focused buttons, and a large
`storctl` banner in the session summary.

Formatting is **never automatic**. If a LUN or namespace has no filesystem you
must choose ext4 or xfs **and** type `ERASE` to confirm.

## Common use cases

- Mount a **Synology, TrueNAS, Unraid, QNAP or Windows/Samba share** on Ubuntu,
  Debian, Fedora, Arch or Raspberry Pi OS.
- Add **NFS storage to Proxmox VE**, a home server, a media server or a backup
  host.
- Connect an **iSCSI LUN** to a Linux server or homelab node.
- Attach an **NVMe-oF TCP/RDMA namespace** for low-latency block storage.
- Keep mounts persistent across reboots without hand-editing `/etc/fstab`.
- Troubleshoot `mount error(13)`, `mount error(2)`, `target is busy`, NFS boot
  hangs and SMB dialect failures.

## Commands

```sh
./storctl.sh                 # interactive menu
./storctl.sh --check         # environment, packages, mounts, preferences
./storctl.sh --summary       # current mounts and fstab lines
./storctl.sh --dry-run       # interactive, but runs no commands
./storctl.sh --version
./storctl.sh --help
```

With the `curl` form, pass flags after a placeholder name:

```sh
bash -c "$(curl -fsSL https://iadityaharsh.github.io/storctl/storctl.sh)" _ --check
```

## Configuration

`storctl` keeps user config in your home directory and only touches system
files where it must (`/etc/fstab`, credentials, systemd units).

| Path | Purpose |
| --- | --- |
| `~/.config/storctl/settings.conf` | user preferences |
| `~/.config/storctl/mounts/<name>.conf` | source of truth for each mount |
| `~/.config/storctl/state.json` | mirrored, human-readable mount definitions |
| `/etc/storctl/credentials/<name>.cred` | SMB password file, mode 0600 |
| `/etc/fstab` | one managed block, regenerated on every change |
| `/etc/fstab.storctl.bak` | one-time backup of the original fstab |
| `/etc/systemd/system/storctl-nvmeof-<name>.service` | NVMe-oF boot unit |

The config directory is configurable in **Options → Config directory**; changing
it moves existing definitions. SMB passwords never appear in `state.json` or
`/etc/fstab`.

### Preferences

| Setting | Default | Used for |
| --- | --- | --- |
| `SMB_VERSION` | `3.1.1` | default SMB dialect |
| `NFS_VERSION` | `4.2` | default NFS version |
| `ISCSI_PORT` | `3260` | default iSCSI portal port |
| `ISCSI_LUN` | `0` | default iSCSI LUN |
| `NVME_TRANSPORT` | `tcp` | default NVMe-oF transport |
| `NVME_PORT` | `4420` | default NVMe-oF port |
| `DEFAULT_AUTOMOUNT` | `boot` | preselected boot behaviour |
| `MOUNT_ROOT` | `/mnt` | default parent for mount points |
| `CONFIG_DIR` | `~/.config/storctl` | mount definitions and state |
| `CREDS_DIR` | `/etc/storctl/credentials` | SMB credential files |

New mounts use these saved defaults automatically. The add wizard does **not**
prompt for protocol version, transport, port or LUN; change those in **Options**
first if the target needs something different.

### Environment variables

Mostly useful for testing and automation:

| Variable | Effect |
| --- | --- |
| `STORCTL_ROOT=/dir` | relocate every system path under `/dir` |
| `STORCTL_DRY_RUN=1` | log commands instead of running them |
| `STORCTL_SETTINGS=/path` | use a specific settings file |

## Safety

- No binary, daemon, service or setuid helper is installed.
- No automatic formatting; `ERASE` confirmation is required.
- fstab is edited only inside the `storctl` managed block.
- The original fstab is backed up once before the first change.
- Credentials are root-owned and mode `0600`.
- Rollback removes partial configuration when a setup step fails.
- Removing a mount never touches data on the server.

## Troubleshooting

Run `--check` first. Common errors and their usual causes:

| Error | Likely cause |
| --- | --- |
| `mount error(13)` / `access denied` | wrong SMB credentials or share permissions |
| `mount error(2)` / `not exported` | wrong share or export name |
| `Connection refused` / `timed out` | service down, wrong port or firewall |
| `target is busy` | files still open; `storctl` offers a lazy unmount |
| `wrong fs type` / `bad option` | kernel module or mount helper missing |
| `unsupported dialect` | server does not speak the selected SMB version; set 3.0 or 2.1 in Options |
| iSCSI/NVMe CHAP or login errors | credentials or target ACL |

NFS access is controlled by the server's export rules (client IP), not a
password. For iSCSI and NVMe-oF, add the initiator to the target's ACL.

See [docs/troubleshooting-network-mounts.md](https://iadityaharsh.github.io/storctl/troubleshooting-network-mounts/)
for detailed fixes.

## FAQ

### Is `storctl` a GUI?

It is a terminal UI built with `whiptail`, so it works over SSH and on servers
without a desktop. It is not a graphical file manager.

### Do I need to install anything first?

Only the base tools: `bash` 4.3+, `whiptail`, `util-linux` and `sudo`. `storctl`
installs the protocol client package (`cifs-utils`, `nfs-common`, `open-iscsi`
or `nvme-cli`) when you add the first mount of that type.

### Does it work on Ubuntu, Debian, Fedora, Arch and openSUSE?

Yes. Package installation supports apt, dnf, pacman and zypper. It also works on
Raspberry Pi OS, Proxmox VE and other systemd-based Linux distributions.

### Does it work with Synology, TrueNAS, Unraid, QNAP and Windows shares?

Yes, as long as the target speaks standard SMB/CIFS, NFS, iSCSI or NVMe-oF.

### Will it format my disks?

Only if you explicitly choose a filesystem **and** type `ERASE`. Supported
formats are ext4, xfs, btrfs, f2fs, FAT32/vfat, exFAT and NTFS. The default
policy is to ask. After formatting, the new filesystem is mounted immediately
and persisted with the selected boot mode.

### Where are my mount definitions stored?

In `~/.config/storctl/mounts/` by default, mirrored to
`~/.config/storctl/state.json`. You can change the directory in Options.

### Is there an apt package?

Not required. The script is the distribution: one file, no install step, no
version drift between a package and the script. Your package manager is only
used to install the protocol clients.

### Can I use it non-interactively?

`--check`, `--summary`, `--dry-run`, `--version` and `--help` are scriptable.
The add/manage workflows are interactive by design because they edit fstab and
credentials.

### Does it work in containers or on serverless platforms?

Only with the privileges needed to mount filesystems and edit `/etc/fstab`.
Unprivileged containers and serverless runtimes cannot use it.

## Documentation

**Live docs:** <https://iadityaharsh.github.io/storctl/>

- [Install storctl on Linux](https://iadityaharsh.github.io/storctl/install-storctl/)
- [Mount an SMB/CIFS share on Linux](https://iadityaharsh.github.io/storctl/mount-smb-cifs-share-on-linux/)
- [Mount an NFS export on Linux](https://iadityaharsh.github.io/storctl/mount-nfs-export-on-linux/)
- [Connect an iSCSI target on Linux](https://iadityaharsh.github.io/storctl/connect-iscsi-target-on-linux/)
- [Connect an NVMe-oF target on Linux](https://iadityaharsh.github.io/storctl/connect-nvme-of-target-on-linux/)
- [Persist network mounts at boot](https://iadityaharsh.github.io/storctl/persist-network-mounts-at-boot/)
- [Troubleshoot network mounts](https://iadityaharsh.github.io/storctl/troubleshooting-network-mounts/)
- [Comparison: storctl vs fstab vs autofs vs systemd](https://iadityaharsh.github.io/storctl/comparison/)
- [FAQ](https://iadityaharsh.github.io/storctl/faq/)
- [Full documentation index](https://iadityaharsh.github.io/storctl/)

## Contributing

Bug reports and feature requests are welcome via
[GitHub Issues](https://github.com/iadityaharsh/storctl/issues). See
[CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

## License

MIT — see [LICENSE](LICENSE).
