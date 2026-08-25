---
rfc: "per-keeper-github-cli-identity"
status: Draft
---

# RFC: Keeper-specific GitHub CLI identity

Status: Draft

## Problem

Keeper processes can receive `GH_TOKEN` through secret projection, but they do
not have an explicit, operator-controlled GitHub CLI account store. Reusing the
host user's default `~/.config/gh` or Keychain makes identity depend on account
selection outside MASC. Parsing `gh auth status` also does not prove which
account an actual Keeper command will use.

## Decision

Each Keeper owns exactly one GitHub CLI config directory:

```text
<base>/.masc/keepers/<keeper>/github-cli/
```

Local Keeper commands receive this path as `GH_CONFIG_DIR`. Docker Keeper
commands receive the same directory read-only at:

```text
/tmp/masc-runtime/.masc/keepers/<keeper>/github-cli/
```

The host-side operator login is the only writer. A login runs:

```text
gh auth login --hostname HOST --git-protocol https --skip-ssh-key --web --insecure-storage
```

The login environment removes `GH_TOKEN`, `GITHUB_TOKEN`,
`GH_ENTERPRISE_TOKEN`, and `GITHUB_ENTERPRISE_TOKEN`. Normal Keeper execution
does not remove them. GitHub CLI's standard precedence remains intact, so an
explicitly projected token may override the stored account.

The Dashboard reports two direct observations using
`gh api --hostname HOST user --jq .login`:

- `stored`: Keeper config directory with GitHub token variables removed.
- `effective`: the exact Keeper runtime environment, including projected tokens.

No output regex or `gh auth status` prose determines authentication state.

## Operator surfaces

```text
masc keeper-github login --keeper NAME [--hostname HOST] [--base-path PATH]
masc keeper-github status --keeper NAME [--hostname HOST] [--base-path PATH]
masc keeper-github logout --keeper NAME [--hostname HOST] [--base-path PATH]
```

The Keeper config panel (권한·샌드박스 tab) exposes status, refresh, and
`GitHub 로그인`. The POST
response streams secret-redacted stdout/stderr from `gh`. The browser only
recognizes generic HTTP URLs for links; it does not parse device codes or GitHub
prose. Closing the modal aborts the request.

## Explicit non-goals

- No import or migration from host `~/.config/gh`, Keychain, or old paths.
- No fallback to a host account.
- No login lease, claim, settlement, registry, TTL, polling worker, or confirmation gate.
- No cached authentication verdict.
- No duplicate secret store. `.masc/secrets/<keeper>` remains the token projection surface.
- No provider/plugin facade in this change.

## Failure behavior

An absent credential is observable, not a Keeper lifecycle admission gate.
General Local and Docker tool execution continues without creating or repairing
identity state, while `GH_CONFIG_DIR` still names the deterministic Keeper path
so the host account is never reused. Malformed or unsafe identity state is a
typed execution error and is not collapsed into absence. GitHub commands fail
according to `gh`. A failed Dashboard login ends its stream and leaves the
Keeper runnable. Projected tokens are visible by name only, never by value.
