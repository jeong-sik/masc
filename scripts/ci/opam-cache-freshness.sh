#!/usr/bin/env bash
set -euo pipefail

refresh_repository() {
  local exact_cache_hit="$1"
  case "${exact_cache_hit}" in
    true)
      echo "[opam-cache-freshness] exact dependency cache hit; repository refresh skipped"
      ;;
    false|"")
      echo "[opam-cache-freshness] fallback or empty dependency cache; refreshing repositories"
      opam update --repositories
      ;;
    *)
      printf '[opam-cache-freshness] invalid cache-hit value: %q\n' \
        "${exact_cache_hit}" >&2
      return 2
      ;;
  esac
}


if [[ "$#" -ne 2 || "$1" != "--refresh" ]]; then
  echo "usage: $0 --refresh <true|false|empty>" >&2
  exit 2
fi
refresh_repository "$2"
