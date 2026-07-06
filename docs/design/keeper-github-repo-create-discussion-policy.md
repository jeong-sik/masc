---
title: "Keeper GitHub repo-create and Discussions policy"
status: Draft
created: 2026-07-06
updated: 2026-07-06
author: codex
supersedes: []
superseded_by: null
related: ["0008", "0160", "0254", "0255"]
implementation_prs: []
---

# Keeper GitHub repo-create and Discussions policy

Status: Draft · Capability decision · G-WDECIDE

## 1. Decision

Keeper autonomous execution does not expose GitHub repository creation or
GitHub Discussions mutation as supported capabilities.

- GitHub PR and issue work remains supported through `Execute` with `gh` in a
  bound repository context.
- Remote repository creation is disabled for keepers. Operators may still create
  repositories outside keeper autonomous execution.
- GitHub Discussions mutation is disabled for keepers. Durable workspace
  discussion stays on MASC board tools, which are typed, observable, and scoped
  to the workspace.

The generic `gh` execution path must fail closed for this decision. A command
that would create a remote GitHub repository or mutate GitHub Discussions is
classified as a repository-hosting policy floor violation, not as an ordinary
reversible mutation.

## 2. Evidence

- [근거] `gh auth status --hostname github.com` on 2026-07-06T10:29:25+09:00,
  confidence High: the active operator account currently has `repo` scope. Scope
  availability is therefore not enough to define keeper capability.
- [근거] `gh api graphql -f query='{__schema{mutationType{fields{name}}}}'` on
  2026-07-06T10:29:25+09:00, confidence High: the live GitHub GraphQL schema
  includes `createRepository`, `cloneTemplateRepository`, `createDiscussion`,
  `addDiscussionComment`, `updateDiscussion`, `deleteDiscussion`, and related
  discussion mutations.
- [근거] Source inspection on 2026-07-06T10:29:25+09:00, confidence High:
  `docs/KEEPER-CAPABILITY-MATRIX.md` documents PR/issue work through `gh`, board
  tools already own durable workspace discussion, and `RFC-0008` retired the
  keeper-side GitHub credential provider.

## 3. Rationale

Repository creation and GitHub Discussions create durable remote surfaces whose
ownership, lifecycle, and moderation policy are not represented in the current
keeper tool contracts. Leaving them reachable only because an ambient `gh` token
has broad scope is a silent capability decision.

Disabling both surfaces is the smaller production decision:

- no new GitHub credential materialization path;
- no new cross-repo ownership model;
- no duplicate discussion plane beside MASC board;
- no prompt affordance that suggests an unsupported tool;
- no dependence on removing broad operator `repo` scope from local `gh` auth.

## 4. Enforcement

The Shell IR repo-hosting classifier treats these forms as R2/policy-floor
operations:

- `gh repo create ...`
- `gh repo fork ...`
- `gh discussion create|comment|edit|delete|close|reopen|lock|unlock|answer|unanswer ...`
- `gh api graphql` bodies containing the live GitHub mutation names for
  repository creation or Discussions mutation.

The deny reason remains `Destructive_repo_hosting_cli` because the floor is the
same remote repository-hosting policy boundary used for irreversible PR/repo
operations. The user-facing text states that the operation is not permitted by
policy.

## 5. Non-goals

- This decision does not remove the operator's local `repo` token scope.
- This decision does not add a dedicated repo-create tool.
- This decision does not add GitHub Discussions read or write tools.
- This decision does not change MASC board discussion semantics.

## 6. Verification

- `test/test_shell_ir_risk.ml` proves `gh repo create`, `gh repo fork`,
  `gh discussion create/comment`, `createRepository`, `cloneTemplateRepository`,
  `createDiscussion`, and `addDiscussionComment` classify as R2.
- `lib/exec/test/test_shell_ir_risk_repo_hosting_cli_stress.ml` covers the
  direct repo-hosting classifier.
- `lib/exec/test/test_approval_policy.ml` proves autonomous approval denies
  repo-create, repo-fork, discussion-create, and GraphQL create mutations.
- Keeper capability docs and prompts state the decision directly: PR/issue work
  is supported, while remote repo creation and GitHub Discussions mutation are
  not keeper affordances.
