---
rfc: "0312"
title: "Keeper repo mappings are advisory default scope, not access caps"
status: Accepted
created: 2026-07-07
updated: 2026-07-07
author: vincent + codex
supersedes: []
superseded_by: null
related: ["0104", "0219", "0305", "0309"]
implementation_prs:
  - "#23359"
---

# RFC-0312: Keeper repo mappings are advisory default scope, not access caps

## 1. Problem

Keeper repository mappings were treated as if they were an authorization
boundary: a registered repository outside a keeper's mapping could be denied,
and a missing or malformed mapping could lock a keeper out of otherwise valid
work. That makes `keeper_repo_mappings.toml` a hidden cap on operator-approved
repository registration.

The cap also creates a bad recovery shape. A keeper can be blocked from the
repository that contains the fix for the mapping, and the system must invent a
repo-claim HITL path for a state that is not a real security decision.

## 2. Decision

`keeper_repo_mappings.toml` is advisory/default-scope metadata only. It answers
"which registered repositories should this keeper see first?" It does not
answer "which registered repositories may this keeper access?"

The hard access boundary is the registered repository catalog plus repository
identity validation:

- A registered repository is accessible to a keeper even when it is outside the
  keeper's advisory mapping.
- `repositories = ["*"]` selects every registered repository as default scope.
- A selected repository list narrows display/default scope only.
- An explicit empty mapping selects no default repositories without denying
  access.
- A missing or malformed mapping file degrades to default-scope behavior and is
  observable via metrics/logs; it must not deny registered repository access.
- Unregistered repository IDs, malformed repository catalogs, repository-store
  load failures, and registered-path identity mismatches fail closed.

Repo-claim HITL is intentionally retired for registered repository access.
There is no claimable lease for a registered repository that has already passed
catalog and identity checks. Unregistered repositories remain denied rather than
being converted into an approval prompt.

## 3. Security boundary

This RFC narrows the meaning of keeper mappings; it does not make every
operation safe to run. Operation safety remains owned by the tool and command
policy layers:

- Repository registration and identity checks decide whether a filesystem path
  is a known repository.
- Destructive filesystem and shell operations remain gated by the existing
  execution policy.
- GitHub mutation capability is governed by the typed capability-policy axis in
  RFC-0309, not by keeper repo mappings.

Mutable checkout metadata, including a playground clone's `.git/config` remote
URLs, must not authorize repository identity. It can inform diagnostics, but it
is not a substitute for the registered catalog and identity check.

## 4. Consequences

Positive:

- Keepers are no longer locked out by stale or absent advisory scope metadata.
- The operator-facing repository catalog remains the single source of truth for
  repository access.
- Dashboard/default-repo selection can stay ergonomic without becoming a hidden
  authorization system.

Trade-offs:

- A keeper with repository-capable tools can operate on any registered
  repository unless another tool-policy layer denies the specific operation.
- Operators must treat repository registration as the point where repository
  access enters the system.

## 5. Verification

PR #23359 implements this decision with regression coverage:

- `test/test_keeper_repo_mapping.ml` covers registered repositories outside an
  advisory mapping, wildcard mappings, missing mappings, malformed mappings,
  unregistered repository denial, repository-store failures, and identity
  mismatches.
- `test/test_keeper_repo_claim_hitl.ml` covers the retired claim-flow behavior:
  registered repositories outside advisory scope are allowed, while
  unregistered repositories remain fail-closed.
- `test/test_playground_repo_readiness.ml` covers registered repository policy
  and mapping-load-error behavior in playground readiness.
- `docs/repo-migration-guide.md` documents the operator-facing migration
  semantics.
