# RFC-0019: Keeper Credential Unification

- **Status**: Withdrawn.
- **Author**: vincent (with Agent-LLM-A Opus 4.7 1M, exploratory session)
- **Created**: 2026-04-30
- **Withdrawn**: 2026-06-02
- **Related**: RFC-0008, PR #10660, PR #12304

## 1. Withdrawal

The repository credential unification model was removed instead of completed.
The replacement is simpler: MASC does not keep a repo GitHub identity registry
or materialize per-repository login state.

Keeper execution receives no special GitHub credential provider based on repo,
keeper, sandbox, or CLI identity. Repository git operations use registered
repository metadata and an ordinary non-interactive git environment.

## 2. Replacement Contract

- Repository config has no credential binding field.
- Keeper-repository mapping controls only repository access.
- Dashboard has no repository credential settings surface.
- HTTP repository routes do not expose credential routes.
- GitHub authentication remains outside repo-manager policy.

This file remains only to document why the prior unification plan is not an
active design target.
