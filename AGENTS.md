# Agents Guide

This repository a consolidated installer (`nanobrew.sh`) script that targets `~/.local`.

## Project layout
- `nanobrew.sh` is the primary, single-file installer CLI. Keep all package logic in this file.
- [design.md](doc/design.md) contains design notes.

## Conventions
- Bash 4+ is required; use strict mode in the CLI entrypoint.
- All env vars are prefixed with `NANOBREW_`.
- Package functions live in `nanobrew.sh` using the naming convention:
  - `nanobrew_pkg_<pkg>_latest_version`, `nanobrew_pkg_<pkg>_install`, `nanobrew_pkg_<pkg>_uninstall`, optional `nanobrew_pkg_<pkg>_env`
  - Package names in the CLI may use dashes; function names map `-` → `_`.
- Install prefix: `$NANOBREW_HOME_DIR/$NANOBREW_OS/$NANOBREW_PLAT`, with state/cache under `$NANOBREW_HOME_DIR/.nanobrew/`.
- HTTP responses should use ETag caching via `nanobrew_http_get_cached_named`.

## Adding a package
- Implement the `latest_version/install/uninstall` functions and optional `env` function.
- Update `nanobrew_known_pkgs` and `nanobrew_is_known_pkg`.
- Ensure `install` is idempotent and `uninstall` removes symlinks under `$NANOBREW_BIN_DIR`.

## Suggested checks
- `shellcheck nanobrew.sh`
- `bash -n nanobrew.sh`
