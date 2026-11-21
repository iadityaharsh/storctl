---
description: "Persist network mounts at boot on Linux with fstab, nofail, x-systemd.automount, x-systemd.requires and managed storctl blocks."
---

# Persist network mounts at boot on Linux

A mount that works until reboot is not finished. `storctl` gives every mount the
same three-way boot choice and generates the correct fstab/systemd options.

## The three modes

| Mode | fstab options | Behaviour |
| --- | --- | --- |
| **At boot** | `_netdev,nofail,x-systemd.device-timeout=30s` | normal fstab mount, systemd waits up to 30 s for the device |
| **On first access** | `_netdev,nofail,x-systemd.automount,x-systemd.idle-timeout=60` | systemd mounts on first access and unmounts after 60 s idle |
| **Manual only** | `_netdev,noauto` | never mounted automatically; use `mount /mnt/name` |

`storctl` also adds protocol-specific options such as `credentials=`, `vers=`,
`hard`, `timeo`, `retrans`, `noatime` and `x-systemd.requires=` for NVMe-oF.

## Why `nofail` matters

Without `nofail`, a missing server or a slow network can delay or block the boot
process. `nofail` tells systemd to continue even if the mount cannot be
completed.

`x-systemd.device-timeout=30s` caps how long systemd waits for the device to
appear.

## Why `x-systemd.automount` matters

`x-systemd.automount` is useful for laptops, workstations and homelab machines
that are not always on the same network. The mount happens when a process first
accesses the directory, and the idle timeout unmounts it later.

For remote filesystems, combine it with `_netdev` and `nofail`.

## fstab examples

### SMB/CIFS at boot

```fstab
//nas.local/media /mnt/media cifs credentials=/etc/storctl/credentials/media.cred,uid=1000,gid=1000,vers=3.1.1,iocharset=utf8,rw,_netdev,nofail,x-systemd.device-timeout=30s 0 0
```

### NFS on first access

```fstab
nas.local:/volume1/media /mnt/media nfs4 hard,timeo=600,retrans=2,noatime,vers=4.2,rw,_netdev,nofail,x-systemd.automount,x-systemd.idle-timeout=60 0 0
```

### iSCSI by UUID

```fstab
UUID=<uuid> /mnt/storage ext4 defaults,noatime,rw,_netdev,nofail,x-systemd.device-timeout=30s 0 0
```

### NVMe-oF by UUID

```fstab
UUID=<uuid> /mnt/fast xfs defaults,noatime,rw,_netdev,nofail,x-systemd.device-timeout=30s,x-systemd.requires=storctl-nvmeof-fast.service 0 0
```

## The managed block

`storctl` edits only one block in `/etc/fstab`:

```fstab
# >>> storctl managed block (do not edit) >>>
# media
//nas.local/media /mnt/media cifs ... 0 0
# <<< storctl managed block <<<
```

Everything outside the block is preserved. The original fstab is backed up once
to `/etc/fstab.storctl.bak` before the first change.

## Verify after reboot

```sh
findmnt -rn -o SOURCE,FSTYPE,TARGET -M /mnt/media
systemctl status mnt-media.mount
journalctl -b -u mnt-media.mount
```

## Using storctl

Choose the boot mode in the mount wizard, or change it by removing and
re-adding the mount. `storctl --summary` shows the generated fstab line for each
mount.

## Related

- [Troubleshoot network mounts](troubleshooting-network-mounts.md)
- [Comparison: storctl vs fstab vs autofs vs systemd](comparison.md)
- [storctl README](index.md)
