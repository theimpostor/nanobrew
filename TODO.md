- Add README
  - how to install
    - download script, put in path
    - source in bashrc
  - how to install/uninstall/list/upgrade a package
  - contributing
    - how to add a package
    - how to test
- Don't support sourcing - just require 'source <(./nanobrew.sh env)'
  - check and exit if being sourced
- remove 'nanobrew_' prefix from all functions
- env command:
  - update path
  - add alias 'nb'
  - run env callbacks
- Test w/Docker
- Add packages:
  ant
  bat
  bun
  crane
  dive
  dua
  eclipse-jdt-ls
  eza
  fd
  git-lfs
  go
  gradle
  groovy-language-server
  groovy
  jq
  kubectl
  llvm
  maven
  node
  ollama
  openjdk11
  openjdk17
  openjdk21
  osc
  pandoc
  rbac-tool
  regctl
  ripgrep
  shellcheck
  starship
  temurin
  ttyd
  viddy
  vivid
  wezterm
  zellij
  zoxide

<!-- vim: set ft=markdown sw=2 ts=2 expandtab: -->
