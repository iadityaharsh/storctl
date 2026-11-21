---
description: "How to connect an NVMe-oF target over TCP or RDMA on Linux, mount the namespace and create a persistent systemd boot unit."
---

# How to connect an NVMe-oF target on Linux

**Quick answer:** install `nvme-cli`, discover the subsystem, connect over TCP
or RDMA, find the namespace, prepare a filesystem, mount it by UUID, and create
a systemd unit so the connection returns at boot. Or run one command and let
`storctl` do it:

```sh
bash -c "$(curl -fsSL https://iadityaharsh.github.io/storctl/storctl.sh)"
```

`storctl` discovers subsystems, connects, finds the namespace, prepares the
filesystem, mounts by UUID, writes a `storctl-nvmeof-<name>.service` unit and
adds `x-systemd.requires=` to the fstab entry so the mount waits for the
namespace.

## What you need

- An NVMe-oF target reachable over TCP (default port `4420`) or RDMA.
- The subsystem NQN, or discovery enabled on the target.
- The host NQN allowed in the target's ACL.
- Root or `sudo`.

## Manual method

### 1. Install nvme-cli

```sh
# Debian / Ubuntu / Proxmox
sudo apt update && sudo apt install nvme-cli

# Fedora / RHEL
sudo dnf install nvme-cli

# Arch
sudo pacman -S nvme-cli

# openSUSE
sudo zypper install nvme-cli
```

### 2. Discover subsystems

```sh
sudo nvme discover -t tcp -a 192.168.1.30 -s 4420
```

### 3. Connect

```sh
sudo nvme connect -t tcp -n nqn.2024-01.example:vol1 -a 192.168.1.30 -s 4420
```

### 4. Find the namespace

```sh
lsblk
ls -l /dev/disk/by-path/ | grep nvme
```

Typical path:

```text
/dev/disk/by-path/nvme-tcp-192.168.1.30:4420-nqn.2024-01.example:vol1
```

### 5. Check or create a filesystem

```sh
sudo blkid /dev/nvme0n1
```

Formatting is destructive; only do it on an empty namespace:

```sh
sudo mkfs.xfs -f -L storage /dev/nvme0n1
```

### 6. Mount by UUID

```sh
sudo blkid -s UUID -o value /dev/nvme0n1
sudo install -d -m 0755 /mnt/fast
sudo mount UUID=<uuid> /mnt/fast
```

### 7. Persist the connection and mount

Create `/etc/systemd/system/storctl-nvmeof-fast.service`:

```ini
[Unit]
Description=storctl NVMe-oF connect for fast
Documentation=man:nvme-connect(1)
After=network-online.target
Wants=network-online.target
Before=remote-fs-pre.target
Wants=remote-fs-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nvme connect -t tcp -n nqn.2024-01.example:vol1 -a 192.168.1.30 -s 4420
ExecStop=-/usr/sbin/nvme disconnect -n nqn.2024-01.example:vol1

[Install]
WantedBy=multi-user.target
```

Enable it:

```sh
sudo systemctl daemon-reload
sudo systemctl enable storctl-nvmeof-fast.service
```

fstab:

```fstab
UUID=<uuid> /mnt/fast xfs defaults,noatime,rw,_netdev,nofail,x-systemd.device-timeout=30s,x-systemd.requires=storctl-nvmeof-fast.service 0 0
```

## TCP or RDMA?

| Transport | When to use |
| --- | --- |
| `tcp` | default; works over normal Ethernet and routed networks |
| `rdma` | RoCE or InfiniBand; lower latency, requires RDMA-capable hardware |

## Common errors

| Error | Fix |
| --- | --- |
| `Failed to write to /dev/nvme-fabrics` | kernel module or permissions problem |
| `no subsystems found` | check the address, port, firewall and discovery configuration |
| `Connect failed` | check the NQN and the target ACL |
| `no namespace appeared` | check the subsystem's namespace configuration and `dmesg` |
| mount fails at boot | verify the unit is enabled and referenced by `x-systemd.requires=` |
| `target is busy` | close open files, or use a lazy unmount |

## Using storctl instead

Run the script and choose:

1. **Add storage**
2. **NVMe-oF**
3. Enter the target address and NQN (or leave empty to discover).
4. Choose the no-filesystem policy and ownership option.
5. Choose the mount point and boot behaviour.

The transport (TCP/RDMA) and port come from **Options → NVMe-oF defaults**.
Change them there before adding the mount if the target uses RDMA or a
non-default port.

Format policies are **ask**, **ext4**, **xfs**, **btrfs**, **f2fs**,
**FAT32/vfat**, **exFAT**, **NTFS** and **never format**. The matching `mkfs`
tool is installed on demand. Formatting requires typing `ERASE`; after it
finishes, `storctl` mounts the new filesystem immediately and persists it with
the selected boot mode. It also creates the boot unit and embeds it in the fstab
dependency, then verifies the mount.

## Related

- [Persist network mounts at boot](persist-network-mounts-at-boot.md)
- [Troubleshoot network mounts](troubleshooting-network-mounts.md)
- [storctl README](index.md)
