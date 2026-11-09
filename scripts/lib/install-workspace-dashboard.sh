# shellcheck shell=bash
# Sourced by scripts/install-local-build.sh.
#
# Replaces the dashboard bundle a workspace serves with the one this checkout
# built.
#
# masc start makes the base path its working directory
# (lib/server/server_base_path_guard.ml). With no MASC_ASSETS_DIR and no
# assets next to the binary, the server reads <base-path>/assets
# (Web_dashboard.select_assets_root). A local install replaced the binaries and
# never that bundle, so a workspace kept serving the dashboard somebody last
# copied by hand: the 2026-10-27 bundle was still served on 2026-11-08 (#49980).
#
# The rule is the guest shim's. A workspace that holds a bundle gets this
# checkout's built bundle when that one is newer, and the old one is kept as
# dashboard-backup-<UTC time>. A workspace with no bundle is given none. Every
# refusal is a line and a zero status, because the binaries are installed by
# the time this runs.
#
# Newer means the .build-stamp mtime, which build-dashboard-if-needed.sh
# writes and which cp -p keeps. A workspace copy made from an older checkout
# is therefore never replaced by an even older build.
#
# usage: install_workspace_dashboard CHECKOUT_BUNDLE_DIR WORKSPACE_ROOT
install_workspace_dashboard() {
  local bundle=$1 workspace_root=$2
  local dest_root="$workspace_root/assets"
  local dest="$dest_root/dashboard"
  local tag="install-local-build"
  local stamp staged backup

  if [ ! -f "$dest/index.html" ]; then
    echo "$tag: no dashboard bundle in $dest; none installed"
    return 0
  fi
  if [ -L "$dest_root" ] || [ -L "$dest" ]; then
    echo "$tag: dashboard bundle in $dest left as it is: a symlink leads to it, and the install does not replace what a symlink points at"
    return 0
  fi
  if [ ! -f "$bundle/index.html" ] || [ ! -f "$bundle/.build-stamp" ]; then
    echo "$tag: WARN dashboard bundle in $dest left as it is: $bundle holds no built bundle (scripts/build-dashboard-if-needed.sh builds one)" >&2
    return 0
  fi
  if [ -f "$dest/.build-stamp" ] && [ ! "$bundle/.build-stamp" -nt "$dest/.build-stamp" ]; then
    echo "$tag: dashboard bundle in $dest is already as new as the one in $bundle"
    return 0
  fi

  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  backup="$dest_root/dashboard-backup-$stamp"
  if [ -e "$backup" ]; then
    echo "$tag: WARN dashboard bundle in $dest left as it is: $backup already exists" >&2
    return 0
  fi
  if ! staged=$(mktemp -d "$dest_root/.dashboard.partial.XXXXXX" 2>/dev/null); then
    echo "$tag: WARN dashboard bundle in $dest left as it is: no staging directory could be made in $dest_root" >&2
    return 0
  fi
  if ! chmod 755 "$staged" || ! cp -Rp "$bundle/." "$staged/"; then
    rm -rf "$staged"
    echo "$tag: WARN dashboard bundle in $dest left as it is: $bundle could not be copied" >&2
    return 0
  fi
  if ! mv "$dest" "$backup"; then
    rm -rf "$staged"
    echo "$tag: WARN dashboard bundle in $dest left as it is: it could not be moved to $backup" >&2
    return 0
  fi
  if ! mv "$staged" "$dest"; then
    mv "$backup" "$dest" || echo "$tag: WARN the previous dashboard bundle is in $backup; move it back to $dest" >&2
    rm -rf "$staged"
    echo "$tag: WARN dashboard bundle in $dest left as it was: the new copy could not be put in place" >&2
    return 0
  fi
  echo "$tag: installed the dashboard bundle of $bundle into $dest (the previous one is kept as $backup)"
}
