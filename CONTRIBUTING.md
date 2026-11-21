# Contributing to storctl

Thanks for helping make Linux storage setup simpler.

## Development setup

- Linux with Bash 4.3+, `whiptail`, `util-linux` and `systemd`.
- Python 3 for the test suite.
- Optional: `pexpect` for the interactive tests.

```sh
bash -n storctl.sh
python3 -m unittest discover -s tests -v
```

Tests relocate all system paths with `STORCTL_ROOT` and never modify the host.

## Style

- `storctl.sh` must remain a single self-contained file.
- Keep `set -Eeuo pipefail` and quote expansions.
- Use the existing helpers: `msg_info`, `msg_ok`, `msg_warn`, `msg_err`,
  `ui_menu`, `ask_field`, `run_step`, `as_root`.
- Put validation in a `v_*` function and set `VALIDATION_ERROR`.
- Register a rollback action for every state-changing step.
- Keep messages lowercase and concise, matching the surrounding code.

## Safety rules

- Never format a device automatically.
- Never put a password in `state.json` or `/etc/fstab`.
- Keep fstab edits inside the managed block.
- Preserve user configuration outside the managed block.
- Removing a mount must not touch server data.

## Adding a protocol

1. Add `add_<protocol>` with validation and a review step.
2. Add dependency mapping in `dep_binary` and `dep_package`.
3. Build the fstab line in `build_fstab_line` and runtime options in
   `build_runtime_opts`.
4. Add teardown/rollback handling.
5. Add entries to `option_keys`, `emit_options_json` and `docs/`.
6. Update `llms.txt` and `llms-full.txt`.
7. Add tests covering the fstab line, validation and persistence.

## Documentation

- Prefer query-shaped titles such as “How to mount an NFS export on Linux”.
- Include a quick answer, a manual method, a `storctl` method and common errors.
- Link new pages from `docs/README.md` and the README documentation section.

## Pull requests

- Keep commits focused.
- Explain the problem, the change and how it was tested.
- Include test output for behavior changes.
- Do not include generated artifacts or credentials.

## License

By contributing you agree that your contribution is licensed under the MIT
License.
