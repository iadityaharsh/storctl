---
description: "Install storctl on Linux: requirements, curl-runnable setup, and verification for Debian, Ubuntu, Fedora, Arch and openSUSE."
---

# Install storctl on Linux

**Quick answer:** there is nothing to install. `storctl` is one Bash script.
Run it from GitHub Pages:

```sh
bash -c "$(curl -fsSL https://iadityaharsh.github.io/storctl/storctl.sh)"
```

It uses your distribution's package manager only to install the protocol client
when you add a mount: `cifs-utils`, `nfs-common`/`nfs-utils`, `open-iscsi` or
`nvme-cli`.

## Base requirements

- Linux with `bash` 4.3+
- `whiptail`
- `util-linux` (`findmnt`, `lsblk`, `blkid`, `mount`)
- `systemd` for boot persistence
- `sudo` for privileged operations

On minimal systems:

```sh
# Debian / Ubuntu / Proxmox
sudo apt update && sudo apt install whiptail util-linux sudo

# Fedora / RHEL
sudo dnf install newt util-linux sudo

# Arch
sudo pacman -S libnewt util-linux sudo

# openSUSE
sudo zypper install newt util-linux sudo
```

## Run from a checkout

```sh
git clone https://github.com/iadityaharsh/storctl.git
cd storctl
chmod +x storctl.sh
./storctl.sh
```

## Verify

```sh
./storctl.sh --check
./storctl.sh --summary
./storctl.sh --version
```

`--check` prints the detected package manager, config paths, protocol
dependencies and configured mounts.

## Related

- [Mount an SMB/CIFS share on Linux](mount-smb-cifs-share-on-linux.md)
- [Mount an NFS export on Linux](mount-nfs-export-on-linux.md)
- [storctl README](index.md)
