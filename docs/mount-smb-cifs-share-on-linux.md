---
description: "How to mount an SMB/CIFS share on Linux manually or with storctl, including credentials, fstab persistence and troubleshooting."
---

# How to mount an SMB/CIFS share on Linux

**Quick answer:** install `cifs-utils`, mount with `mount -t cifs`, then add a
credentials file and an `/etc/fstab` entry to make it persistent. Or run one
command and let `storctl` do all of it:

```sh
bash -c "$(curl -fsSL https://iadityaharsh.github.io/storctl/storctl.sh)"
```

`storctl` installs `cifs-utils`, asks for the server and credentials, lists the
available disk shares with `smbclient` when possible, mounts and verifies the
selected share, writes the credential file with mode `0600`, and records a
managed `/etc/fstab` entry. It works on Ubuntu, Debian, Fedora, Arch, openSUSE,
Raspberry Pi OS and Proxmox VE.

## What you need

- A reachable SMB server: Windows, Samba, Synology, TrueNAS, Unraid, QNAP or
  another standards-compliant SMB target.
- The server name or IP, the share name, and credentials if the share is not
  guest-accessible.
- `cifs-utils` on the client (the package that provides `mount.cifs`).
- Root or `sudo`.

## Manual method

### 1. Install the client

```sh
# Debian / Ubuntu / Proxmox
sudo apt update && sudo apt install cifs-utils

# Fedora / RHEL
sudo dnf install cifs-utils

# Arch
sudo pacman -S cifs-utils

# openSUSE
sudo zypper install cifs-utils
```

### 2. Create a credentials file

```sh
sudo install -d -m 0700 /etc/storctl/credentials
sudo install -m 0600 /dev/null /etc/storctl/credentials/media.cred
sudo tee /etc/storctl/credentials/media.cred >/dev/null <<'EOF'
username=alice
password=your-password
domain=WORKGROUP
EOF
```

### 3. Mount the share

```sh
sudo install -d -m 0755 /mnt/media
sudo mount -t cifs //nas.local/media /mnt/media \
  -o credentials=/etc/storctl/credentials/media.cred,uid=1000,gid=1000,vers=3.1.1,iocharset=utf8
```

Verify:

```sh
findmnt -rn -o SOURCE,FSTYPE,TARGET -M /mnt/media
```

### 4. Make it persistent

Add one line to `/etc/fstab`:

```fstab
//nas.local/media /mnt/media cifs credentials=/etc/storctl/credentials/media.cred,uid=1000,gid=1000,vers=3.1.1,iocharset=utf8,rw,_netdev,nofail,x-systemd.device-timeout=30s 0 0
```

Then:

```sh
sudo systemctl daemon-reload
sudo mount /mnt/media
```

## SMB dialect notes

| Version | When to use |
| --- | --- |
| `3.1.1` | default; modern servers, AES-GCM and pre-auth integrity |
| `3.0` | widest compatibility with older NAS appliances |
| `2.1` | very old NAS or legacy Samba |
| `1.0` | legacy only; insecure, avoid if possible |

The CIFS client does not negotiate downwards automatically. If the server
rejects the selected dialect, mount again and choose a lower version.

## Common errors

| Error | Fix |
| --- | --- |
| `mount error(13): Permission denied` | check username, password, domain and share permissions |
| `mount error(2): No such file or directory` | check the share name and the server path |
| `mount error(6)` / `could not resolve` | use an IP address or fix DNS |
| `unsupported dialect` | set SMB 3.0 or 2.1 in **Options → Default SMB version** |
| `wrong fs type` / `bad option` | install `cifs-utils` and load the `cifs` kernel module |
| `target is busy` | close open files, or use a lazy unmount |

## Using storctl instead

Run the script and choose:

1. **Add storage**
2. **SMB / CIFS**
3. Enter the server.
4. Choose a saved credential, enter new credentials, or connect as guest.
5. Select a discovered share, or enter the share name manually.
6. Choose the mount point and boot behaviour.

The SMB dialect comes from **Options → Default SMB version**. If a server needs
an older dialect, change it there before adding the mount.

`storctl` handles the credentials file, fstab block, verification and rollback.
Re-run the same command to manage the mount later.

## Related

- [Persist network mounts at boot](persist-network-mounts-at-boot.md)
- [Troubleshoot network mounts](troubleshooting-network-mounts.md)
- [storctl README](index.md)
