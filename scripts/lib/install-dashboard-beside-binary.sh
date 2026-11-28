# shellcheck shell=bash
# Sourced by scripts/install-local-build.sh.
#
# Puts the dashboard bundle this checkout built beside the installed binaries,
# in <prefix>/assets/dashboard. The release install keeps its bundle beside its
# binary too, in <prefix>/.masc-releases/<identity>/assets/dashboard, which
# <prefix>/masc links to (scripts/release-dashboard-bundle.py).
#
# A server started from <prefix>/masc reads the assets beside its binary
# before the assets of its working directory, which masc start makes the base
# path (Web_dashboard.select_assets_root). The bundle used to go into the
# workspace the install judged, so a second workspace served from the same
# binary, such as an account server, found none and answered /dashboard with
# 503 (#55405). Beside the binary, every workspace that binary serves reads
# the bundle of the same install.
#
# An older bundle there is replaced and kept as dashboard-backup-<UTC time>,
# and a prefix with no bundle is given one. An assets directory this step made
# is taken away again when the copy fails, since the server reads an empty one
# before the assets of the base path. A checkout with no built bundle
# installs nothing; that is a warning only when it leaves an older bundle
# beside the new binaries. Every
# refusal is a line and a zero status, because the binaries are installed by
# the time this runs.
#
# Newer means the .build-stamp mtime, which build-dashboard-if-needed.sh
# writes and which cp -p keeps. A copy made from an older checkout is
# therefore never replaced by an even older build.
#
# usage: install_dashboard_beside_binary CHECKOUT_BUNDLE_DIR PREFIX
install_dashboard_beside_binary() {
  # An assets directory made by this call holds nothing of anyone else's, so
  # rmdir takes it away; one that is not empty is left as it is.
  take_back_made_root() {
    if [ "$made_root" = true ]; then
      rmdir "$dest_root" 2>/dev/null || true
    fi
  }

  local bundle=$1 prefix=$2
  local dest_root="$prefix/assets"
  local dest="$dest_root/dashboard"
  local tag="install-local-build"
  local stamp staged backup="" made_root=false

  if [ -L "$dest_root" ] || [ -L "$dest" ]; then
    echo "$tag: dashboard bundle in $dest left as it is: a symlink leads to it, and the install does not replace what a symlink points at"
    return 0
  fi
  if [ ! -f "$bundle/index.html" ] || [ ! -f "$bundle/.build-stamp" ]; then
    if [ -e "$dest" ]; then
      echo "$tag: WARN dashboard bundle in $dest left as it is: $bundle holds no built bundle (scripts/build-dashboard-if-needed.sh builds one)" >&2
    else
      echo "$tag: no dashboard bundle in $bundle; none installed into $dest (scripts/build-dashboard-if-needed.sh builds one)"
    fi
    return 0
  fi
  if [ -f "$dest/.build-stamp" ] && [ ! "$bundle/.build-stamp" -nt "$dest/.build-stamp" ]; then
    echo "$tag: dashboard bundle in $dest is already as new as the one in $bundle"
    return 0
  fi

  if [ ! -d "$dest_root" ]; then
    if ! mkdir -p "$dest_root" 2>/dev/null; then
      echo "$tag: WARN no dashboard bundle installed into $dest: $dest_root could not be made" >&2
      return 0
    fi
    made_root=true
  fi
  if [ -e "$dest" ]; then
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    backup="$dest_root/dashboard-backup-$stamp"
    if [ -e "$backup" ]; then
      echo "$tag: WARN dashboard bundle in $dest left as it is: $backup already exists" >&2
      return 0
    fi
  fi
  if ! staged=$(mktemp -d "$dest_root/.dashboard.partial.XXXXXX" 2>/dev/null); then
    take_back_made_root
    echo "$tag: WARN dashboard bundle in $dest left as it is: no staging directory could be made in $dest_root" >&2
    return 0
  fi
  if ! chmod 755 "$staged" || ! cp -Rp "$bundle/." "$staged/"; then
    rm -rf "$staged"
    take_back_made_root
    echo "$tag: WARN dashboard bundle in $dest left as it is: $bundle could not be copied" >&2
    return 0
  fi
  if [ -n "$backup" ] && ! mv "$dest" "$backup"; then
    rm -rf "$staged"
    echo "$tag: WARN dashboard bundle in $dest left as it is: it could not be moved to $backup" >&2
    return 0
  fi
  if ! mv "$staged" "$dest"; then
    if [ -n "$backup" ]; then
      mv "$backup" "$dest" || echo "$tag: WARN the previous dashboard bundle is in $backup; move it back to $dest" >&2
    fi
    rm -rf "$staged"
    take_back_made_root
    echo "$tag: WARN dashboard bundle in $dest left as it was: the new copy could not be put in place" >&2
    return 0
  fi
  if [ -n "$backup" ]; then
    echo "$tag: installed the dashboard bundle of $bundle into $dest (the previous one is kept as $backup)"
  else
    echo "$tag: installed the dashboard bundle of $bundle into $dest"
  fi
}
