#!/usr/bin/env bash
# Reclaim regenerable build artifacts under .masc/playground.
#
# Complements the three worktree cleaners, which remove checkouts. This one
# leaves every checkout in place and removes only what a build recreates.
# That is the larger share: on 2026-08-28 the playground measured 314G across
# eight live keepers, and 72 _build directories accounted for 221G of it —
# ten of them 20G or more, because a keeper keeps several checkouts of masc
# (repos/masc, masc-366, masc-t382, .worktrees/task-*) and each one builds.
#
# Conservative by design:
#   - dry-run by default; --apply required to actually remove
#   - skips any directory a running build is working inside
#   - never touches sources, .git, or lockfiles
#   - node_modules is opt-in, not default (see below)
#
# node_modules is excluded unless --include-node-modules is passed. _build is
# recreated by `dune build` with no network, but node_modules needs a package
# install, and kidsnote_web_inapp keeps yarn PnP packages under
# .yarn/unplugged/*/node_modules that a plain reinstall may not restore
# offline. Deleting those trades disk for a broken checkout.
#
# Reclaim is reported from df, not du. On APFS a cloned checkout shares
# blocks with its origin, so du counts the same bytes once per clone: the 24
# canary-*-20260820 playgrounds that du sized as part of a 314G total freed
# 0 GB when removed. Only the df delta is real.
#
# Usage:
#   ./scripts/cleanup-playground-builds.sh                        # dry run
#   ./scripts/cleanup-playground-builds.sh --apply
#   ./scripts/cleanup-playground-builds.sh --apply --include-node-modules
set -uo pipefail

# Sibling cleaners' convention: MASC_BASE_PATH, else cwd — never a
# HOME-anchored machine guess (audit-path-ssot).
PLAYGROUND="${MASC_BASE_PATH:-$(pwd)}/.masc/playground"
APPLY=0
WITH_NODE=0

for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --include-node-modules) WITH_NODE=1 ;;
    -h | --help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *)
      echo "unknown flag: $arg" >&2
      exit 2
      ;;
  esac
done

if [ ! -d "$PLAYGROUND" ]; then
  echo "no playground at $PLAYGROUND — nothing to do"
  exit 0
fi

# Directories a live build is sitting in. Only cwds inside the playground
# count: the runtime itself runs from the base path, and treating that as
# busy marks every artifact below it in use (first draft reported
# "162 removable, 0 in use" for exactly this reason).
busy=$(
  {
    pgrep -x dune 2>/dev/null
    pgrep -f 'ocamlopt|ocamlc|esbuild|vitest' 2>/dev/null
  } | sort -u | while read -r pid; do
    lsof -p "$pid" 2>/dev/null | awk '$4 == "cwd" { print $NF }'
  done | sort -u | grep "^$PLAYGROUND/" || true
)
if [ -n "$busy" ]; then
  echo "busy paths (skipped):"
  echo "$busy" | sed 's/^/  /'
fi

if [ "$WITH_NODE" = 1 ]; then
  name_filter=(\( -name '_build' -o -name 'target' -o -name 'node_modules' \))
else
  name_filter=(\( -name '_build' -o -name 'target' \))
fi

avail_before=$(df -k "$PLAYGROUND" | tail -1 | awk '{ print $4 }')
targets=$(find "$PLAYGROUND" -type d "${name_filter[@]}" -prune -print 2>/dev/null)

doomed=()
skipped=0
while IFS= read -r dir; do
  [ -z "$dir" ] && continue
  in_use=0
  while IFS= read -r b; do
    [ -z "$b" ] && continue
    case "$dir" in "$b"*) in_use=1 ;; esac
  done <<<"$busy"
  if [ "$in_use" = 1 ]; then
    skipped=$((skipped + 1))
    continue
  fi
  doomed+=("$dir")
done <<<"$targets"

echo "found $(( ${#doomed[@]} + skipped )) artifact dir(s): ${#doomed[@]} removable, $skipped in use"

if [ "${#doomed[@]}" -eq 0 ]; then
  exit 0
fi

if [ "$APPLY" = 0 ]; then
  printf '%s\n' "${doomed[@]:0:15}" | sed "s#$PLAYGROUND/#  #"
  [ "${#doomed[@]}" -gt 15 ] && echo "  ... and $(( ${#doomed[@]} - 15 )) more"
  echo
  echo "dry run — re-run with --apply to remove"
  exit 0
fi

for dir in "${doomed[@]}"; do
  rm -rf "$dir"
done

avail_after=$(df -k "$PLAYGROUND" | tail -1 | awk '{ print $4 }')
echo "removed ${#doomed[@]} dir(s)"
echo "reclaimed: $(( (avail_after - avail_before) / 1024 / 1024 )) GB"
df -h "$PLAYGROUND" | tail -1 | awk '{ print "now: used=" $3 " avail=" $4 " (" $5 ")" }'
