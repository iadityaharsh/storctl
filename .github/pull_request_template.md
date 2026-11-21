## Problem

What problem does this change solve?

## Change

What did you change, and why this approach?

## Protocol / area

- [ ] SMB / CIFS
- [ ] NFS
- [ ] iSCSI
- [ ] NVMe-oF
- [ ] fstab / systemd persistence
- [ ] disks / filesystems
- [ ] documentation

## Testing

- [ ] `bash -n storctl.sh`
- [ ] `python3 -m unittest discover -s tests`
- [ ] Manually tested on: <!-- distro/version -->

## Safety

- [ ] No automatic formatting
- [ ] No secrets in state.json or fstab
- [ ] fstab edits stay inside the managed block
- [ ] Rollback covers new state-changing steps
- [ ] Docs updated (README, `docs/`, `llms.txt`, `llms-full.txt` if needed)
