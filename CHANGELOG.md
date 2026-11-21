# Changelog

## Versioning

- `0.0.1` — bug fixes, UI changes and small tweaks.
- `0.1` — functional changes.

## 1.0.2 — 2026-11-21

### UI changes (0.0.1)

- Documentation backgrounds now match the logo palette: `#1B1F23` dark,
  `#F3F0EA` light, and `#FF7A1A` accents. Text, code blocks, tables, navigation
  and footer contrast were adjusted for both light and dark schemes.

## 1.0.1 — 2026-11-21

Current release.

### Features

- Mount SMB/CIFS, NFS, iSCSI and NVMe-oF storage on Linux.
- Discover SMB shares with `smbclient` and NFS exports with `showmount`.
- Reuse saved SMB credentials, enter new credentials, or connect as guest.
- Install missing protocol clients on apt, dnf, pacman and zypper.
- Persist mounts with a managed `/etc/fstab` block and
  `/etc/fstab.storctl.bak` backup.
- Boot modes: at boot, on first access (`x-systemd.automount`) and manual
  (`noauto`).
- iSCSI discovery, CHAP, LUN lookup and automatic login at boot.
- NVMe-oF TCP/RDMA discovery, connection and generated systemd boot units.
- Format blank devices as ext4, xfs, btrfs, f2fs, FAT32/vfat, exFAT or NTFS,
  with the matching `mkfs` tool installed on demand.
- SMB credentials stored with mode `0600`; passwords never appear in
  `state.json` or `/etc/fstab`.
- Rollback on failure, dry-run mode and scratch-root test isolation.
- Whiptail TUI with logo-matched colors, visible button focus, clean menu
  labels and step-by-step Back navigation.
- GitHub Pages documentation with sitemap, robots, canonical metadata, JSON-LD
  and `/llms.txt` endpoints.
