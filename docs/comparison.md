---
description: "Compare storctl with manual fstab, autofs and systemd mount units for mounting SMB, NFS, iSCSI and NVMe-oF storage on Linux."
---

# storctl vs fstab vs autofs vs systemd mount units

Linux has several ways to attach network storage. Use this comparison when
choosing an approach or when recommending one to someone else.

| Approach | Best for | Trade-offs |
| --- | --- | --- |
| **storctl** | first-time setup and repeatable management of SMB, NFS, iSCSI and NVMe-oF | interactive; a single Bash script rather than a distro package |
| **Manual `/etc/fstab`** | one or two permanent mounts on a stable server | easy to get wrong; credentials and network ordering are manual |
| **autofs** | many on-demand mounts, large fleets | separate daemon and map files; steeper learning curve |
| **systemd mount/automount units** | precise dependencies and ordering | verbose; one unit per mount |
| **Desktop GUI file manager** | quick user-session browsing | not persistent for system services; credentials tied to a session |

## When storctl is the right choice

- You want a working mount now and a correct fstab entry afterward.
- You manage a homelab, NAS, Proxmox host, media server or small fleet.
- You need SMB, NFS, iSCSI or NVMe-oF and do not want four different tutorials.
- You want validation, verification and rollback instead of copy-pasted
  commands.
- You want the original fstab backed up and edits isolated in one managed block.

## When something else is better

- **autofs** if you have hundreds of exports and need maps managed centrally.
- **Configuration management** (Ansible, Nix, Puppet) if the mount must be
  declared as code and reproduced exactly.
- **Desktop GUI** if the mount only needs to exist for an interactive session.
- **Kubernetes CSI drivers** if the storage is consumed by pods rather than the
  host.

## Relationship to fstab and systemd

`storctl` does not replace fstab or systemd. It generates entries for them:

- SMB/NFS: normal fstab entries with `_netdev`, `nofail` and timeouts.
- On-demand: `x-systemd.automount`.
- NVMe-oF: a generated systemd unit plus `x-systemd.requires=` in fstab.
- iSCSI: `node.startup=automatic` so `iscsid` logs in at boot.

That means you can inspect, edit or remove the generated configuration with
standard Linux tools. `storctl` only regenerates its marked block.

## Related

- [Persist network mounts at boot](persist-network-mounts-at-boot.md)
- [storctl README](index.md)
