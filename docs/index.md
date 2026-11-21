---
description: "storctl documentation: mount SMB/CIFS, NFS, iSCSI and NVMe-oF storage on Linux with one curl-runnable Bash script."
---

<p align="center" class="storctl-hero">
  <img class="storctl-logo-on-light" src="images/storctl-logo-on-light.svg" alt="storctl">
  <img class="storctl-logo-on-dark" src="images/storctl-logo-on-dark.svg" alt="storctl">
</p>

# storctl documentation

Practical guides for mounting and persisting storage on Linux with `storctl`
and with standard Linux tools.

## Getting started

- [Install storctl on Linux](install-storctl.md) — requirements and the
  curl-runnable workflow.

## Protocol guides

- [How to mount an SMB/CIFS share on Linux](mount-smb-cifs-share-on-linux.md)
  — Ubuntu, Debian, Fedora, Arch, Raspberry Pi OS and NAS appliances.
- [How to mount an NFS export on Linux](mount-nfs-export-on-linux.md)
  — NFS 4.2 / 4.1 / 4.0 / 3, ports, fstab and systemd automount.
- [How to connect an iSCSI target on Linux](connect-iscsi-target-on-linux.md)
  — discovery, CHAP, LUN lookup, formatting and automatic login.
- [How to connect an NVMe-oF target on Linux](connect-nvme-of-target-on-linux.md)
  — NVMe over TCP/RDMA, discovery, connect and a systemd boot unit.

## Operations

- [Persist network mounts at boot](persist-network-mounts-at-boot.md)
  — fstab, `nofail`, `x-systemd.automount`, `noauto` and timeouts.
- [Troubleshoot network mounts](troubleshooting-network-mounts.md)
  — `mount error(13)`, `mount error(2)`, hangs, busy devices and CHAP.
- [Comparison: storctl vs fstab vs autofs vs systemd](comparison.md)
  — when to use each approach.
- [FAQ](faq.md) — common questions about install, safety and support.
