#!/usr/bin/env sh
# Pin the git dependencies recorded in a lock file's `pin-depends:` section.
#
# Eleven first-party packages are absent from opam-repository, so a plain
# `opam install --deps-only` on masc.opam fails at solve time with
# "unknown package: mcp_protocol". The lock file records each package and its
# git URL, which is what this script replays.
#
# Why not the alternatives:
# - `opam install --locked` and `opam install <file>.locked` do not apply
#   pin-depends: both still fail to solve.
# - `opam pin add --locked <dir>` does apply them, but crashes partway
#   through with Invalid_argument("String.sub / Bytes.sub").
# - scripts/opam-pin-external-deps.sh acquires a host switch write lease and
#   validates the caller's shell prefix, neither of which exists in an image
#   build.
#
# `-n` pins without building; the caller runs one `opam install` afterwards so
# the solve happens once over the whole dependency set.
#
# Usage: opam-pin-from-lock.sh <path-to-opam.locked>

set -eu

lock="${1:?usage: opam-pin-from-lock.sh <path-to-opam.locked>}"

# pin-depends entries are two-line pairs (package, then git URL), but the
# lock file's indentation is not uniform, so pairs are recovered by tracking
# the line before each git URL rather than by block structure. The repo's own
# `dev-repo:` field also carries a git URL and is excluded.
awk '/"git\+/ { gsub(/[ "]/, "", prev); gsub(/[ "]/, "", $0); print prev, $0 } { prev = $0 }' \
  "$lock" \
  | grep -v 'dev-repo' \
  > /tmp/opam-pins.txt

if [ ! -s /tmp/opam-pins.txt ]; then
  echo "opam-pin-from-lock: no pin-depends entries found in $lock" >&2
  exit 1
fi

while read -r pkg url; do
  echo "opam-pin-from-lock: pinning $pkg -> $url"
  opam pin add -n -y "$pkg" "$url"
done < /tmp/opam-pins.txt

rm -f /tmp/opam-pins.txt
