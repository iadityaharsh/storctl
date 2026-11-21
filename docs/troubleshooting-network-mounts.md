---
description: "Fix common Linux network mount errors: mount error(13), mount error(2), NFS boot hangs, busy devices and CHAP failures."
---

# Troubleshoot network mounts on Linux

Start with:

```sh
sudo ./storctl.sh --check
```

Then reproduce the mount and read the terminal output. Full command logs are
kept under `/tmp/storctl.*.log` when a setup step fails.

## Error reference

### `mount error(13): Permission denied`

SMB rejected the credentials.

- Check the username, password and domain.
- Check that the account may access the share.
- Verify the credentials file is root-owned, mode `0600`.
- Try the same share with `smbclient` to separate client and server problems.

### `mount error(2): No such file or directory`

The share or export path is wrong.

- Check spelling and case.
- For SMB, use the share name only (`media`), not `//server/media` in the share
  field.
- For NFS, verify the export exists on the server.

### `mount error(6)` / `could not resolve`

The hostname cannot be resolved.

- Use an IP address.
- Fix DNS or `/etc/hosts`.
- Check that the client is on the right network.

### `Connection refused`

Something is listening on the wrong port, or the service is down.

- SMB: port 445 (and sometimes 139).
- NFS: port 2049 and rpcbind for NFSv3.
- iSCSI: port 3260.
- NVMe-oF: port 4420.
- Check the firewall on both sides.

### `Connection timed out` / `No route to host`

- Ping the server.
- Check routing, VLANs and firewall rules.
- Verify the client IP is allowed in the target's ACL.

### `unsupported dialect` or SMB protocol errors

The CIFS client does not negotiate downwards automatically.

- Set **Options → Default SMB version** to **SMB 3.0**, then remove and re-add
  the mount so it picks up the new default.
- For very old NAS appliances, try **SMB 2.1**.
- Avoid SMB 1.0 unless the server cannot do anything else.

### `wrong fs type` / `bad option` / `unknown filesystem`

- Install the protocol client package (`cifs-utils`, `nfs-common`,
  `open-iscsi`, `nvme-cli`).
- Check that the kernel module is available.
- For NFS, make sure the fstab type is `nfs4` for NFSv4 and `nfs` for NFSv3.

### NFS mount hangs during boot

A missing `nofail` or an unreachable server can block boot.

- Add `nofail` and `x-systemd.device-timeout=30s`.
- Or use `x-systemd.automount,x-systemd.idle-timeout=60`.
- Check the server's export rules.

### `target is busy` / `device is busy`

Files are still open on the mount.

- Close the files or processes using the mount.
- `storctl` offers a lazy unmount (`umount -l`) when you confirm.
- Check with `lsof +f -- /mnt/name` or `fuser -vm /mnt/name`.

### iSCSI login or CHAP errors

- Verify the CHAP username and secret.
- Add the initiator IQN to the target's ACL.
- Check `iscsid` is running.
- Try discovery manually with `iscsiadm -m discovery`.

### NVMe-oF connect errors

- Verify the target address, port and NQN.
- Add the host NQN to the target's ACL.
- Check the transport (`tcp` vs `rdma`).
- Look at `dmesg` for namespace errors.
- If the mount fails at boot, confirm the generated unit is enabled and
  referenced by `x-systemd.requires=`.

## Useful commands

```sh
findmnt -rn -o SOURCE,FSTYPE,TARGET,OPTIONS -M /mnt/name
lsblk -f
blkid
systemctl list-units --type=mount
journalctl -b -u mnt-name.mount
dmesg | tail -50
lsof +f -- /mnt/name
```

## Related

- [Mount an SMB/CIFS share](mount-smb-cifs-share-on-linux.md)
- [Mount an NFS export](mount-nfs-export-on-linux.md)
- [Connect an iSCSI target](connect-iscsi-target-on-linux.md)
- [Connect an NVMe-oF target](connect-nvme-of-target-on-linux.md)
