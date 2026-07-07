---
title: "Keeper GitHub repo-create and Discussions policy"
status: Superseded
created: 2026-07-06
updated: 2026-07-07
author: codex
supersedes: []
superseded_by: "0309"
related: ["0008", "0160", "0254", "0255", "0309"]
implementation_prs: []
---

# Keeper GitHub repo-create and Discussions policy

Status: Superseded by RFC-0309 · Historical capability decision · G-WDECIDE

## 1. Decision

This document records the earlier disable decision. RFC-0309 supersedes it:
keeper execution may request reversible GitHub repository creation and GitHub
Discussions mutations through typed Shell IR plus non-blocking HITL approval.
They are not autonomous auto-run operations.

- GitHub PR and issue work remains supported through `Execute` with `gh` in a
  bound repository context.
- Reversible remote repository creation/fork/edit/sync/rename requests route to
  `Requires_approval` and enqueue a non-blocking HITL approval entry.
- Reversible GitHub Discussions create/comment/edit/close/reopen/lock/unlock
  requests route to `Requires_approval` and enqueue a non-blocking HITL approval
  entry.
- Repo delete, PR merge, destructive API calls, and irreversible discussion
  deletion remain denied by the trust-independent Shell IR floor.
- Durable workspace discussion still prefers MASC board tools unless the task
  explicitly requires a GitHub Discussion artifact.

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

The superseded disable decision was the smaller production decision before the
approval queue was wired into the Shell IR approval verdict:

- no new GitHub credential materialization path;
- no new cross-repo ownership model;
- no duplicate discussion plane beside MASC board;
- no prompt affordance that suggests an unsupported tool;
- no dependence on removing broad operator `repo` scope from local `gh` auth.

## 4. Current Enforcement

The current Shell IR path separates risk from capability policy:

- `gh repo create|fork|edit|sync|rename ...` -> `Requires_approval`
- `gh discussion create|comment|edit|close|reopen|lock|unlock|answer|unanswer ...`
  -> `Requires_approval`
- `gh api graphql` bodies containing durable repository/discussion create or
  comment mutations -> `Requires_approval`
- `gh repo delete`, `gh pr merge`, destructive REST/GraphQL deletes, and
  irreversible discussion deletion -> `Deny`

`Requires_approval` creates a pending HITL approval entry and returns immediately
to the keeper turn. The keeper must not block waiting for the operator decision;
resolution is delivered later through the HITL wake path.

## 5. Non-goals

- This decision does not remove the operator's local `repo` token scope.
- This decision does not add a dedicated repo-create tool; the surface remains
  typed `Execute` with `gh`.
- This decision does not allow autonomous repository creation or Discussion
  mutation without HITL approval.
- This decision does not change MASC board discussion semantics.

## 6. Verification

- `lib/exec/test/test_approval_policy.ml` proves autonomous approval emits
  `Ask` for durable reversible repo/discussion operations and still denies
  irreversible operations.
- `test/test_keeper_tool_execute_retry_deterministic_close.ml` proves the
  runtime helper enqueues a non-blocking pending approval entry for gh
  capability approval.
- Keeper capability docs and prompts state the decision directly: PR/issue work
  is supported, remote repo/discussion reversible mutations require HITL, and
  irreversible repo/discussion operations remain denied.
