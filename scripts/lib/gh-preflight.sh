#!/usr/bin/env bash
# Shared GitHub CLI readiness checks for PR audit scripts.
#
# Keep this helper side-effect-free: it only proves that gh exists, that the
# active credentials resolve an identity, and that the target repository is
# readable before an audit script starts making PR-specific decisions.

gh_preflight_die() {
  echo "ERROR: $*" >&2
  exit 2
}

gh_preflight_require_cli() {
  command -v gh >/dev/null 2>&1 || gh_preflight_die "GitHub CLI 'gh' is required"
}

gh_preflight_check_auth() {
  local status_output

  if ! command -v gh >/dev/null 2>&1; then
    echo "GitHub CLI 'gh' is required" >&2
    return 2
  fi

  if ! status_output="$(gh auth status --hostname github.com 2>&1)"; then
    echo "gh auth is not usable for github.com; refresh credentials before running PR audit. Details: ${status_output}" >&2
    return 2
  fi
}

gh_preflight_require_auth() {
  gh_preflight_check_auth || exit 2
}

gh_preflight_check_repo_read() {
  local repo="$1"
  local repo_output

  if [[ -z "$repo" || "$repo" != */* ]]; then
    echo "repo must be owner/name, got: ${repo:-<empty>}" >&2
    return 2
  fi

  gh_preflight_check_auth || return 2

  if ! repo_output="$(gh api "repos/$repo" --jq .full_name 2>&1)"; then
    echo "gh credentials are authenticated but cannot read repo ${repo}; check token repository permissions before PR audit. Details: ${repo_output}" >&2
    return 2
  fi
}

gh_preflight_require_repo_read() {
  gh_preflight_check_repo_read "$1" || exit 2
}

gh_preflight_shared_repo_root() {
  local common_dir
  common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || git rev-parse --git-common-dir 2>/dev/null || true)"
  if [[ -n "$common_dir" && -d "$common_dir" ]]; then
    (cd "$common_dir/.." && pwd -P)
  else
    pwd -P
  fi
}

gh_preflight_cache_root() {
  # Allow CI runners or local multi-repo setups to redirect the audit cache.
  if [ -n "${MASC_GH_PR_AUDIT_CACHE_ROOT:-}" ]; then
    printf '%s\n' "$MASC_GH_PR_AUDIT_CACHE_ROOT"
  else
    printf '%s/.masc/cache/gh-pr-audit\n' "$(gh_preflight_shared_repo_root)"
  fi
}

gh_preflight_cache_ttl_sec() {
  local default_ttl="${1:-3600}"
  local ttl="${MASC_GH_PR_AUDIT_CACHE_TTL_SEC:-$default_ttl}"
  if [[ ! "$ttl" =~ ^[0-9]+$ ]]; then
    gh_preflight_die "MASC_GH_PR_AUDIT_CACHE_TTL_SEC must be a non-negative integer, got: $ttl"
  fi
  printf '%s\n' "$ttl"
}

gh_preflight_cache_segment() {
  printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._=-' '_'
}

gh_preflight_cache_path() {
  local kind="$1"
  local repo="$2"
  local key="$3"
  printf '%s/%s/%s/%s.json\n' \
    "$(gh_preflight_cache_root)" \
    "$(gh_preflight_cache_segment "$kind")" \
    "$(gh_preflight_cache_segment "$repo")" \
    "$(gh_preflight_cache_segment "$key")"
}

gh_preflight_file_mtime() {
  local path="$1"
  stat -f %m "$path" 2>/dev/null || stat -c %Y "$path" 2>/dev/null
}

gh_preflight_cache_load_fresh() {
  local path="$1"
  local ttl_sec="$2"
  local now
  local mtime

  [[ -f "$path" ]] || return 1
  mtime="$(gh_preflight_file_mtime "$path")" || return 1
  now="$(date +%s)"
  if ((now - mtime > ttl_sec)); then
    return 1
  fi
  cat "$path"
}

gh_preflight_cache_store() {
  local path="$1"
  local payload="$2"
  local tmp

  mkdir -p "$(dirname "$path")"
  tmp="${path}.$$"
  printf '%s\n' "$payload" > "$tmp"
  mv "$tmp" "$path"
}
