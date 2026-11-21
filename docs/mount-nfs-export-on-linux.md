---
description: "How to mount an NFS export on Linux with NFSv4.2/4.1/4.0 or v3, fstab persistence and common error fixes."
---

# How to mount an NFS export on Linux

**Quick answer:** install the NFS client, mount with `mount -t nfs4`, then add
an `/etc/fstab` entry. Or run one command and let `storctl` do it:

```sh
bash -c "$(curl -fsSL https://iadityaharsh.github.io/storctl/storctl.sh)"
```

`storctl` installs `nfs-common` or `nfs-utils`, asks for the server, lists the
available exports with `showmount` when possible, mounts and verifies the
selected export, and records a managed `/etc/fstab` entry with boot-safe
options. It works on Ubuntu, Debian, Fedora, Arch, openSUSE, Raspberry Pi OS and
Proxmox VE.

## What you need

- A reachable NFS server (Linux, NAS, TrueNAS, Synology, Unraid, QNAP, etc.).
- The export path, for example `/volume1/media`.
- The server must allow your client IP in its export rules.
- Root or `sudo`.

NFS does not use a password. Access is controlled by the server's export
configuration and client IP.

## Manual method

### 1. Install the client

```sh
# Debian / Ubuntu / Proxmox
sudo apt update && sudo apt install nfs-common

# Fedora / RHEL
sudo dnf install nfs-utils

# Arch
sudo pacman -S nfs-utils

# openSUSE
sudo zypper install nfs-client
```

### 2. Create the mount point

```sh
sudo install -d -m 0755 /mnt/media
```

### 3. Mount the export

```sh
sudo mount -t nfs4 nas.local:/volume1/media /mnt/media \
  -o vers=4.2,hard,timeo=600,retrans=2,noatime
```

Verify:

```sh
findmnt -rn -o SOURCE,FSTYPE,TARGET -M /mnt/media
```

### 4. Make it persistent

```fstab
nas.local:/volume1/media /mnt/media nfs4 hard,timeo=600,retrans=2,noatime,vers=4.2,rw,_netdev,nofail,x-systemd.device-timeout=30s 0 0
```

Then:

```sh
sudo systemctl daemon-reload
sudo mount /mnt/media
```

For an on-demand mount instead of a boot mount, replace `nofail` and
`x-systemd.device-timeout` with:

```fstab
x-systemd.automount,x-systemd.idle-timeout=60
```

## NFS version notes

| Version | Notes |
| --- | --- |
| `4.2` | default; latest features, best choice on modern servers |
| `4.1` | widely supported; useful on older NAS firmware |
| `4.0` | legacy NFSv4 |
| `3` | legacy; uses `nfs` instead of `nfs4`, may need `rpcbind` |

Optional port:

```sh
sudo mount -t nfs4 nas.local:/export /mnt/media -o vers=4.2,port=2049
```

## Common errors

| Error | Fix |
| --- | --- |
| `access denied by server` | add the client IP to the server's export rules |
| `No such file or directory` | check the export path on the server |
| `Connection refused` | NFS service is down or blocked by a firewall |
| boot hangs waiting for NFS | use `nofail` and `x-systemd.device-timeout`, or `x-systemd.automount` |
| `wrong fs type` | install the NFS client package |
| `target is busy` | close open files, or use a lazy unmount |

## Using storctl instead

Run the script and choose:

1. **Add storage**
2. **NFS**
3. Enter the server.
4. Select a discovered export, or enter the export path manually.
5. Choose the mount point and boot behaviour.

The NFS version comes from **Options → Default NFS version**. Change it there
before adding the mount if the server needs an older version.

`storctl` handles verification, fstab persistence and rollback. Re-run the same
command to inspect, mount, unmount or remove the export.

## Related

- [Persist network mounts at boot](persist-network-mounts-at-boot.md)
- [Troubleshoot network mounts](troubleshooting-network-mounts.md)
- [storctl README](index.md)
