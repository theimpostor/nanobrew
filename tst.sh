#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
image_name="${NANOBREW_TEST_IMAGE:-nanobrew-test}"

if [[ -z "${NANOBREW_IN_DOCKER:-}" ]]; then
    docker build -t "$image_name" "$script_dir"
    docker run --rm "$image_name" /root/nanobrew/tst.sh
    exit 0
fi

cd "$script_dir"

export NANOBREW_HOME_DIR=/tmp/nanobrew-test
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
rm -rf "$NANOBREW_HOME_DIR"

eval "$(bash ./nanobrew.sh env)"

nanobrew_bin_dir="${NANOBREW_HOME_DIR}/${NANOBREW_OS}/${NANOBREW_PLAT}/bin"

if command -v shellcheck >/dev/null 2>&1; then
    echo "shellcheck already on PATH before nanobrew install" >&2
    exit 1
fi
if command -v rg >/dev/null 2>&1; then
    echo "rg already on PATH before nanobrew install" >&2
    exit 1
fi

[[ ! -e "${nanobrew_bin_dir}/shellcheck" ]]
[[ ! -e "${nanobrew_bin_dir}/rg" ]]

./nanobrew.sh install shellcheck

shellcheck --enable=all --severity=style nanobrew.sh

bash -n nanobrew.sh

bash ./nanobrew.sh pkgs | grep -q '^ripgrep$'
bash ./nanobrew.sh pkgs | grep -q '^shellcheck$'

bash ./nanobrew.sh install ripgrep
[[ -x "${nanobrew_bin_dir}/rg" ]]
"${nanobrew_bin_dir}/rg" --version >/dev/null

bash ./nanobrew.sh uninstall ripgrep
[[ ! -e "${nanobrew_bin_dir}/rg" ]]
