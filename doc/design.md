# design for bash .local installer script - nanobrew.sh

- support mac, linux
- install platform-specific stuff to plaform specific dirs
- use curl etags, keep cache of responses in .cache
- all code lives in functions, including main()
- all env vars prefixed with `NANOBREW_`, i.e. `NANOBREW_HOME_DIR=$HOME/.local`
- sourcing nanobrew.sh adds `$NANOBREW_HOME_DIR/bin:$NANOBREW_HOME_DIR/$NANOBREW_OS/$NANOBREW_PLAT/bin` to PATH
    - also runs installed app env callbacks
- prereqs, check and exit if not there on startup:
    - bash 4 or greater
    - curl w/etag support
    - tar
- use bash 'strict mode':

```bash
set -o errexit -o errtrace -o pipefail -o nounset
```
- use readonly, local variables as appropriate
- use bash backtrace:
```bash
function warn() {
    >&2 echo "$@"
}

function die() {
    local ec=$?; if ((ec == 0)); then ec=1; fi
    if (($#)); then warn -n "died: "; warn "$@"; else warn "died."; fi
    local frame=0; while caller $frame; do ((++frame)); done
    exit $ec
}
trap die ERR
```
- per-app callbacks:
    - <pkg>-latest-version
        - returns the latest version available for pkg
    - <pkg>-install:
        - installs the pkg, error if already installed
    - <pkg>-uninstall:
        - uninstalls the pkg, error if not installed
    - <pkg>-env:
        - optional, updates env for the pkg

- script ui
    - `<script> <command> <args>`
    - commands are declaritive in nature
    - commands:
    - install
        - if installed, done
        - download, extract, symlink
        - update db
    - uninstall
        - if not installed, done
        - remove artifacts
        - clean up symlink
        - update db
    - upgrade
        - if outdated
        - uninstall
        - exec install
    - outdated
        - if not installed, return true
        - if new version available, return true
        - else return false
    - env
        - update env, sourced
- script persistence
    - bash map persisted to file
    - persisted on exit
        ```bash
        declare -p mymap > map.save   # write
        source map.save               # read back
        ```
    - saved to $NANOBREW_HOME_DIR/.nanobrew/db.bash


# future stuff
lock file - future enhancement

declarative package specs + generic installers (to simplify adding many package types)
  - single required callback per pkg: <pkg>_spec
    - sets metadata vars, no logic
    - optional <pkg>_env (only when needed)
    - optional <pkg>_install / <pkg>_uninstall overrides for non-standard cases
  - add generic installer types, e.g.:
    - github_release_tar / github_release_zip
    - url_tar / url_zip / url_bin
    - git_build (git clone + build command)
  - store install_dir + bin list in DB at install time to make uninstall generic
  - fallback path: if install_dir not in DB, recompute or call override
  - spec field sketch (all strings unless noted):
    - PKG_TYPE
    - PKG_REPO / PKG_URL
    - PKG_ASSET_RE (regex; may use ${version}, ${triple})
    - PKG_BINS (array)
    - PKG_INSTALL_DIR (template; may use ${version}, ${triple})
    - PKG_BUILD_CMD (for git_build)
  - flow:
    - latest_version: generic per type, pkg spec only
    - install: generic per type, record install_dir + bins in DB
    - uninstall: generic, removes symlinks + opt dir from DB metadata

bash 4/5 => bash 3 polyfills?

https://pnut.sh/ -> transpile C to POSIX sh
amber-lang -> transpile amber to bash
write/test in oil shell?

install needed tools if missing:
  curl w/etag support
  gnu tar (gtar)
  bsdtar
