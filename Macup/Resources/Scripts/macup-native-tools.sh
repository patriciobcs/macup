#!/bin/zsh
# Native updaters must not replace installations another manager owns.
native_tool_owner() {
  local name=$1 bin real casks=""
  bin=$(command -v "$name" 2>/dev/null) || return 1
  real=${bin:A}
  case "$real" in
    */Cellar/*|*/Caskroom/*) print Homebrew; return 0 ;;
    /nix/store/*) print Nix; return 0 ;;
    */mise/*|*/.asdf/*) print "a version manager"; return 0 ;;
    /opt/local/*) print MacPorts; return 0 ;;
  esac
  if command -v brew >/dev/null 2>&1; then
    case "$name" in
      tailscale) casks=$(brew list --cask --versions tailscale-app tailscale 2>/dev/null) ;;
      gcloud)
        case "$real" in
          /opt/homebrew/share/google-cloud-sdk/*|/usr/local/share/google-cloud-sdk/*)
            casks=$(brew list --cask --versions gcloud-cli google-cloud-sdk 2>/dev/null) ;;
        esac ;;
    esac
    [[ -n "$casks" ]] && { print Homebrew; return 0; }
  fi
  return 1
}

gcloud_updater_disabled() {
  local root=$1
  [[ -f "$root/lib/googlecloudsdk/core/config.json" ]] && \
    grep -Eq '"disable_updater"[[:space:]]*:[[:space:]]*true' "$root/lib/googlecloudsdk/core/config.json"
}

native_version_is_newer() {
  autoload -Uz is-at-least
  ! is-at-least "$1" "$2"
}
