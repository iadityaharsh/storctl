---
description: "storctl FAQ: supported Linux distributions, protocols, filesystems, configuration, safety and how to remove a mount."
---

# storctl FAQ

## What is storctl?

`storctl` is a single Bash script that mounts SMB/CIFS, NFS, iSCSI and NVMe-oF
storage on Linux, verifies it, and makes it persistent across reboots.

## Is it a GUI?

No. It is a terminal UI built with `whiptail`. It works over SSH and on servers
without a desktop.

## Do I need Python?

No. The script only needs Bash, `whiptail`, `util-linux`, `systemd` and `sudo`.
Python is only used by the development test suite.

## Do I need to install a package?

No `storctl` package is required. Run the script from GitHub. It uses your
distribution's package manager only to install the protocol client
(`cifs-utils`, `nfs-common`, `open-iscsi` or `nvme-cli`) when needed.

## Which distributions are supported?

Any Linux with Bash 4.3+, `whiptail`, `util-linux` and `systemd`, including
Debian, Ubuntu, Fedora, Arch, openSUSE, Raspberry Pi OS and Proxmox VE.
Package installation supports apt, dnf, pacman and zypper.

## Does it work with Synology, TrueNAS, Unraid, QNAP and Windows shares?

Yes, if the target speaks standard SMB/CIFS, NFS, iSCSI or NVMe-oF.

## Does it format disks?

Only when you explicitly choose a filesystem **and** type `ERASE`. Supported
formats are ext4, xfs, btrfs, f2fs, FAT32/vfat, exFAT and NTFS. The default is
to ask. Formatting destroys data, so the confirmation is intentionally strict.
After formatting, `storctl` mounts the new filesystem immediately and persists
it with the selected boot mode.

## Can I reuse saved SMB credentials?

Yes. When adding an SMB mount, the authentication menu lists previously saved
credentials by username and domain. You can reuse one, enter new credentials,
or connect as guest. Passwords are never displayed.

## Where does it store configuration?

By default:

- `~/.config/storctl/settings.conf`
- `~/.config/storctl/mounts/<name>.conf`
- `~/.config/storctl/state.json`

Credentials are in `/etc/storctl/credentials/<name>.cred`, mode `0600`. System
mount configuration is in `/etc/fstab` inside the managed block.

## Does it store SMB passwords in fstab or state.json?

No. fstab references a separate credentials file, and `state.json` contains only
non-secret definitions.

## Can I change the config or credentials directory?

Yes. Use **Options → Config directory** or **Options → Credentials**. Changing
the config directory moves existing mount definitions so they are not orphaned.

## How do I remove a mount?

Run the script again, choose **Manage existing mounts**, select the mount and
choose **Remove completely**. This unmounts, logs out/disconnects, removes the
fstab entry, credentials and boot unit. Data on the server is not touched.

## Can I use it non-interactively?

`--check`, `--summary`, `--dry-run`, `--version` and `--help` are scriptable.
Adding and removing mounts is interactive because it edits system files and
handles credentials.

## Does it work in Docker, LXC or serverless?

Only with the privileges required to mount filesystems and edit `/etc/fstab`.
Unprivileged containers and serverless platforms cannot use it. Cloudflare
Workers can host the script file but cannot run it.

## How is it different from autofs?

`autofs` is a daemon for large-scale on-demand maps. `storctl` is a setup and
management tool that generates fstab/systemd configuration. For many mounts and
central maps, use autofs; for a handful of mounts, `storctl` is simpler.

## How is it different from editing fstab manually?

`storctl` validates inputs, installs dependencies, verifies the mount, backs up
fstab once, isolates its edits in a managed block and rolls back on failure. You
can still inspect and edit the result.

## How do I report a bug or request a feature?

Open an issue on [GitHub](https://github.com/iadityaharsh/storctl/issues) with
your distribution, protocol, the command or menu path you used, and the error
output. Remove passwords and CHAP secrets before posting.
