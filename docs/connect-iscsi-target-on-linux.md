---
description: "How to connect an iSCSI target on Linux: discovery, CHAP, LUN lookup, filesystem preparation, UUID mounts and automatic login."
---

# How to connect an iSCSI target on Linux

**Quick answer:** install `open-iscsi`, discover the portal, log in, find the
LUN under `/dev/disk/by-path`, format it if necessary, mount it by UUID, and set
`node.startup=automatic` so `iscsid` logs in at boot. Or run one command and let
`storctl` do it:

```sh
bash -c "$(curl -fsSL https://iadityaharsh.github.io/storctl/storctl.sh)"
```

`storctl` starts `iscsid`, discovers targets, configures CHAP if needed, logs
in, finds the LUN, prepares the filesystem, mounts by UUID, enables automatic
login and records the mount in the managed fstab block.

## What you need

- An iSCSI target portal (IP or hostname) and usually port `3260`.
- The target IQN, or discovery enabled on the portal.
- CHAP credentials if the target requires them.
- The initiator must be allowed in the target's ACL.
- Root or `sudo`.

## Manual method

### 1. Install and start open-iscsi

```sh
# Debian / Ubuntu / Proxmox
sudo apt update && sudo apt install open-iscsi
sudo systemctl enable --now iscsid

# Fedora / RHEL
sudo dnf install iscsi-initiator-utils
sudo systemctl enable --now iscsid

# Arch
sudo pacman -S open-iscsi
sudo systemctl enable --now iscsid

# openSUSE
sudo zypper install open-iscsi
sudo systemctl enable --now iscsid
```

### 2. Discover targets

```sh
sudo iscsiadm -m discovery -t sendtargets -p 192.168.1.20:3260
```

### 3. Log in

```sh
sudo iscsiadm -m node -T iqn.2024-01.example:storage -p 192.168.1.20:3260 --login
```

### 4. Find the block device

```sh
lsblk
ls -l /dev/disk/by-path/ | grep iscsi
```

Typical path:

```text
/dev/disk/by-path/ip-192.168.1.20:3260-iscsi-iqn.2024-01.example:storage-lun-0
```

### 5. Check or create a filesystem

```sh
sudo blkid /dev/sdb
```

If the device is blank, formatting is destructive:

```sh
# Only after confirming the device is empty
sudo mkfs.ext4 -L storage /dev/sdb
```

### 6. Mount by UUID

```sh
sudo blkid -s UUID -o value /dev/sdb
sudo install -d -m 0755 /mnt/storage
sudo mount UUID=<uuid> /mnt/storage
```

### 7. Make it persistent

fstab:

```fstab
UUID=<uuid> /mnt/storage ext4 defaults,noatime,rw,_netdev,nofail,x-systemd.device-timeout=30s 0 0
```

Automatic login at boot:

```sh
sudo iscsiadm -m node -T iqn.2024-01.example:storage -p 192.168.1.20:3260 \
  -o update -n node.startup -v automatic
```

## CHAP

```sh
sudo iscsiadm -m node -T <iqn> -p <portal> -o new
sudo iscsiadm -m node -T <iqn> -p <portal> -o update \
  -n node.session.auth.authmethod -v CHAP
sudo iscsiadm -m node -T <iqn> -p <portal> -o update \
  -n node.session.auth.username -v <user>
sudo iscsiadm -m node -T <iqn> -p <portal> -o update \
  -n node.session.auth.password -v <secret>
```

## Common errors

| Error | Fix |
| --- | --- |
| `iscsiadm: No portals found` | check the portal address, port and firewall |
| `authorization failure` | wrong CHAP username or secret |
| `no block device appeared` | check the LUN mapping and `dmesg` |
| `wrong fs type` | format the LUN or mount the correct partition |
| `target is busy` | close open files, or use a lazy unmount |
| login fails after reboot | ensure `iscsid` is enabled and `node.startup=automatic` |

## Using storctl instead

Run the script and choose:

1. **Add storage**
2. **iSCSI**
3. Enter the portal and IQN (or leave empty to discover).
4. Add CHAP if required.
5. Choose the no-filesystem policy and ownership option.
6. Choose the mount point and boot behaviour.

The portal port and LUN come from **Options → iSCSI defaults**. Change them
there before adding the mount if the target uses a different port or LUN.

Format policies are **ask**, **ext4**, **xfs**, **btrfs**, **f2fs**,
**FAT32/vfat**, **exFAT**, **NTFS** and **never format**. The matching `mkfs`
tool is installed on demand. Formatting requires typing `ERASE`; after it
finishes, `storctl` mounts the new filesystem immediately and persists it with
the selected boot mode. It mounts by UUID and enables automatic login.

## Related

- [Persist network mounts at boot](persist-network-mounts-at-boot.md)
- [Troubleshoot network mounts](troubleshooting-network-mounts.md)
- [storctl README](index.md)
