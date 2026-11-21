# Security policy

## Supported versions

Security fixes are applied to the latest release on `main`.

| Version | Supported |
| --- | --- |
| 1.x | yes |

## Reporting a vulnerability

Report privately to **iadityaharsh@gmail.com**. Include:

- affected version and Linux distribution,
- the command or mount type involved,
- reproduction steps,
- impact and any suggested fix.

Please do not open a public issue for an unpatched vulnerability.

## Security model

`storctl` is a root-level local administration tool. It:

- asks for `sudo` and runs privileged commands non-interactively;
- edits `/etc/fstab` inside a managed block and backs it up once;
- writes SMB credentials to `/etc/storctl/credentials` with mode `0600`;
- creates systemd units for NVMe-oF;
- never sends data anywhere.

It does **not** install a daemon, setuid binary or network service.

## Trust and the curl model

The recommended install method executes the script from GitHub:

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/iadityaharsh/storctl/main/storctl.sh)"
```

This trusts the URL and the network. For higher assurance:

- pin a commit hash instead of `main`,
- download the script, inspect it, then run it,
- verify the repository and commit history,
- run in a test VM before using it on production storage.

## Secrets

- SMB passwords are stored in separate root-owned `0600` files.
- Passwords never appear in `state.json` or `/etc/fstab`.
- iSCSI CHAP secrets are written into the open-iscsi node database by
  `iscsiadm`.
- No secrets are logged. Avoid pasting secrets into issue reports.
- SMB share discovery uses a temporary `0600` authentication file for
  `smbclient` and removes it immediately after listing.
- NFS export discovery uses `showmount`; NFS itself relies on server export
  rules rather than a password.

## Destructive operations

- Formatting is never automatic.
- A device without a filesystem requires an explicit ext4/xfs choice and the
  `ERASE` confirmation.
- Removing a mount removes local configuration and disconnects the session; it
  never deletes data on the server.
