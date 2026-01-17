#!/usr/bin/env bash
# vim:ft=bash:sw=4:ts=4:expandtab

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    printf '%s\n' "nanobrew.sh should not be sourced. Use: source <(./nanobrew.sh env)" >&2
    return 1
fi

color_enabled() {
    local stream_fd=$1
    case "${NANOBREW_COLOR:-auto}" in
        on) return 0 ;;
        off) return 1 ;;
        auto) [[ -t "$stream_fd" ]] ;;
        *) [[ -t "$stream_fd" ]] ;;
    esac
}

warn() {
    if color_enabled 2; then
        >&2 printf '\033[31m%s\033[0m\n' "$*"
    else
        >&2 echo "$@"
    fi
}

log() {
    if color_enabled 2; then
        >&2 printf '\033[32m%s\033[0m\n' "$*"
    else
        >&2 echo "$@"
    fi
}

die() {
    local ec=$?; if ((ec == 0)); then ec=1; fi
    if (($#)); then warn -n "died: "; warn "$@"; else warn "died."; fi
    local frame=0; while caller $frame; do ((++frame)); done
    exit "$ec"
}

usage() {
    cat <<'EOF'
Usage: nanobrew.sh [--debug] <command> [args...]

Environment:
  NANOBREW_HOME_DIR  Install prefix root (default: $HOME/.local)
  NANOBREW_COLOR     Color output: auto|on|off (default: auto)

Commands:
  install   <pkg...>        Install latest if missing
  uninstall <pkg...>        Uninstall if installed
  upgrade   [pkg...]        Upgrade if outdated (default: installed)
  outdated  [pkg...]        Exit 0 if any outdated (default: installed)
  env                     Print shell env (source <(./nanobrew.sh env))
  pkgs                    List known packages
  help                    Show this help
EOF
}

require_cmd() {
    local cmd=$1
    command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
}

require_prereqs() {
    if ((BASH_VERSINFO[0] < 4)); then
        die "Bash 4+ required (current: ${BASH_VERSINFO[*]})"
    fi
    require_cmd uname
    require_cmd curl
    require_cmd tar
    require_cmd jq

    if ! curl --help all 2>/dev/null | grep -q -- '--etag-compare'; then
        die "curl with --etag-compare/--etag-save required"
    fi
}

detect_os() {
    local os; os="$(uname -s)"
    case "$os" in
        Darwin) echo darwin ;;
        Linux) echo linux ;;
        *) die "Unsupported OS: $os" ;;
    esac
}

detect_plat() {
    local arch; arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64) echo amd64 ;;
        arm64|aarch64) echo arm64 ;;
        *) die "Unsupported arch: $arch" ;;
    esac
}

init_env() {
    : "${NANOBREW_HOME_DIR:=${HOME}/.local}"
    : "${NANOBREW_OS:=$(detect_os)}"
    : "${NANOBREW_PLAT:=$(detect_plat)}"
    : "${NANOBREW_COLOR:=auto}"

    : "${NANOBREW_PREFIX_DIR:=${NANOBREW_HOME_DIR}/${NANOBREW_OS}/${NANOBREW_PLAT}}"
    : "${NANOBREW_STATE_DIR:=${NANOBREW_HOME_DIR}/.nanobrew}"
    : "${NANOBREW_CACHE_DIR:=${NANOBREW_STATE_DIR}/.cache}"
    : "${NANOBREW_DB_FILE:=${NANOBREW_STATE_DIR}/db.bash}"

    : "${NANOBREW_BIN_DIR:=${NANOBREW_PREFIX_DIR}/bin}"
    : "${NANOBREW_OPT_DIR:=${NANOBREW_PREFIX_DIR}/opt}"

    export NANOBREW_HOME_DIR NANOBREW_OS NANOBREW_PLAT
}

ensure_dirs() {
    init_env
    mkdir -p "$NANOBREW_BIN_DIR" "$NANOBREW_OPT_DIR" "$NANOBREW_CACHE_DIR"
}

db_init() {
    declare -gi NANOBREW_DB_SCHEMA_VERSION=1
    declare -gA NANOBREW_DB_PKG_VERSION=()
    declare -gA NANOBREW_DB_PKG_INSTALLED_AT=()
    declare -gi NANOBREW_DB_DIRTY=0
    declare -gi NANOBREW_DB_LOADED=1
}

db_load() {
    init_env
    if [[ "${NANOBREW_DB_LOADED:-0}" == 1 ]]; then
        return 0
    fi

    db_init
    if [[ -f "$NANOBREW_DB_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$NANOBREW_DB_FILE"
    fi
    : "${NANOBREW_DB_SCHEMA_VERSION:=1}"
    : "${NANOBREW_DB_DIRTY:=0}"
}

db_mark_dirty() {
    NANOBREW_DB_DIRTY=1
}

db_save_if_dirty() {
    init_env
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

db_is_installed() {
    local pkg=$1
    db_load
    [[ -n "${NANOBREW_DB_PKG_VERSION[$pkg]:-}" ]]
}

db_get_version() {
    local pkg=$1
    db_load
    printf '%s' "${NANOBREW_DB_PKG_VERSION[$pkg]:-}"
}

db_set_version() {
    local pkg=$1 version=$2
    db_load
    NANOBREW_DB_PKG_VERSION["$pkg"]="$version"
    NANOBREW_DB_PKG_INSTALLED_AT["$pkg"]="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    db_mark_dirty
}

db_unset_pkg() {
    local pkg=$1
    db_load
    unset 'NANOBREW_DB_PKG_VERSION[$pkg]'
    unset 'NANOBREW_DB_PKG_INSTALLED_AT[$pkg]'
    db_mark_dirty
}

db_list_installed() {
    db_load
    printf '%s\n' "${!NANOBREW_DB_PKG_VERSION[@]}" | sort
}

cache_sanitize_name() {
    local name=$1
    name="${name//\//_}"
    name="${name//[^A-Za-z0-9_.-]/_}"
    printf '%s' "$name"
}

http_get_cached_named() {
    local url=$1 cache_name_raw=$2
    init_env
    mkdir -p "$NANOBREW_CACHE_DIR"

    local cache_name; cache_name="$(cache_sanitize_name "$cache_name_raw")"
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

github_release_json() {
    local owner_repo=$1
    local url="https://api.github.com/repos/${owner_repo}/releases/latest"
    local name="github.${owner_repo}.releases.latest.json"
    name="$(cache_sanitize_name "$name")"

    local json; json="$(http_get_cached_named "$url" "$name")"
    printf '%s\n' "$json"
}

github_latest_tag() {
    local owner_repo=$1
    local json; json="$(github_release_json "$owner_repo")"
    jq -r '.tag_name' <"$json"
}

select_single_line() {
    local what=$1; shift
    local -a lines=("$@")
    if ((${#lines[@]} == 0)); then
        die "No matches for: $what"
    fi
    if ((${#lines[@]} > 1)); then
        warn "Multiple matches for: $what"
        printf '%s\n' "${lines[@]}" >&2
        die "Ambiguous match for: $what"
    fi
    printf '%s\n' "${lines[0]}"
}

github_asset_url() {
    local json_file=$1 name_re=$2
    local -a urls=()
    mapfile -t urls < <(jq -r --arg re "$name_re" '.assets[] | select(.name | test($re)) | .browser_download_url' <"$json_file")
    if ((${#urls[@]} == 0)); then
        local -a assets=()
        mapfile -t assets < <(jq -r '.assets[].name' <"$json_file")
        log "No asset match for regex: ${name_re}"
        if ((${#assets[@]} == 0)); then
            log "No assets found in release."
        else
            log "Available assets:"
            >&2 printf '%s\n' "${assets[@]}"
        fi
    fi
    select_single_line "asset regex $name_re" "${urls[@]}"
}

mktempdir() {
    mktemp -d "${TMPDIR:-/tmp}/nanobrew.XXXXXXXX"
}

extract_root_dir() {
    local extract_dir=$1
    local -a entries=()
    mapfile -t entries < <(find "$extract_dir" -mindepth 1 -maxdepth 1 -print)
    if ((${#entries[@]} == 1)) && [[ -d "${entries[0]}" ]]; then
        printf '%s\n' "${entries[0]}"
        return 0
    fi
    printf '%s\n' "$extract_dir"
}

move_dir_contents() {
    local src_dir=$1 dest_dir=$2
    mkdir -p "$dest_dir"
    local count
    count="$( (shopt -s dotglob nullglob; set -- "$src_dir"/*; echo $#) )"
    if ((count == 0)); then
        die "No files extracted from archive"
    fi
    (
        shopt -s dotglob
        mv "$src_dir"/* "$dest_dir"/
    )
}

find_binary_relpath() {
    local root_dir=$1 bin_name=$2
    local found
    found="$(find "$root_dir" -type f -name "$bin_name" -print | head -n 1 || true)"
    if [[ -z "$found" ]]; then
        die "Binary not found in payload: $bin_name"
    fi
    if [[ "$found" != "$root_dir/"* ]]; then
        die "Internal error: unexpected find result: $found"
    fi
    printf '%s\n' "${found#"$root_dir"/}"
}

tarball_dir_name() {
    local url=$1
    local name
    name="$(basename "$url")"
    case "$name" in
        *.tar.gz) name="${name%.tar.gz}" ;;
        *.tgz) name="${name%.tgz}" ;;
    esac
    printf '%s\n' "$name"
}

pkg_install_from_tar_gz_url() {
    local pkg=$1 version=$2 url=$3 install_dir=$4; shift 4
    local -a bin_names=("$@")

    ensure_dirs

    local target_dir="$NANOBREW_OPT_DIR/$install_dir"
    rm -rf "$target_dir"
    mkdir -p "$target_dir"

    log "Downloading $pkg $version"
    curl --fail --location --silent --show-error "$url" | tar -xzf - -C "$target_dir"

    local bin
    for bin in "${bin_names[@]}"; do
        local relpath; relpath="$(find_binary_relpath "$target_dir" "$bin")"
        ln -nfs "../opt/$install_dir/$relpath" "$NANOBREW_BIN_DIR/$bin"
    done
}

safe_unlink_bin() {
    local install_dir=$1 bin=$2
    init_env
    local link="$NANOBREW_BIN_DIR/$bin"
    if [[ ! -L "$link" ]]; then
        return 0
    fi
    local target; target="$(readlink "$link")"
    case "$target" in
        ../opt/"$install_dir"/*) rm -f "$link" ;;
        *) warn "Skipping $link (not managed by nanobrew): $target" ;;
    esac
}

pkg_uninstall_generic() {
    local pkg=$1 version=$2; shift 2
    local -a bin_names=("$@")

    init_env

    if [[ -z "$version" ]]; then
        return 0
    fi

    local install_dir
    install_dir="$(pkg_call "$pkg" install_dir "$version")"
    if [[ -z "$install_dir" ]]; then
        die "Missing install dir for $pkg $version"
    fi

    local bin
    for bin in "${bin_names[@]}"; do
        safe_unlink_bin "$install_dir" "$bin"
    done

    rm -rf "${NANOBREW_OPT_DIR:?}/$install_dir"
}

rust_target_triple() {
    init_env
    case "${NANOBREW_OS}/${NANOBREW_PLAT}" in
        linux/amd64) echo x86_64-unknown-linux-musl ;;
        linux/arm64) echo aarch64-unknown-linux-musl ;;
        darwin/amd64) echo x86_64-apple-darwin ;;
        darwin/arm64) echo aarch64-apple-darwin ;;
        *) die "Unsupported platform: ${NANOBREW_OS}/${NANOBREW_PLAT}" ;;
    esac
}

# --- Package callbacks (install/uninstall/env hooks) ---

pkg_ripgrep_latest_version() {
    github_latest_tag BurntSushi/ripgrep
}

pkg_ripgrep_install_dir() {
    local version=$1
    local triple; triple="$(rust_target_triple)"
    printf 'ripgrep-%s-%s\n' "${version#v}" "$triple"
}

pkg_ripgrep_install() {
    local version=$1
    local json; json="$(github_release_json BurntSushi/ripgrep)"
    local triple; triple="$(rust_target_triple)"
    local asset="ripgrep-${version#v}-${triple}.tar.gz"
    local name_re="^${asset}$"
    local url; url="$(github_asset_url "$json" "$name_re")"
    local install_dir; install_dir="$(tarball_dir_name "$asset")"
    pkg_install_from_tar_gz_url ripgrep "$version" "$url" "$install_dir" rg
}



pkg_ripgrep_uninstall() {
    local version=$1
    pkg_uninstall_generic ripgrep "$version" rg
}

pkg_bat_latest_version() {
    github_latest_tag sharkdp/bat
}

pkg_bat_install_dir() {
    local version=$1
    local triple; triple="$(rust_target_triple)"
    printf 'bat-v%s-%s\n' "${version#v}" "$triple"
}

pkg_bat_install() {
    local version=$1
    local json; json="$(github_release_json sharkdp/bat)"
    local triple; triple="$(rust_target_triple)"
    local asset="bat-v${version#v}-${triple}.tar.gz"
    local name_re="^${asset}$"
    local url; url="$(github_asset_url "$json" "$name_re")"
    local install_dir; install_dir="$(tarball_dir_name "$asset")"
    pkg_install_from_tar_gz_url bat "$version" "$url" "$install_dir" bat
}



pkg_bat_uninstall() {
    local version=$1
    pkg_uninstall_generic bat "$version" bat
}

pkg_eza_latest_version() {
    github_latest_tag eza-community/eza
}

pkg_eza_asset_name() {
    init_env
    case "${NANOBREW_OS}/${NANOBREW_PLAT}" in
        linux/amd64) printf '%s\n' 'eza_x86_64-unknown-linux-musl.tar.gz' ;;
        linux/arm64) printf '%s\n' 'eza_aarch64-unknown-linux-gnu.tar.gz' ;;
        darwin/amd64) printf '%s\n' 'eza_x86_64-apple-darwin.tar.gz' ;;
        darwin/arm64) printf '%s\n' 'eza_aarch64-apple-darwin.tar.gz' ;;
        *) die "Unsupported platform: ${NANOBREW_OS}/${NANOBREW_PLAT}" ;;
    esac
}

pkg_eza_install_dir() {
    local asset
    asset="$(pkg_eza_asset_name)"
    tarball_dir_name "$asset"
}

pkg_eza_install() {
    local version=$1
    local json; json="$(github_release_json eza-community/eza)"

    local asset; asset="$(pkg_eza_asset_name)"
    local name_re="^${asset}$"
    local url; url="$(github_asset_url "$json" "$name_re")"
    local install_dir; install_dir="$(tarball_dir_name "$asset")"
    pkg_install_from_tar_gz_url eza "$version" "$url" "$install_dir" eza
}



pkg_eza_uninstall() {
    local version=$1
    pkg_uninstall_generic eza "$version" eza
}

pkg_zellij_latest_version() {
    github_latest_tag zellij-org/zellij
}

pkg_zellij_install_dir() {
    local triple; triple="$(rust_target_triple)"
    printf 'zellij-%s\n' "$triple"
}

pkg_zellij_install() {
    local version=$1
    local json; json="$(github_release_json zellij-org/zellij)"
    local triple; triple="$(rust_target_triple)"
    local asset="zellij-${triple}.tar.gz"
    local name_re="^${asset}$"
    local url; url="$(github_asset_url "$json" "$name_re")"
    local install_dir; install_dir="$(tarball_dir_name "$asset")"
    pkg_install_from_tar_gz_url zellij "$version" "$url" "$install_dir" zellij
}



pkg_zellij_uninstall() {
    local version=$1
    pkg_uninstall_generic zellij "$version" zellij
}

pkg_zoxide_latest_version() {
    github_latest_tag ajeetdsouza/zoxide
}

pkg_zoxide_install_dir() {
    local version=$1
    local triple; triple="$(rust_target_triple)"
    printf 'zoxide-%s-%s\n' "${version#v}" "$triple"
}

pkg_zoxide_install() {
    local version=$1
    local json; json="$(github_release_json ajeetdsouza/zoxide)"
    local triple; triple="$(rust_target_triple)"
    local asset="zoxide-${version#v}-${triple}.tar.gz"
    local name_re="^${asset}$"
    local url; url="$(github_asset_url "$json" "$name_re")"
    local install_dir; install_dir="$(tarball_dir_name "$asset")"
    pkg_install_from_tar_gz_url zoxide "$version" "$url" "$install_dir" zoxide
}



pkg_zoxide_uninstall() {
    local version=$1
    pkg_uninstall_generic zoxide "$version" zoxide
}

# --- End package callbacks ---

pkg_func_prefix() {
    local pkg=$1
    printf 'pkg_%s' "${pkg//-/_}"
}

pkg_call() {
    local pkg=$1 action=$2; shift 2
    local prefix; prefix="$(pkg_func_prefix "$pkg")"
    local fn="${prefix}_${action}"
    if ! declare -F "$fn" >/dev/null; then
        die "Unknown package or action: $pkg $action"
    fi
    log "calling ${pkg} ${action}"
    "$fn" "$@"
}

known_pkgs() {
    printf '%s\n' ripgrep bat eza zellij zoxide
}

is_known_pkg() {
    local pkg=$1
    case "$pkg" in
        ripgrep|bat|eza|zellij|zoxide) return 0 ;;
        *) return 1 ;;
    esac
}

cmd_pkgs() {
    known_pkgs
}

cmd_install() {
    local -a pkgs=("$@")
    if ((${#pkgs[@]} == 0)); then
        die "install requires at least 1 package"
    fi

    require_prereqs
    init_env
    db_load

    local pkg
    for pkg in "${pkgs[@]}"; do
        if ! is_known_pkg "$pkg"; then
            die "Unknown package: $pkg"
        fi
        if db_is_installed "$pkg"; then
            warn "$pkg already installed ($(db_get_version "$pkg"))"
            continue
        fi
        local version
        version="$(pkg_call "$pkg" latest_version)"
        if [[ -z "$version" ]]; then
            die "Unable to determine latest version for $pkg"
        fi
        pkg_call "$pkg" install "$version"
        db_set_version "$pkg" "$version"
    done
}

cmd_uninstall() {
    local -a pkgs=("$@")
    if ((${#pkgs[@]} == 0)); then
        die "uninstall requires at least 1 package"
    fi

    require_prereqs
    init_env
    db_load

    local pkg
    for pkg in "${pkgs[@]}"; do
        if ! is_known_pkg "$pkg"; then
            die "Unknown package: $pkg"
        fi
        if ! db_is_installed "$pkg"; then
            continue
        fi
        local version
        version="$(db_get_version "$pkg")"
        pkg_call "$pkg" uninstall "$version"
        db_unset_pkg "$pkg"
    done
}

pkg_is_outdated() {
    local pkg=$1
    db_load
    if ! db_is_installed "$pkg"; then
        return 0
    fi

    local installed latest
    installed="$(db_get_version "$pkg")"
    latest="$(pkg_call "$pkg" latest_version)"
    [[ "$installed" != "$latest" ]]
}

cmd_outdated() {
    require_prereqs
    init_env
    db_load

    local -a pkgs=("$@")
    if ((${#pkgs[@]} == 0)); then
        mapfile -t pkgs < <(db_list_installed || true)
    fi

    local any=1
    local pkg
    for pkg in "${pkgs[@]}"; do
        if ! is_known_pkg "$pkg"; then
            die "Unknown package: $pkg"
        fi
        if pkg_is_outdated "$pkg"; then
            echo "$pkg"
            any=0
        fi
    done
    return "$any"
}

cmd_upgrade() {
    require_prereqs
    init_env
    db_load

    local -a pkgs=("$@")
    if ((${#pkgs[@]} == 0)); then
        mapfile -t pkgs < <(db_list_installed || true)
    fi

    local pkg
    for pkg in "${pkgs[@]}"; do
        if ! is_known_pkg "$pkg"; then
            die "Unknown package: $pkg"
        fi
        local installed_version=""
        if db_is_installed "$pkg"; then
            installed_version="$(db_get_version "$pkg")"
        fi
        local latest_version
        latest_version="$(pkg_call "$pkg" latest_version)"
        if [[ -z "$latest_version" ]]; then
            die "Unable to determine latest version for $pkg"
        fi
        if [[ -z "$installed_version" || "$installed_version" != "$latest_version" ]]; then
            log "Upgrading $pkg"
            if [[ -n "$installed_version" ]]; then
                pkg_call "$pkg" uninstall "$installed_version"
                db_unset_pkg "$pkg"
            fi
            pkg_call "$pkg" install "$latest_version"
            db_set_version "$pkg" "$latest_version"
        fi
    done
}

env_print() {
    init_env
    db_load

    printf 'export NANOBREW_HOME_DIR=%q\n' "$NANOBREW_HOME_DIR"
    printf 'export NANOBREW_OS=%q\n' "$NANOBREW_OS"
    printf 'export NANOBREW_PLAT=%q\n' "$NANOBREW_PLAT"

    local nb_home_bin="${NANOBREW_HOME_DIR}/bin"
    local nb_plat_bin="${NANOBREW_BIN_DIR}"
    local new_path=":${PATH}:"
    new_path="${new_path//:${nb_home_bin}:/:}"
    new_path="${new_path//:${nb_plat_bin}:/:}"
    new_path="${new_path#:}"
    new_path="${new_path%:}"
    new_path="${nb_home_bin}:${nb_plat_bin}:${new_path}"
    new_path="${new_path%:}"
    printf 'export PATH=%q\n' "$new_path"

    local script_path
    if script_path="$(command -v -- "${BASH_SOURCE[0]}")"; then
        :
    else
        script_path="${BASH_SOURCE[0]}"
    fi
    if [[ "$script_path" != /* ]]; then
        script_path="${PWD}/${script_path}"
    fi
    printf 'alias nb=%q\n' "$script_path"

    local pkg
    for pkg in $(db_list_installed); do
        local fn
        fn="$(pkg_func_prefix "$pkg")_env"
        if declare -F "$fn" >/dev/null; then
            "$fn"
        fi
    done

}

cmd_env() {
    env_print
}

main() {
    set -o errexit -o errtrace -o pipefail -o nounset
    trap die ERR
    trap db_save_if_dirty EXIT

    local cmd=""
    while (($#)); do
        case "$1" in
            --help|-h) usage; return 0 ;;
            --debug|-d) set -o xtrace ;;
            *) cmd=$1; shift; break ;;
        esac
        shift
    done

    if [[ -z "$cmd" ]] || [[ "$cmd" == help ]]; then
        usage
        return 0
    fi

    case "$cmd" in
        install) cmd_install "$@" ;;
        uninstall) cmd_uninstall "$@" ;;
        upgrade) cmd_upgrade "$@" ;;
        outdated) cmd_outdated "$@" ;;
        env) cmd_env ;;
        pkgs) cmd_pkgs ;;
        *) die "Unknown command: $cmd" ;;
    esac
}

main "$@"
