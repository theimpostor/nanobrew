#!/usr/bin/env bash
# vim:ft=bash:sw=4:ts=4:expandtab

nanobrew_is_sourced() {
    [[ "${BASH_SOURCE[0]}" != "${0}" ]]
}

nanobrew_warn() {
    >&2 echo "$@"
}

nanobrew_die() {
    local ec=$?; if ((ec == 0)); then ec=1; fi
    if (($#)); then nanobrew_warn -n "died: "; nanobrew_warn "$@"; else nanobrew_warn "died."; fi
    local frame=0; while caller $frame; do ((++frame)); done
    if nanobrew_is_sourced; then
        return "$ec"
    fi
    exit "$ec"
}

nanobrew_enable_strict_mode() {
    set -o errexit -o errtrace -o pipefail -o nounset
}

nanobrew_on_exit() {
    nanobrew_db_save_if_dirty
}

nanobrew_set_traps() {
    trap nanobrew_die ERR
    trap nanobrew_on_exit EXIT
}

nanobrew_usage() {
    cat <<'EOF'
Usage: nanobrew.sh [--debug] <command> [args...]

Environment:
  NANOBREW_HOME_DIR  Install prefix root (default: $HOME/.local)

Commands:
  install   <pkg...>        Install latest if missing
  uninstall <pkg...>        Uninstall if installed
  upgrade   [pkg...]        Upgrade if outdated (default: installed)
  outdated  [pkg...]        Exit 0 if any outdated (default: installed)
  env                     Print shell env (eval "$(nanobrew.sh env)")
  pkgs                    List known packages
  help                    Show this help
EOF
}

nanobrew_require_cmd() {
    local cmd=$1
    command -v "$cmd" >/dev/null 2>&1 || nanobrew_die "Missing required command: $cmd"
}

nanobrew_require_prereqs() {
    if ((BASH_VERSINFO[0] < 4)); then
        nanobrew_die "Bash 4+ required (current: ${BASH_VERSINFO[*]})"
    fi
    nanobrew_require_cmd uname
    nanobrew_require_cmd curl
    nanobrew_require_cmd tar
    nanobrew_require_cmd jq

    if ! curl --help all 2>/dev/null | grep -q -- '--etag-compare'; then
        nanobrew_die "curl with --etag-compare/--etag-save required"
    fi
}

nanobrew_detect_os() {
    local os; os="$(uname -s)"
    case "$os" in
        Darwin) echo darwin ;;
        Linux) echo linux ;;
        *) nanobrew_die "Unsupported OS: $os" ;;
    esac
}

nanobrew_detect_plat() {
    local arch; arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64) echo amd64 ;;
        arm64|aarch64) echo arm64 ;;
        *) nanobrew_die "Unsupported arch: $arch" ;;
    esac
}

nanobrew_init_env() {
    : "${NANOBREW_HOME_DIR:=${HOME}/.local}"
    : "${NANOBREW_OS:=$(nanobrew_detect_os)}"
    : "${NANOBREW_PLAT:=$(nanobrew_detect_plat)}"

    : "${NANOBREW_PREFIX_DIR:=${NANOBREW_HOME_DIR}/${NANOBREW_OS}/${NANOBREW_PLAT}}"
    : "${NANOBREW_STATE_DIR:=${NANOBREW_HOME_DIR}/.nanobrew}"
    : "${NANOBREW_CACHE_DIR:=${NANOBREW_STATE_DIR}/.cache}"
    : "${NANOBREW_DB_FILE:=${NANOBREW_STATE_DIR}/db.bash}"

    : "${NANOBREW_BIN_DIR:=${NANOBREW_PREFIX_DIR}/bin}"
    : "${NANOBREW_OPT_DIR:=${NANOBREW_PREFIX_DIR}/opt}"

    export NANOBREW_HOME_DIR NANOBREW_OS NANOBREW_PLAT
}

nanobrew_ensure_dirs() {
    nanobrew_init_env
    mkdir -p "$NANOBREW_BIN_DIR" "$NANOBREW_OPT_DIR" "$NANOBREW_CACHE_DIR"
}

nanobrew_db_init() {
    declare -gi NANOBREW_DB_SCHEMA_VERSION=1
    declare -gA NANOBREW_DB_PKG_VERSION=()
    declare -gA NANOBREW_DB_PKG_INSTALLED_AT=()
    declare -gi NANOBREW_DB_DIRTY=0
    declare -gi NANOBREW_DB_LOADED=1
}

nanobrew_db_load() {
    nanobrew_init_env
    if [[ "${NANOBREW_DB_LOADED:-0}" == 1 ]]; then
        return 0
    fi

    nanobrew_db_init
    if [[ -f "$NANOBREW_DB_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$NANOBREW_DB_FILE"
    fi
    : "${NANOBREW_DB_SCHEMA_VERSION:=1}"
    : "${NANOBREW_DB_DIRTY:=0}"
}

nanobrew_db_mark_dirty() {
    NANOBREW_DB_DIRTY=1
}

nanobrew_db_save_if_dirty() {
    nanobrew_init_env
    if [[ "${NANOBREW_DB_LOADED:-0}" != 1 ]]; then
        return 0
    fi
    if [[ "${NANOBREW_DB_DIRTY:-0}" != 1 ]]; then
        return 0
    fi

    mkdir -p "$NANOBREW_STATE_DIR"
    local tmp="${NANOBREW_DB_FILE}.tmp.$$"
    {
        echo "# nanobrew db (generated)"; echo
        declare -p NANOBREW_DB_SCHEMA_VERSION NANOBREW_DB_PKG_VERSION NANOBREW_DB_PKG_INSTALLED_AT
    } >"$tmp"
    mv "$tmp" "$NANOBREW_DB_FILE"
    NANOBREW_DB_DIRTY=0
}

nanobrew_db_is_installed() {
    local pkg=$1
    nanobrew_db_load
    [[ -n "${NANOBREW_DB_PKG_VERSION[$pkg]:-}" ]]
}

nanobrew_db_get_version() {
    local pkg=$1
    nanobrew_db_load
    printf '%s' "${NANOBREW_DB_PKG_VERSION[$pkg]:-}"
}

nanobrew_db_set_version() {
    local pkg=$1 version=$2
    nanobrew_db_load
    NANOBREW_DB_PKG_VERSION["$pkg"]="$version"
    NANOBREW_DB_PKG_INSTALLED_AT["$pkg"]="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    nanobrew_db_mark_dirty
}

nanobrew_db_unset_pkg() {
    local pkg=$1
    nanobrew_db_load
    unset 'NANOBREW_DB_PKG_VERSION[$pkg]'
    unset 'NANOBREW_DB_PKG_INSTALLED_AT[$pkg]'
    nanobrew_db_mark_dirty
}

nanobrew_db_list_installed() {
    nanobrew_db_load
    printf '%s\n' "${!NANOBREW_DB_PKG_VERSION[@]}" | sort
}

nanobrew_cache_sanitize_name() {
    local name=$1
    name="${name//\//_}"
    name="${name//[^A-Za-z0-9_.-]/_}"
    printf '%s' "$name"
}

nanobrew_http_get_cached_named() {
    local url=$1 cache_name_raw=$2
    nanobrew_init_env
    mkdir -p "$NANOBREW_CACHE_DIR"

    local cache_name; cache_name="$(nanobrew_cache_sanitize_name "$cache_name_raw")"
    local body="$NANOBREW_CACHE_DIR/$cache_name"
    local etag="$NANOBREW_CACHE_DIR/$cache_name.etag"
    local meta="$NANOBREW_CACHE_DIR/$cache_name.url"

    printf '%s\n' "$url" >"$meta"

    local -a curl_args=(--fail --location --silent --show-error)
    if [[ -f "$etag" ]]; then
        curl_args+=(--etag-compare "$etag")
    fi
    curl_args+=(--etag-save "$etag" --output "$body")
    if [[ -n "${NANOBREW_GITHUB_TOKEN:-}" ]] && [[ "$url" == https://api.github.com/* ]]; then
        curl_args+=(-H "Authorization: Bearer ${NANOBREW_GITHUB_TOKEN}")
    fi
    curl "${curl_args[@]}" "$url"

    printf '%s\n' "$body"
}

nanobrew_github_release_json() {
    local owner_repo=$1
    local url="https://api.github.com/repos/${owner_repo}/releases/latest"
    local name="github.${owner_repo}.releases.latest.json"
    name="$(nanobrew_cache_sanitize_name "$name")"

    local json; json="$(nanobrew_http_get_cached_named "$url" "$name")"
    printf '%s\n' "$json"
}

nanobrew_github_latest_tag() {
    local owner_repo=$1
    local json; json="$(nanobrew_github_release_json "$owner_repo")"
    jq -r '.tag_name' <"$json"
}

nanobrew_select_single_line() {
    local what=$1; shift
    local -a lines=("$@")
    if ((${#lines[@]} == 0)); then
        nanobrew_die "No matches for: $what"
    fi
    if ((${#lines[@]} > 1)); then
        nanobrew_warn "Multiple matches for: $what"
        printf '%s\n' "${lines[@]}" >&2
        nanobrew_die "Ambiguous match for: $what"
    fi
    printf '%s\n' "${lines[0]}"
}

nanobrew_github_asset_url() {
    local json_file=$1 name_re=$2
    local -a urls=()
    mapfile -t urls < <(jq -r --arg re "$name_re" '.assets[] | select(.name | test($re)) | .browser_download_url' <"$json_file")
    nanobrew_select_single_line "asset regex $name_re" "${urls[@]}"
}

nanobrew_mktempdir() {
    mktemp -d "${TMPDIR:-/tmp}/nanobrew.XXXXXXXX"
}

nanobrew_extract_root_dir() {
    local extract_dir=$1
    local -a entries=()
    mapfile -t entries < <(find "$extract_dir" -mindepth 1 -maxdepth 1 -print)
    if ((${#entries[@]} == 1)) && [[ -d "${entries[0]}" ]]; then
        printf '%s\n' "${entries[0]}"
        return 0
    fi
    printf '%s\n' "$extract_dir"
}

nanobrew_move_dir_contents() {
    local src_dir=$1 dest_dir=$2
    mkdir -p "$dest_dir"
    local count
    count="$( (shopt -s dotglob nullglob; set -- "$src_dir"/*; echo $#) )"
    if ((count == 0)); then
        nanobrew_die "No files extracted from archive"
    fi
    (
        shopt -s dotglob
        mv "$src_dir"/* "$dest_dir"/
    )
}

nanobrew_find_binary_relpath() {
    local root_dir=$1 bin_name=$2
    local found
    found="$(find "$root_dir" -type f -name "$bin_name" -print | head -n 1 || true)"
    if [[ -z "$found" ]]; then
        nanobrew_die "Binary not found in payload: $bin_name"
    fi
    if [[ "$found" != "$root_dir/"* ]]; then
        nanobrew_die "Internal error: unexpected find result: $found"
    fi
    printf '%s\n' "${found#"$root_dir"/}"
}

nanobrew_tarball_dir_name() {
    local url=$1
    local name
    name="$(basename "$url")"
    case "$name" in
        *.tar.gz) name="${name%.tar.gz}" ;;
        *.tgz) name="${name%.tgz}" ;;
    esac
    printf '%s\n' "$name"
}

nanobrew_pkg_install_from_tar_gz_url() {
    local pkg=$1 version=$2 url=$3 install_dir=$4; shift 4
    local -a bin_names=("$@")

    nanobrew_ensure_dirs

    local target_dir="$NANOBREW_OPT_DIR/$install_dir"
    rm -rf "$target_dir"
    mkdir -p "$target_dir"

    nanobrew_warn "Downloading $pkg $version"
    curl --fail --location --silent --show-error "$url" | tar -xzf - -C "$target_dir"

    local bin
    for bin in "${bin_names[@]}"; do
        local relpath; relpath="$(nanobrew_find_binary_relpath "$target_dir" "$bin")"
        ln -nfs "../opt/$install_dir/$relpath" "$NANOBREW_BIN_DIR/$bin"
    done

    nanobrew_db_set_version "$pkg" "$version"
}

nanobrew_safe_unlink_bin() {
    local install_dir=$1 bin=$2
    nanobrew_init_env
    local link="$NANOBREW_BIN_DIR/$bin"
    if [[ ! -L "$link" ]]; then
        return 0
    fi
    local target; target="$(readlink "$link")"
    case "$target" in
        ../opt/"$install_dir"/*) rm -f "$link" ;;
        *) nanobrew_warn "Skipping $link (not managed by nanobrew): $target" ;;
    esac
}

nanobrew_pkg_uninstall_generic() {
    local pkg=$1; shift
    local -a bin_names=("$@")

    nanobrew_init_env

    if ! nanobrew_db_is_installed "$pkg"; then
        return 0
    fi

    local version install_dir
    version="$(nanobrew_db_get_version "$pkg")"
    install_dir="$(nanobrew_pkg_call "$pkg" install_dir "$version")"
    if [[ -z "$install_dir" ]]; then
        nanobrew_die "Missing install dir for $pkg $version"
    fi

    local bin
    for bin in "${bin_names[@]}"; do
        nanobrew_safe_unlink_bin "$install_dir" "$bin"
    done

    rm -rf "${NANOBREW_OPT_DIR:?}/$install_dir"
    nanobrew_db_unset_pkg "$pkg"
}

nanobrew_rust_target_triple() {
    nanobrew_init_env
    case "${NANOBREW_OS}/${NANOBREW_PLAT}" in
        linux/amd64) echo x86_64-unknown-linux-musl ;;
        linux/arm64) echo aarch64-unknown-linux-musl ;;
        darwin/amd64) echo x86_64-apple-darwin ;;
        darwin/arm64) echo aarch64-apple-darwin ;;
        *) nanobrew_die "Unsupported platform: ${NANOBREW_OS}/${NANOBREW_PLAT}" ;;
    esac
}

# --- Package callbacks (install/uninstall/env hooks) ---

nanobrew_pkg_ripgrep_latest_version() {
    nanobrew_github_latest_tag BurntSushi/ripgrep
}

nanobrew_pkg_ripgrep_install_dir() {
    local version=$1
    local triple; triple="$(nanobrew_rust_target_triple)"
    printf 'ripgrep-%s-%s\n' "${version#v}" "$triple"
}

nanobrew_pkg_ripgrep_install() {
    local version; version="$(nanobrew_pkg_ripgrep_latest_version)"
    local json; json="$(nanobrew_github_release_json BurntSushi/ripgrep)"
    local triple; triple="$(nanobrew_rust_target_triple)"
    local asset="ripgrep-${version#v}-${triple}.tar.gz"
    local name_re="^${asset}$"
    local url; url="$(nanobrew_github_asset_url "$json" "$name_re")"
    local install_dir; install_dir="$(nanobrew_tarball_dir_name "$asset")"
    nanobrew_pkg_install_from_tar_gz_url ripgrep "$version" "$url" "$install_dir" rg
}



nanobrew_pkg_ripgrep_uninstall() {
    nanobrew_pkg_uninstall_generic ripgrep rg
}

nanobrew_pkg_bat_latest_version() {
    nanobrew_github_latest_tag sharkdp/bat
}

nanobrew_pkg_bat_install_dir() {
    local version=$1
    local triple; triple="$(nanobrew_rust_target_triple)"
    printf 'bat-v%s-%s\n' "${version#v}" "$triple"
}

nanobrew_pkg_bat_install() {
    local version; version="$(nanobrew_pkg_bat_latest_version)"
    local json; json="$(nanobrew_github_release_json sharkdp/bat)"
    local triple; triple="$(nanobrew_rust_target_triple)"
    local asset="bat-v${version#v}-${triple}.tar.gz"
    local name_re="^${asset}$"
    local url; url="$(nanobrew_github_asset_url "$json" "$name_re")"
    local install_dir; install_dir="$(nanobrew_tarball_dir_name "$asset")"
    nanobrew_pkg_install_from_tar_gz_url bat "$version" "$url" "$install_dir" bat
}



nanobrew_pkg_bat_uninstall() {
    nanobrew_pkg_uninstall_generic bat bat
}

nanobrew_pkg_eza_latest_version() {
    nanobrew_github_latest_tag eza-community/eza
}

nanobrew_pkg_eza_asset_name() {
    nanobrew_init_env
    case "${NANOBREW_OS}/${NANOBREW_PLAT}" in
        linux/amd64) printf '%s\n' 'eza_x86_64-unknown-linux-musl.tar.gz' ;;
        linux/arm64) printf '%s\n' 'eza_aarch64-unknown-linux-gnu.tar.gz' ;;
        darwin/amd64) printf '%s\n' 'eza_x86_64-apple-darwin.tar.gz' ;;
        darwin/arm64) printf '%s\n' 'eza_aarch64-apple-darwin.tar.gz' ;;
        *) nanobrew_die "Unsupported platform: ${NANOBREW_OS}/${NANOBREW_PLAT}" ;;
    esac
}

nanobrew_pkg_eza_install_dir() {
    local asset
    asset="$(nanobrew_pkg_eza_asset_name)"
    nanobrew_tarball_dir_name "$asset"
}

nanobrew_pkg_eza_install() {
    local version; version="$(nanobrew_pkg_eza_latest_version)"
    local json; json="$(nanobrew_github_release_json eza-community/eza)"

    local asset; asset="$(nanobrew_pkg_eza_asset_name)"
    local name_re="^${asset}$"
    local url; url="$(nanobrew_github_asset_url "$json" "$name_re")"
    local install_dir; install_dir="$(nanobrew_tarball_dir_name "$asset")"
    nanobrew_pkg_install_from_tar_gz_url eza "$version" "$url" "$install_dir" eza
}



nanobrew_pkg_eza_uninstall() {
    nanobrew_pkg_uninstall_generic eza eza
}

nanobrew_pkg_zellij_latest_version() {
    nanobrew_github_latest_tag zellij-org/zellij
}

nanobrew_pkg_zellij_install_dir() {
    local triple; triple="$(nanobrew_rust_target_triple)"
    printf 'zellij-%s\n' "$triple"
}

nanobrew_pkg_zellij_install() {
    local version; version="$(nanobrew_pkg_zellij_latest_version)"
    local json; json="$(nanobrew_github_release_json zellij-org/zellij)"
    local triple; triple="$(nanobrew_rust_target_triple)"
    local asset="zellij-${triple}.tar.gz"
    local name_re="^${asset}$"
    local url; url="$(nanobrew_github_asset_url "$json" "$name_re")"
    local install_dir; install_dir="$(nanobrew_tarball_dir_name "$asset")"
    nanobrew_pkg_install_from_tar_gz_url zellij "$version" "$url" "$install_dir" zellij
}



nanobrew_pkg_zellij_uninstall() {
    nanobrew_pkg_uninstall_generic zellij zellij
}

nanobrew_pkg_zoxide_latest_version() {
    nanobrew_github_latest_tag ajeetdsouza/zoxide
}

nanobrew_pkg_zoxide_install_dir() {
    local version=$1
    local triple; triple="$(nanobrew_rust_target_triple)"
    printf 'zoxide-%s-%s\n' "${version#v}" "$triple"
}

nanobrew_pkg_zoxide_install() {
    local version; version="$(nanobrew_pkg_zoxide_latest_version)"
    local json; json="$(nanobrew_github_release_json ajeetdsouza/zoxide)"
    local triple; triple="$(nanobrew_rust_target_triple)"
    local asset="zoxide-${version#v}-${triple}.tar.gz"
    local name_re="^${asset}$"
    local url; url="$(nanobrew_github_asset_url "$json" "$name_re")"
    local install_dir; install_dir="$(nanobrew_tarball_dir_name "$asset")"
    nanobrew_pkg_install_from_tar_gz_url zoxide "$version" "$url" "$install_dir" zoxide
}



nanobrew_pkg_zoxide_uninstall() {
    nanobrew_pkg_uninstall_generic zoxide zoxide
}

# --- End package callbacks ---

nanobrew_pkg_func_prefix() {
    local pkg=$1
    printf 'nanobrew_pkg_%s' "${pkg//-/_}"
}

nanobrew_pkg_call() {
    local pkg=$1 action=$2; shift 2
    local prefix; prefix="$(nanobrew_pkg_func_prefix "$pkg")"
    local fn="${prefix}_${action}"
    if ! declare -F "$fn" >/dev/null; then
        nanobrew_die "Unknown package or action: $pkg $action"
    fi
    "$fn" "$@"
}

nanobrew_known_pkgs() {
    printf '%s\n' ripgrep bat eza zellij zoxide
}

nanobrew_is_known_pkg() {
    local pkg=$1
    case "$pkg" in
        ripgrep|bat|eza|zellij|zoxide) return 0 ;;
        *) return 1 ;;
    esac
}

nanobrew_cmd_pkgs() {
    nanobrew_known_pkgs
}

nanobrew_cmd_install() {
    local -a pkgs=("$@")
    if ((${#pkgs[@]} == 0)); then
        nanobrew_die "install requires at least 1 package"
    fi

    nanobrew_require_prereqs
    nanobrew_init_env
    nanobrew_db_load

    local pkg
    for pkg in "${pkgs[@]}"; do
        if ! nanobrew_is_known_pkg "$pkg"; then
            nanobrew_die "Unknown package: $pkg"
        fi
        if nanobrew_db_is_installed "$pkg"; then
            nanobrew_warn "$pkg already installed ($(nanobrew_db_get_version "$pkg"))"
            continue
        fi
        nanobrew_pkg_call "$pkg" install
    done
}

nanobrew_cmd_uninstall() {
    local -a pkgs=("$@")
    if ((${#pkgs[@]} == 0)); then
        nanobrew_die "uninstall requires at least 1 package"
    fi

    nanobrew_require_prereqs
    nanobrew_init_env
    nanobrew_db_load

    local pkg
    for pkg in "${pkgs[@]}"; do
        if ! nanobrew_is_known_pkg "$pkg"; then
            nanobrew_die "Unknown package: $pkg"
        fi
        nanobrew_pkg_call "$pkg" uninstall
    done
}

nanobrew_pkg_is_outdated() {
    local pkg=$1
    nanobrew_db_load
    if ! nanobrew_db_is_installed "$pkg"; then
        return 0
    fi

    local installed latest
    installed="$(nanobrew_db_get_version "$pkg")"
    latest="$(nanobrew_pkg_call "$pkg" latest_version)"
    [[ "$installed" != "$latest" ]]
}

nanobrew_cmd_outdated() {
    nanobrew_require_prereqs
    nanobrew_init_env
    nanobrew_db_load

    local -a pkgs=("$@")
    if ((${#pkgs[@]} == 0)); then
        mapfile -t pkgs < <(nanobrew_db_list_installed || true)
    fi

    local any=1
    local pkg
    for pkg in "${pkgs[@]}"; do
        if ! nanobrew_is_known_pkg "$pkg"; then
            nanobrew_die "Unknown package: $pkg"
        fi
        if nanobrew_pkg_is_outdated "$pkg"; then
            echo "$pkg"
            any=0
        fi
    done
    return "$any"
}

nanobrew_cmd_upgrade() {
    nanobrew_require_prereqs
    nanobrew_init_env
    nanobrew_db_load

    local -a pkgs=("$@")
    if ((${#pkgs[@]} == 0)); then
        mapfile -t pkgs < <(nanobrew_db_list_installed || true)
    fi

    local pkg
    for pkg in "${pkgs[@]}"; do
        if ! nanobrew_is_known_pkg "$pkg"; then
            nanobrew_die "Unknown package: $pkg"
        fi
        if nanobrew_pkg_is_outdated "$pkg"; then
            nanobrew_warn "Upgrading $pkg"
            nanobrew_pkg_call "$pkg" uninstall
            nanobrew_pkg_call "$pkg" install
        fi
    done
}

nanobrew_env_print() {
    nanobrew_init_env
    nanobrew_db_load

    printf 'export NANOBREW_HOME_DIR=%q\n' "$NANOBREW_HOME_DIR"
    printf 'export NANOBREW_OS=%q\n' "$NANOBREW_OS"
    printf 'export NANOBREW_PLAT=%q\n' "$NANOBREW_PLAT"

    local nb_home_bin="${NANOBREW_HOME_DIR}/bin"
    local nb_plat_bin="${NANOBREW_PREFIX_DIR}/bin"
    local new_path=":${PATH}:"
    new_path="${new_path//:${nb_home_bin}:/:}"
    new_path="${new_path//:${nb_plat_bin}:/:}"
    new_path="${new_path#:}"
    new_path="${new_path%:}"
    new_path="${nb_home_bin}:${nb_plat_bin}:${new_path}"
    new_path="${new_path%:}"
    printf 'export PATH=%q\n' "$new_path"

    local pkg
    for pkg in $(nanobrew_db_list_installed); do
        local fn
        fn="$(nanobrew_pkg_func_prefix "$pkg")_env"
        if declare -F "$fn" >/dev/null; then
            "$fn"
        fi
    done

}

nanobrew_cmd_env() {
    nanobrew_env_print
}

nanobrew_source() {
    eval "$(nanobrew_env_print)"
}

nanobrew_main() {
    nanobrew_enable_strict_mode
    nanobrew_set_traps

    local cmd=""
    while (($#)); do
        case "$1" in
            --help|-h) nanobrew_usage; return 0 ;;
            --debug|-d) set -o xtrace ;;
            *) cmd=$1; shift; break ;;
        esac
        shift
    done

    if [[ -z "$cmd" ]] || [[ "$cmd" == help ]]; then
        nanobrew_usage
        return 0
    fi

    case "$cmd" in
        install) nanobrew_cmd_install "$@" ;;
        uninstall) nanobrew_cmd_uninstall "$@" ;;
        upgrade) nanobrew_cmd_upgrade "$@" ;;
        outdated) nanobrew_cmd_outdated "$@" ;;
        env) nanobrew_cmd_env ;;
        pkgs) nanobrew_cmd_pkgs ;;
        *) nanobrew_die "Unknown command: $cmd" ;;
    esac
}

nanobrew_entrypoint() {
    if nanobrew_is_sourced; then
        nanobrew_source
    else
        nanobrew_main "$@"
    fi
}

nanobrew_entrypoint "$@"
