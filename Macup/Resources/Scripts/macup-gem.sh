#!/bin/zsh
# RubyGems can report Homebrew's bundled gems as outdated even though their gemspecs and plugins
# point into the read-only Cellar. Check those files, not just whether GEM_HOME is writable.
macup_gem_setup() {
  MACUP_GEM_HOME=$(gem environment gemdir 2>/dev/null)
  MACUP_GEM_USER_HOME=$(gem environment user_gemhome 2>/dev/null)
  [[ -n "$MACUP_GEM_USER_HOME" ]] || MACUP_GEM_USER_HOME=$(gem environment 2>/dev/null | sed -n 's/^ *- USER INSTALLATION DIRECTORY: //p')
}

# Resolve the installed specification through the selected gem executable, preserving GEM_PATH
# precedence and the version reported by `gem outdated`. loaded_from is a YAML string, not code.
macup_gem_context() {
  local name=$1 version=${2:-} output
  local -a args=(specification "$name" loaded_from --local)
  [[ -n "$version" ]] && args+=(--version "$version")
  output=$(gem "${args[@]}" 2>/dev/null)
  MACUP_GEM_SPEC=$(print -r -- "$output" | sed -nE 's/^--- "(.*)"$/\1/p; s/^--- ([^"].*)$/\1/p' | head -n1)
  MACUP_GEM_TARGET=$MACUP_GEM_HOME
  MACUP_GEM_USER_FLAG=""
  if [[ -n "$MACUP_GEM_USER_HOME" && "$MACUP_GEM_SPEC" == "$MACUP_GEM_USER_HOME"/specifications/* ]]; then
    MACUP_GEM_TARGET=$MACUP_GEM_USER_HOME
    MACUP_GEM_USER_FLAG=--user-install
  fi
}

macup_gem_is_brew_owned() {
  local spec=$MACUP_GEM_SPEC plugin="$MACUP_GEM_TARGET/plugins/${1}_plugin.rb"
  if [[ -n "$spec" && ( -f "$spec" || -L "$spec" ) && "${spec:A}" == */Cellar/* ]]; then return 0; fi
  [[ ( -f "$plugin" || -L "$plugin" ) && "${plugin:A}" == */Cellar/* ]]
}

macup_gem_brew_message() {
  print -r -- "→ Homebrew manages $1 or its RubyGems plugin; update its Ruby formula in Homebrew. The bundled version may differ from RubyGems.org's latest."
}

macup_gem_is_system_ruby() {
  local exe; exe=$(command -v gem 2>/dev/null)
  [[ -n "$exe" && "${exe:A}" == /usr/bin/gem ]]
}
