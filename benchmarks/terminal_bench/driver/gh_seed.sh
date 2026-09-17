# Shared bench helpers for seeding a per-keeper gh identity.
#
# A keeper has a GitHub identity only when this writes its hosts.yml. The
# remote_ssh preflight (keeper_sandbox_remote.perform_preflight) runs
# `gh auth status` with GH_CONFIG_DIR=<keeper root>/.config/gh only for an
# endpoint that has one, and skips the identity step otherwise (#35412).
# Both bootstrap.sh (keeper pool standup) and run_episode.sh (episode
# keepers) seed the same way, so the one recipe lives here.

# seed_gh_hosts <keeper-name>
# Writes <root>/<keeper-name>/.config/gh/hosts.yml from ${GH_TOKEN}.
# No-op when GH_TOKEN is unset or empty.
seed_gh_hosts() {
  local keeper="$1"
  [[ -n "${GH_TOKEN:-}" ]] || return 0
  install -d -m 0700 "/root/${keeper}/.config/gh"
  # Canonical gh hosts.yml shape (measured 2026-09-14): a `github.com:` root
  # with nested user/oauth_token/git_protocol parses cleanly, while a
  # template littered with `[REDACTED]` literals makes gh itself die with
  # "invalid config file ... invalid format" — which remote_ssh preflight
  # (gh auth status) treats as remote_github_identity_missing. Keep this
  # shape invariant when touching the template.
  printf 'github.com:\n    user: %s\n    oauth_token: %s\n    git_protocol: https\n' \
    "bench-${keeper}" "${GH_TOKEN}" > "/root/${keeper}/.config/gh/hosts.yml"
  chmod 600 "/root/${keeper}/.config/gh/hosts.yml"
}
