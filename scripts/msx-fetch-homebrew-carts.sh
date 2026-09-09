#!/usr/bin/env bash
# Put open-source MSX cartridges into <base-path>/.masc/msx/carts/, the
# inventory the MSX machine (RFC-0439) lists as carts_available and the TUI
# load menu shows.
#
# Every entry is a release asset published by the game's author under a
# licence that permits redistribution, pinned to one version and one SHA-256.
# The script downloads from the author's release page, verifies the digest,
# and refuses to keep a file that does not match. It never fetches commercial
# ROM images; what an operator puts in carts/ by hand is the operator's own.
#
# Only plain 16 KB / 32 KB images are listed. The machine maps a cartridge at
# 0x4000 in slot 2 and has no MegaROM mapper, so a 48 KB image (XRacing,
# Westen House) does not run and is deliberately absent.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/msx-fetch-homebrew-carts.sh [--base-path DIR] [--list] [--dry-run]

  --base-path DIR  Workspace root holding .masc (default: $MASC_BASE_PATH, then cwd)
  --list           Print the pinned table and exit
  --dry-run        Say what would be downloaded; write nothing
USAGE
}

# name  version  licence  sha256  url
# The name is the file in carts/ and what a Keeper passes as `cart`.
CARTS='
xspelunker       1.4.3  GPL-3.0  a1b234b8a0a6d3f3d5ea34a255faf42d86f48ed2c5cd66d3e29f0d62aad3edf8  https://github.com/santiontanon/xspelunker/releases/download/1.4.3/spelunk-en.rom
tales-of-popolon 1.3.1  GPL-3.0  711a6b69f7d57549573af3ee308868ba58c292cc5ca3484875e33c8a13b3f630  https://github.com/santiontanon/talesofpopolon/releases/download/v1.3.1/ToP-en.rom
transball        1.3.2  GPL-3.0  35d1cd9b7f2c25cdc38eb160b2fa71473c1b68b2ce713ac8173bae7c2bf8463d  https://github.com/santiontanon/transballmsx/releases/download/1.3.2/transball-en.rom
noborunoca       1.0.2  MIT      57a3be2fe5c3190daa3e69cf23cd262cdc8af98c60993ea941d43c815cbb25f6  https://github.com/h1romas4/noborunoca/releases/download/v1.0.2/noborunoca.rom
'

base_path="${MASC_BASE_PATH:-$PWD}"
list_only=0
dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-path) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; base_path="$2"; shift 2 ;;
    --list) list_only=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

digest_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -c1-64
  else
    shasum -a 256 "$1" | cut -c1-64
  fi
}

if [[ $list_only -eq 1 ]]; then
  printf '%-17s %-7s %-8s %s\n' name version licence source
  while read -r name version licence _sha url; do
    [[ -n "$name" ]] || continue
    printf '%-17s %-7s %-8s %s\n' "$name" "$version" "$licence" "$url"
  done <<<"$CARTS"
  exit 0
fi

carts_dir="$base_path/.masc/msx/carts"
[[ $dry_run -eq 1 ]] || mkdir -p "$carts_dir"

fetched=0
present=0
failed=0
while read -r name version licence sha url; do
  [[ -n "$name" ]] || continue
  dest="$carts_dir/$name.rom"
  if [[ -f "$dest" ]] && [[ "$(digest_of "$dest")" == "$sha" ]]; then
    echo "present   $name.rom ($version, $licence)"
    present=$((present + 1))
    continue
  fi
  if [[ $dry_run -eq 1 ]]; then
    echo "would get $name.rom <- $url"
    continue
  fi
  tmp="$(mktemp "$carts_dir/.$name.XXXXXX")"
  if ! curl -fsSL --retry 3 -o "$tmp" "$url"; then
    echo "failed    $name.rom: download from $url" >&2
    rm -f "$tmp"
    failed=$((failed + 1))
    continue
  fi
  got="$(digest_of "$tmp")"
  if [[ "$got" != "$sha" ]]; then
    echo "failed    $name.rom: sha256 $got != pinned $sha" >&2
    rm -f "$tmp"
    failed=$((failed + 1))
    continue
  fi
  mv "$tmp" "$dest"
  chmod 0644 "$dest"
  echo "fetched   $name.rom ($version, $licence) -> $dest"
  fetched=$((fetched + 1))
done <<<"$CARTS"

if [[ $dry_run -eq 0 ]]; then
  echo "carts: $carts_dir (fetched $fetched, present $present, failed $failed)"
fi
[[ $failed -eq 0 ]]
