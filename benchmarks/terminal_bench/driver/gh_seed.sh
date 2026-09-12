# Shared bench helpers for seeding a per-keeper gh identity.
#
# remote_ssh preflight (keeper_sandbox_remote.perform_preflight) runs
# `gh auth status` with GH_CONFIG_DIR=<keeper root>/.config/gh and refuses
# keeper_up without a GitHub identity (remote_github_identity_missing).
# Both bootstrap.sh (keeper pool standup) and run_episode.sh (episode
# keepers) need the same seeded hosts.yml, so the one recipe lives here.

# seed_gh_hosts <keeper-name>
# Writes <root>/<keeper-name>/.config/gh/hosts.yml from ${GH_TOKEN}.
# No-op when GH_TOKEN is unset or empty.
seed_gh_hosts() {
  local keeper="$1"
  [[ -n "${GH_TOKEN:-}" ]] || return 0
  install -d -m 0700 "/root/${keeper}/.config/gh"
  printf '[REDACTED]\n    oauth_token: %s\n    [REDACTED]\n' \
    "${GH_TOKEN}" > "/root/${keeper}/.config/gh/hosts.yml"
  chmod 600 "/root/${keeper}/.config/gh/hosts.yml"
}
