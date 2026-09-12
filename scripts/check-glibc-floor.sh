#!/usr/bin/env bash
# check-glibc-floor.sh — refuse an ELF that needs a newer glibc than we ship for.
#
# A dynamically linked binary records, per referenced symbol, the oldest glibc
# version that provides it. The binary then refuses to start on any host whose
# glibc is older than the highest of those. That highest value is the real
# support floor of a release, and nothing in the build declares it: it is
# whatever the build machine's glibc happened to offer.
#
# That is how v0.35.x came to need GLIBC_2.38 for exactly two symbols, `fmod`
# and `__isoc23_strtol`, neither of them a feature the code asks for — both
# are what an ubuntu-24.04 runner emits by default. The binary then refused to
# start on Debian 12, on Ubuntu 22.04, and on 26 of Terminal-Bench 4.0's 66
# task images (masc#35321).
#
# So the floor is declared here and checked, rather than being an emergent
# property of the runner image. scripts/build-linux-release.sh builds at the
# floor; this script is what says whether it succeeded.
#
# Usage:
#   scripts/check-glibc-floor.sh <floor> <binary> [binary...]
#     e.g. scripts/check-glibc-floor.sh 2.35 dist/masc-linux-x64
#
# Exit status is 0 only when every binary stays at or below the floor. A
# binary with no dynamic glibc references at all (a static musl build, such as
# masc-exec-shim) passes: it has no floor to exceed.
#
# Requires `objdump` (binutils). Reads only; never modifies the binaries.
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <floor, e.g. 2.35> <binary> [binary...]" >&2
  exit 2
fi

floor="$1"
shift

case "$floor" in
  [0-9]*.[0-9]*) ;;
  *)
    echo "check-glibc-floor: floor must look like 2.35, got '$floor'" >&2
    exit 2
    ;;
esac

if ! command -v objdump >/dev/null 2>&1; then
  # Refusing is the point: a missing objdump must not read as "nothing above
  # the floor". A silent skip here would let the very regression this script
  # exists to catch reach a release.
  echo "check-glibc-floor: objdump not found; install binutils" >&2
  exit 2
fi

floor_tag="GLIBC_${floor}"
status=0

# Highest GLIBC_x.y referenced by $1, or the empty string when the binary
# references none. `sort -V` orders 2.9 below 2.10, which a lexical sort does
# not — that difference decides this check for every floor past 2.9.
#
# The trailing `|| true` is load-bearing: a static binary matches nothing, grep
# exits 1, and under `pipefail` that would abort the whole script rather than
# report the pass that no references actually means.
max_glibc_ref() {
  objdump -T "$1" 2>/dev/null \
    | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' \
    | sort -u -V \
    | tail -1 || true
}

for binary in "$@"; do
  if [ ! -f "$binary" ]; then
    echo "check-glibc-floor: no such file: $binary" >&2
    status=1
    continue
  fi

  highest="$(max_glibc_ref "$binary")"

  if [ -z "$highest" ]; then
    echo "ok   $binary — no dynamic glibc references (static)"
    continue
  fi

  # Both tags share the GLIBC_ prefix, so version-sorting the pair puts the
  # newer one last. Equal to the floor is allowed; above it is not.
  if [ "$(printf '%s\n%s\n' "$highest" "$floor_tag" | sort -V | tail -1)" = "$floor_tag" ]; then
    echo "ok   $binary — needs at most $highest (floor $floor_tag)"
    continue
  fi

  echo "FAIL $binary — needs $highest, above the floor $floor_tag" >&2
  # Name the symbols. Without them the next reader has to rediscover that the
  # cause is two stray references and not a deliberate dependency.
  objdump -T "$binary" 2>/dev/null \
    | grep -E 'GLIBC_[0-9]+(\.[0-9]+)+' \
    | awk -v floor="$floor_tag" '
        {
          ver = ""; sym = ""
          for (i = 1; i <= NF; i++) {
            # objdump writes an imported symbols version in parentheses,
            # "(GLIBC_2.38) fmod", and a defined ones bare. Accept both.
            field = $i
            gsub(/[()]/, "", field)
            if (field ~ /^GLIBC_[0-9]/) { ver = field; sym = $(i + 1); break }
          }
        }
        ver != "" && ver != floor {
          split(substr(ver, 7), a, ".")
          split(substr(floor, 7), b, ".")
          if (a[1] > b[1] || (a[1] == b[1] && a[2] > b[2])) print "       " ver "  " sym
        }
      ' \
    | sort -u >&2 || true
  status=1
done

exit "$status"
