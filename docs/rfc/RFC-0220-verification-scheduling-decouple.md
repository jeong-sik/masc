---
rfc: "0220"
title: "Withdraw cross-Keeper verification scheduling"
status: Withdrawn
created: 2026-06-09
updated: 2026-08-02
author: vincent
supersedes: []
superseded_by: null
related: ["0221", "0323"]
implementation_prs: []
---

# RFC-0220: Withdraw cross-Keeper verification scheduling

## Decision

The proposed verifier-claim pool and cross-Keeper verification dispatch are
withdrawn. Git history retains the original diagnosis and proposal; they are
not kept in the active design corpus because they describe the opposite of the
current typed contract.

An `AwaitingVerification` task is a pending completion-authority obligation,
not Keeper work. It cannot be claimed by a Keeper and never grants verifier
authority through task ownership. The configured system LLM agent, or an
authenticated HITL operator, commits the verdict through the completion-
authority boundary.

Current SSOT:

- [`verification-pipeline-policy.md`](../verification-pipeline-policy.md)
- `Masc_domain.task_claim_decision_for_status`
- `Workspace_task_lifecycle.resolve_claim`
- `Workspace.commit_verdict_r`

The still-valid atomic persistence ordering is documented separately in
[RFC-0221](./RFC-0221-atomic-verification-submission.md).
