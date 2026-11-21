#!/bin/zsh
# Read installed macOS apps without letting copies in Trash, backups or installers stand in for them.
macup_app_version_is_numeric() { [[ "$1" =~ '^[0-9]+(\.[0-9]+)*$' ]] }

# Standard install locations take precedence over copies elsewhere. The App Store can also install
# on its preferred external volume. Resolve links before checking: an Applications alias to a disk
# image or Trash is still a copy there, not an installed app in Applications.
macup_app_install_priority() {
  local app=${1:A} preferred=${2:-} volume readonly root
  local -a roots=(/Applications /System/Volumes/Data/Applications "${HOME:A}/Applications")
  [[ "${(L)app}" == *.app ]] || return 1
  case "${(L)app}" in
    */.trash/*|*/.trashes/*|*/backups.backupdb/*|*/.timemachine/*|*.backup/*|*.app/contents/*) return 1 ;;
  esac
  if [[ "$app" == /Volumes/* ]]; then
    volume="/Volumes/${${app#/Volumes/}%%/*}"
    readonly=$(diskutil info -plist "$volume" 2>/dev/null | plutil -extract ReadOnlyVolume raw -o - - 2>/dev/null)
    [[ "$readonly" == true ]] && return 1
  fi
  [[ -n "$preferred" && "$preferred" != */* ]] && roots+=("/Volumes/$preferred/Applications")
  for root in "${roots[@]}"; do
    if [[ "$app" == "$root/"* ]]; then
      # A top-level installation wins over an archived/nested duplicate in the same Applications root.
      [[ "${app#"$root/"}" == */* ]] && print 2 || print 3
      return 0
    fi
  done
  case "$app" in
    "${HOME:A}/Downloads/"*|/Volumes/*) print 0 ;;
    *) print 1 ;;
  esac
}

# Spotlight locates candidates, but its ID can outlive the bundle at that path. Only trust a version
# from an App Store installation whose on-disk bundle identity still matches the indexed identity.
# CFBundleVersion is a build number, not a fallback for the App Store's marketing version.
macup_app_store_version() {
  local app=$1 identifier indexed version
  [[ -f "$app/Contents/_MASReceipt/receipt" ]] || return 1
  identifier=$(plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist" 2>/dev/null)
  [[ -n "$identifier" ]] || return 1
  indexed=$(mdls -raw -name kMDItemCFBundleIdentifier "$app" 2>/dev/null)
  [[ "$indexed" == "$identifier" ]] || return 1
  version=$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist" 2>/dev/null)
  macup_app_version_is_numeric "$version" || return 1
  print -r -- "$version"
}
