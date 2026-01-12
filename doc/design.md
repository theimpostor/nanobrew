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

bash 4/5 => bash 3 polyfills?

https://pnut.sh/ -> transpile C to POSIX sh
amber-lang -> transpile amber to bash
write/test in oil shell?

install needed tools if missing:
  curl w/etag support
  gnu tar (gtar)
  bsdtar
