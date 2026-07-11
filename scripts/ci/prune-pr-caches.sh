#!/usr/bin/env bash
#
# prune-pr-caches.sh — delete GitHub Actions caches that no run can ever
# restore again.
#
# Actions caches are ref-scoped: an entry stored under refs/pull/N/merge is
# visible only to runs of pull request N. Once that PR closes, the entry is
# unreachable, yet it keeps consuming the repository's 10 GB cache quota until
# GitHub evicts it (LRU) or it ages out after 7 days. Because eviction is
# repo-wide, those dead bytes push out the caches that PRs actually restore
# from (the ones stored on refs/heads/main).
#
# Modes:
#   CLOSED_PR=<n>   delete every cache under refs/pull/<n>/merge
#   (unset)         sweep: delete caches for every pull-request ref whose PR
#                   is no longer open
#
# Reopening a pruned PR costs one cold rebuild; nothing is lost, because cache
# entries are content-addressed build artifacts.
#
# Requires: gh with a token holding `actions: write`.

set -euo pipefail

: "${GH_REPO:?GH_REPO must be set (owner/repo)}"

CLOSED_PR="${CLOSED_PR:-}"

# Cache metadata for the repository, one "id<TAB>ref<TAB>size" row per entry.
list_caches() {
  local page=1
  while :; do
    local rows
    if ! rows="$(gh api "repos/${GH_REPO}/actions/caches?per_page=100&page=${page}" \
      -q '.actions_caches[] | "\(.id)\t\(.ref)\t\(.size_in_bytes)"')"; then
      echo "failed to list Actions caches at page ${page}" >&2
      return 1
    fi
    [ -z "${rows}" ] && break
    printf '%s\n' "${rows}"
    page=$((page + 1))
  done
}

delete_cache() {
  gh api --method DELETE "repos/${GH_REPO}/actions/caches/$1" --silent
}

pr_number_of_ref() {
  # refs/pull/1234/merge -> 1234 ; anything else -> empty
  printf '%s' "$1" | sed -n 's|^refs/pull/\([0-9][0-9]*\)/merge$|\1|p'
}

pr_state() {
  local state
  if ! state="$(gh api "repos/${GH_REPO}/pulls/$1" -q '.state')"; then
    echo "failed to read pull request $1 state" >&2
    return 1
  fi
  case "${state}" in
    open|closed) printf '%s\n' "${state}" ;;
    *)
      echo "unexpected pull request $1 state: ${state}" >&2
      return 1
      ;;
  esac
}

freed=0
deleted=0
if ! cache_rows="$(list_caches)"; then
  exit 1
fi

if [ -n "${CLOSED_PR}" ]; then
  target_ref="refs/pull/${CLOSED_PR}/merge"
  echo "pruning caches for ${target_ref}"
  while IFS=$'\t' read -r id ref size; do
    [ "${ref}" = "${target_ref}" ] || continue
    delete_cache "${id}"
    freed=$((freed + size))
    deleted=$((deleted + 1))
  done <<< "${cache_rows}"
else
  echo "sweeping caches whose pull request is no longer open"
  # Memoise PR state so a PR with several caches costs one API call.
  open_prs=""
  closed_prs=""
  while IFS=$'\t' read -r id ref size; do
    pr="$(pr_number_of_ref "${ref}")"
    [ -n "${pr}" ] || continue
    case " ${open_prs} " in *" ${pr} "*) continue ;; esac
    case " ${closed_prs} " in
      *" ${pr} "*) ;;
      *)
        if ! state="$(pr_state "${pr}")"; then
          exit 1
        fi
        if [ "${state}" = "open" ]; then
          open_prs="${open_prs} ${pr}"
          continue
        fi
        closed_prs="${closed_prs} ${pr}"
        ;;
    esac
    delete_cache "${id}"
    freed=$((freed + size))
    deleted=$((deleted + 1))
  done <<< "${cache_rows}"
fi

echo "deleted ${deleted} cache entries, reclaimed $((freed / 1048576)) MiB"
