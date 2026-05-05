# masc-mcp Roadmap

> Current package version: v0.19.8
> Latest release: v0.19.8 (2026-05-05)
> Updated: 2026-05-05

This roadmap is the 6-8 week operating view for `masc-mcp`.
For the product promise and GitHub operating model, see [docs/PRODUCT-OPERATING-PLAN.md](docs/PRODUCT-OPERATING-PLAN.md).
For historical feature-train rules and release intake background, see [docs/VERSIONED-ROADMAP.md](docs/VERSIONED-ROADMAP.md).

## Product Promise

`masc-mcp` is a repo-local MCP server for coordinating multiple coding agents inside one repository.

Promise levels:

- Front door: repo coordination
- Supporting: dashboard and operator visibility
- Deferred or experimental: broad research surfaces, extraction work, and deep architecture cleanup

## Active 6-8 Week Tracks

| Track | Goal | Why now | Primary references |
|------|------|---------|--------------------|
| Product truth and onboarding | Make the product easy to describe and start correctly | front-door docs and product posture are still fragmented | `README.md`, `docs/PRODUCT-OPERATING-PLAN.md`, `docs/PRODUCT-REVIEW.md` |
| GitHub as operating system | Make issues, PRs, and releases reflect product reality instead of drifting | `type:*` exists, but `target:*` and release blockers are not consistently enforced | `.github/ISSUE_TEMPLATE/*`, `.github/workflows/*`, `CONTRIBUTING.md` |
| Promise hardening | Tighten the parts of the product users actually depend on first | CI truth, transport truth, config visibility, and release truth are blocking trust | `CHANGELOG.md`, `docs/spec/C-implementation-status.md`, open issues below |

## target:now

Items that directly affect the current product promise:

- CI truth and merge gates
  - `#3418` quick-suite Eio regression
  - `#3404` missing `ripgrep` in lint
  - `#3396` shared quick-suite regression tracker
- Transport and health truth
  - `#3408` gRPC / WS discovery says `listening=false` while the transport is reachable
- Config visibility foundation
  - `#3364` centralize env config
  - `#3365` dashboard config introspection
  - `#3363` deduplicate env vars
- Product and release truth
  - README / roadmap / changelog alignment
  - issue / PR / release hygiene automation

## target:next

Items that improve advanced workflows after the front-door promise is cleaner:

- auth and API contract hardening for non-local operation
-   - ready-to-delegate contract
  - verifier turn-budget reliability
  - clearer runtime / model visibility in proof
- richer operator diagnosis bundles and deeper read confidence

## target:later

Important work that stays visible but does not drive the next 6-8 weeks:

- wide extraction and package separation
  - `masc-games`
  - kitchen-sink breakup
  - large module decomposition
- deep Eio and architecture cleanup
  - global mutable state reduction
  - actor/message-passing conversions
  - broad interface and error-pipeline refactors
- speculative distribution and platform work
  - binary distribution
  - cluster mode
  - chaos framework

## Release Lane Rules

- The active release line is pre-1.0: `0.y.0` opens a user-visible train and `0.y.z` stabilizes it.
- Do not open `1.0.0` until repo coordination, release truth, and the core operator path are trustworthy without caveats.
- Historical `v2.*` tags remain audit history only; they do not define the active SemVer policy.
- Do not tag a release while `release-blocker` issues remain open.
- Do not tag a release while version truth is broken across `dune-project`, `masc_mcp.opam`, `ROADMAP.md`, and `CHANGELOG.md`.
- Prefer `target:now`, `target:next`, and `target:later` over vague backlog buckets.

## Completed Reference Points

See [CHANGELOG.md](CHANGELOG.md) for release-by-release details.

| Version | Theme | Key deliverables |
|--------|-------|------------------|
| v0.3.0 | Release line reset | restart SemVer at pre-1.0, skip already-used `v0.1.x`, freeze legacy `v2.*` line, and teach release automation about the new series |

Legacy `v2.*` reference points:

| Version | Theme | Key deliverables |
|--------|-------|------------------|
| v2.87.0 | Release closeout | CI green, changelog honesty, worktree cleanup |
| v2.91.0 | Immortal Base | supervision, health, graceful shutdown |
| v2.92.0 | Product Portfolio Trim | explicit keep / archive decisions for experimental surfaces |
| v2.93.0-v2.158.0 | Incremental | see changelog and product operating plan |

## Design References

- [docs/PRODUCT-OPERATING-PLAN.md](docs/PRODUCT-OPERATING-PLAN.md)
- [docs/PRODUCT-REVIEW.md](docs/PRODUCT-REVIEW.md)
- [docs/ARCHITECTURE-COMPLEXITY-ANALYSIS.md](docs/ARCHITECTURE-COMPLEXITY-ANALYSIS.md)
- [docs/IMMORTAL-SERVER-ROADMAP.md](docs/IMMORTAL-SERVER-ROADMAP.md)
- [docs/spec/SPEC-INDEX.md](docs/spec/SPEC-INDEX.md)
 
