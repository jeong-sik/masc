# RFC-0008: Keeper Credential Provider

- **Status**: Retired.
- **Author**: vincent (with Agent-LLM-A)
- **Created**: 2026-04-24
- **Retired**: 2026-06-02
- **Related**: F-1 (#9843), F-2 (#9844), F-4 (#9847)

## 1. Retirement

Keeper execution no longer has a keeper-side GitHub credential provider, repo
identity resolver, host config bridge, in-container login bridge, or
credentialed Docker mount path.

Repository git operations use the ordinary repository URL plus a
non-interactive git environment. Keeper sandbox behavior is not selected from
GitHub account identity, repo CLI identity, or repo mutation policy.

Auth credentials remain a separate bearer-token/admin-token storage concern and
are not part of this retired repository identity design.

## 2. Replacement Contract

- Repository registration stores repository metadata only.
- Keeper-repository mapping grants repository access only.
- Git commands fail normally when the ambient environment cannot access the
  remote.
- No dashboard or HTTP API exists for repository GitHub credential
  materialization.

This RFC is kept only as a historical marker for the deleted design.
