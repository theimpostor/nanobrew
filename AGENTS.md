# Agents Guide

This repository a consolidated installer (`nanobrew.sh`) script that targets `~/.local`.

## Project layout
- `nanobrew.sh` is the primary, single-file installer CLI. Keep all package logic in this file.
- [design.md](doc/design.md) contains design notes.

## Conventions
- Bash 4+ is required; use strict mode in the CLI entrypoint.
- All env vars are prefixed with `NANOBREW_`.
- `NANOBREW_COLOR` controls colored log output (`auto|on|off`, default `auto`). Logs go to stderr.
- Package functions live in `nanobrew.sh` using the naming convention:
  - `pkg_<pkg>_latest_version`, `pkg_<pkg>_install`, `pkg_<pkg>_uninstall`, optional `pkg_<pkg>_env`
  - Package names in the CLI may use dashes; function names map `-` → `_`.
  - Install/uninstall callbacks now receive `version` and `install_dir` args (`install_dir` is computed as `<pkg>-<version>` and stored in DB).
- Install prefix: `$NANOBREW_HOME_DIR/$NANOBREW_OS/$NANOBREW_PLAT`, with state/cache under `$NANOBREW_HOME_DIR/.nanobrew/`.
- HTTP responses should use ETag caching via `nanobrew_http_get_cached_named`.

## Adding a package
- Implement the `latest_version/install/uninstall` functions and optional `env` function.
- Uninstall relies on the stored `install_dir`; no per-package `install_dir` callback is used.
- Update `known_pkgs` and `is_known_pkg`.
- Ensure `install` is idempotent and `uninstall` removes symlinks under `$NANOBREW_BIN_DIR`.

## Required checks
- `shellcheck --enable=all --severity=style nanobrew.sh`
- `semgrep scan --config auto nanobrew.sh`
- `bash -n nanobrew.sh`
