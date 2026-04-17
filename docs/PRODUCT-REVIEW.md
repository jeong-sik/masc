---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/keeper/keeper_keepalive.ml
  - lib/keeper/keeper_supervisor.ml
  - lib/mcp_server.ml
---

# MASC-MCP Product Review

## Summary

- As a repo-coordination OSS product, `masc-mcp` is already useful.
- As a supervised delivery swarm, it is promising but still an advanced path.
- As a remote or internal-ops product, it is still held back by auth posture, API contract truth, and release hygiene.

The main problem is no longer “there is no product here.” The main problem is that the explanation layers, release truth, and hardening priorities were wider than the front-door promise.

Keeper continuity now fits the same pattern: it is real enough to design and validate, but it should stay a bounded advanced feature until checkpoint truth and readiness evidence are closed.

## Product Posture by Promise Level

### 1. Repo coordination

Current judgment: pass

Why:

- room and task ownership are real
- broadcasts, worktrees, and file-lock style coordination are real
- the basic single-machine coding workflow is already useful

What still matters:

- required CI gates must stay truthful
- docs must keep the front door narrow and clear

### 2. Supervised delivery swarm

Current judgment: usable, but advanced

Why:

- Team Session + Supervisor is real
- operator digest and proof flows exist
- planner / implementer / supervisor split is already a practical path

What still blocks wider trust:

- ready-to-delegate ergonomics
- verifier turn-budget reliability
- runtime/model visibility in reports and proof

### 3. Dashboard and operator visibility

Current judgment: useful, but supporting rather than front-door

Why:

- dashboard read paths and operator surfaces exist
- current views help with coordination and diagnosis

What still blocks stronger promises:

- transport health can disagree with real reachability
- config introspection exists, but the read contract is split and not yet strong enough to treat as a clean SSOT
- some read paths still need stronger truth guarantees

### 4. Remote-safe or ops-grade posture

Current judgment: not ready as a product promise

Why:

- auth defaults still rely too much on trusted-network assumptions
- REST and SSE contracts are not yet crisp enough for stronger product claims
- release and documentation truth have drifted too often

## Front-Door Blockers

These are the blockers for the current product promise, not for every possible future posture.

- required CI truth must stay green and believable
- transport and health read models must match reachable runtime state
- package version, roadmap, and changelog truth must not drift
- GitHub issue / PR / release flow must reflect the product promise instead of a mixed backlog

## Advanced-Path Blockers

These matter after the repo-coordination front door is clean.

- auth hardening for non-local operation
- REST API contract versioning and error-shape discipline
- delivery-swarm ergonomics for delegation, verification, and operator diagnosis
- bounded keeper continuity contract plus checkpoint/readiness evidence
- richer config and runtime visibility for operators

## Security Posture

Historical security audit (SECURITY-AUDIT.md, 2025-02-02, verified 2026-02-17) identified:
- 2 Critical severity issues: **RESOLVED** (cryptographically unsafe token generation, command injection)
- 4 High severity issues (fail-open authorization, disabled auth defaults, shell command injection)
- Multiple Medium/Low severity issues

Current security-sensitive areas requiring attention:
- Auth defaults for non-loopback binds
- Token generation for bearer auth
- Room token validation
- Shell command construction in worktree operations
- Path traversal prevention in static asset serving

Security posture remains appropriate for trusted-network, repo-local use. Remote exposure requires explicit auth configuration and hardening.

See `docs/spec/09-server-transport.md` for remote auth semantics and `docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md` for the current operator auth bootstrap path.

## Judgment

- **Repo-local multi-agent coordination**: ready to describe and use
- **Supervised delivery swarm**: real and worth documenting, but not the first promise
- **Keeper continuity**: should be described as checkpoint-backed same-trace continuity, not as general memory
- **Remote or ops-grade product story**: still incomplete and should remain explicit about its gaps

The next useful re-evaluation gate is:

`truthful CI + truthful transport health + truthful release/docs + stable GitHub operating loop`
