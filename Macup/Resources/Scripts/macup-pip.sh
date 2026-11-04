#!/bin/zsh
# Shared ownership check for Python distributions. A writable site-packages directory does not
# imply pip owns its contents: Homebrew's bundled pip has INSTALLER=brew and no RECORD file.
# Read package metadata rather than guessing from the Python executable or its install prefix;
# pip-installed packages in the same Python must remain independently updatable.
macup_pip_is_brew_owned() {
  setopt local_options null_glob extended_glob
  local site=$1 name=$2 version=$3 norm=${2//[-.]/_} info
  local -a metadata=("$site"/(#i)${norm}-${version}.dist-info(N) "$site"/(#i)${name}-${version}.dist-info(N))
  for info in "${metadata[@]}"; do
    [[ -f "$info/INSTALLER" ]] && [[ "$(<"$info/INSTALLER")" == brew ]] && return 0
  done
  return 1
}

macup_pip_brew_message() {
  print -r -- "→ Homebrew manages $1; update its Python formula in Homebrew. The bundled version may differ from PyPI's latest."
}
