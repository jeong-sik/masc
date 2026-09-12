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
# masc-exec-shim) passes: it has no floor to exceed. A file objdump cannot read
# fails — it is not a measurement, and this runs on packaged assets where a
# wrong file is one of the things being looked for.
#
# Requires `objdump` (binutils). Reads only; never modifies the binaries.
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <floor, e.g. 2.35> <binary> [binary...]" >&2
  exit 2
fi

floor="$1"
shift

# Dot-separated numbers and nothing else. The glob this replaced accepted
# "2..35", because `*` matches any text, and GNU sort -V then places
# GLIBC_2..35 *after* GLIBC_2.38 (measured, coreutils 9.x): a typo in --floor
# would have made every binary meet it. The one caller that can carry a typo
# is build-linux-release.sh's --floor, which passes its value straight here.
if ! [[ "$floor" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
  echo "check-glibc-floor: floor must look like 2.35, got '$floor'" >&2
  exit 2
fi

if ! command -v objdump >/dev/null 2>&1; then
  # Refusing is the point: a missing objdump must not read as "nothing above
  # the floor". A silent skip here would let the very regression this script
  # exists to catch reach a release.
  echo "check-glibc-floor: objdump not found; install binutils" >&2
  exit 2
fi

floor_tag="GLIBC_${floor}"
status=0

# Every GLIBC_x.y referenced in the private headers $1, one per line, oldest
# first. `sort -V` orders 2.9 below 2.10, which a lexical sort does not — that
# difference decides this check for every floor past 2.9.
#
# The trailing `|| true` is load-bearing: a static binary matches nothing, grep
# exits 1, and under `pipefail` that would abort the whole script rather than
# report the pass that no references actually means.
glibc_refs() {
  printf '%s\n' "$1" | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' | sort -u -V || true
}

# True when the tag $1 is strictly above the floor. Both tags share the GLIBC_
# prefix, so version-sorting the pair puts the newer one last; equal to the
# floor is allowed. The verdict and the symbol listing both ask through here,
# so there is one answer to "is this above the floor" instead of two that
# disagree — the arithmetic this replaced read only two components, so it
# called GLIBC_2.38.1 equal to GLIBC_2.38.
above_floor() {
  [ "$(printf '%s\n%s\n' "$1" "$floor_tag" | sort -V | tail -1)" != "$floor_tag" ]
}

for binary in "$@"; do
  if [ ! -f "$binary" ]; then
    echo "check-glibc-floor: no such file: $binary" >&2
    status=1
    continue
  fi

  # objdump also recognizes PE/COFF and other non-Linux formats. Their lack
  # of GLIBC references must not turn them into an accepted static ELF.
  if ! magic="$(od -An -tx1 -N4 "$binary" | tr -d '[:space:]')" \
    || [ "$magic" != 7f454c46 ]; then
    echo "check-glibc-floor: not an ELF file: $binary" >&2
    status=1
    continue
  fi

  # Private headers include the version requirements, including ABI tags
  # without an imported symbol. Unlike -T, -p also succeeds on a real static
  # ELF. A nonzero status still means no valid measurement was obtained.
  if ! table="$(objdump -p "$binary" 2>&1)"; then
    echo "check-glibc-floor: objdump could not read $binary" >&2
    printf '%s\n' "$table" | sed 's/^/       /' >&2
    status=1
    continue
  fi

  # Named ABI requirements are not numeric symbol versions. DT_RELR was
  # introduced in glibc 2.36; unknown requirements must not silently pass.
  # https://sourceware.org/pipermail/libc-alpha/2022-August/141193.html
  abi_refs="$(printf '%s\n' "$table" | grep -oE 'GLIBC_[A-Z][A-Z0-9_]*' | sort -u || true)"
  abi_failed=0
  while IFS= read -r ref; do
    case "$ref" in
      '') ;;
      GLIBC_ABI_DT_RELR)
        if above_floor GLIBC_2.36; then
          echo "FAIL $binary — $ref needs GLIBC_2.36, above the floor $floor_tag" >&2
          abi_failed=1
        fi
        ;;
      *)
        echo "FAIL $binary — unknown glibc requirement $ref" >&2
        abi_failed=1
        ;;
    esac
  done <<< "$abi_refs"
  if [ "$abi_failed" -eq 1 ]; then status=1; continue; fi

  refs="$(glibc_refs "$table")"
  highest="$(printf '%s\n' "$refs" | tail -1)"

  if [ -z "$highest" ]; then
    echo "ok   $binary — no dynamic glibc references (static)"
    continue
  fi

  if ! above_floor "$highest"; then
    echo "ok   $binary — needs at most $highest (floor $floor_tag)"
    continue
  fi

  echo "FAIL $binary — needs $highest, above the floor $floor_tag" >&2
  # Name the symbols. Without them the next reader has to rediscover that the
  # cause is two stray references and not a deliberate dependency.
  # This is diagnostic only: a numeric version violation is already proven
  # by the version requirements, even if its symbol table cannot be read.
  if ! table="$(objdump -T "$binary" 2>&1)"; then
    printf '%s\n' "$table" | sed 's/^/       /' >&2
    status=1
    continue
  fi
  above="$(printf '%s\n' "$refs" | while IFS= read -r ref; do
    if [ -n "$ref" ] && above_floor "$ref"; then printf '%s\n' "$ref"; fi
  done)"
  printf '%s\n' "$table" \
    | awk -v above="$above" '
        BEGIN {
          count = split(above, listed, "\n")
          for (i = 1; i <= count; i++) if (listed[i] != "") wanted[listed[i]] = 1
        }
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
        ver in wanted { print "       " ver "  " sym }
      ' \
    | sort -u >&2 || true
  status=1
done

exit "$status"
