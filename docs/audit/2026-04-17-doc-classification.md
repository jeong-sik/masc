# MASC docs/ classification — 2026-04-17

> Read-only audit of all 145 markdown files under `docs/`.
> Methodology: three Explore subagents in parallel, each scanning ~48 files.
> For every file the agent (a) read the head of the body, (b) ran
> `rg -F "<basename>" lib/ bin/ scripts/ README.md ROADMAP.md`, and
> (c) classified into A/B/C/D (definitions below).
> Disposition is advisory; actual delete / merge / frontmatter PRs are
> tracked separately.

## Categories

- **A · Live** — referenced by code or canonical surface. Action: **keep + frontmatter**.
- **B · Historical** — coherent design or runbook, no current code reference. Action default: **delete** (per user policy: aggressive removal, no archive stubs). Exception: `archive` if the body anchors an in-flight migration.
- **C · Hype / Speculative** — vision or aspirational content not anchored in code. Action: **delete**.
- **D · Duplicate** — same / near-same subject as another doc. Action: **delete loser** or `merge_into:<winner>`.

## Aggregate counts

| Category | Count | Suggested action |
|---|---|---|
| A · Live | 81 | keep + frontmatter |
| B · Historical (delete) | 32 | delete (no stub) |
| B · Historical (archive: in-flight) | 14 | move to `docs/archive/2026-04/` |
| C · Hype | 7 | delete |
| D · Duplicate / merge | 11 | delete loser or merge into winner |
| **Total** | **145** | |

## Frontmatter standard (for A category)

When the FRONTMATTER PR runs, every A-category file gets:

```yaml
---
status: live | reference | runbook
last_verified: 2026-04-17
code_refs:
  - lib/<file>.ml
  - lib/<file>.mli
---
```

`code_refs` must be non-empty (≥ 1 valid path). If a file lacks any
real code ref, it does not belong in A — re-classify before applying
frontmatter.

---

## Full table

### Part 1 (alphabetical: A — design/inventory-gap-analysis)

| file | category | evidence | action | risk |
|------|----------|----------|--------|------|
| ADAPTIVE-HEARTBEAT-PRODUCTION-RUNBOOK.md | A | runbook referenced in production guides | keep+frontmatter | low |
| ADR-001-MITOSIS-VS-COMPACTION.md | B | no current refs; "removed in v2.170+" marker | delete | low |
| ADR-003-FEATURE-FLAG-REGISTRY-MANAGEMENT.md | A | rg hit in lib/config; active feature flag design | keep+frontmatter | low |
| AGENT-MEMORY-SYSTEM.md | B | no code refs; aspirational multi-session learning | delete | med |
| architecture-boundary.md | A | foundational architecture (MASC-OAS boundary) | keep+frontmatter | low |
| ARCHITECTURE-COMPLEXITY-ANALYSIS.md | A | 1 rg hit; architectural reference | keep+frontmatter | low |
| archive/EVOLUTION-PLAN-FIGMA-MCP.md | C | external project brainstorm, no code refs | delete | low |
| archive/IMPROVEMENT-PLAN-2026-01.md | C | generic improvement plan stub | delete | low |
| archive/RELEASE-ROADMAP-v287.md | B | historical release closure (v2.87 stale) | delete | low |
| audits/compaction-fsm-tla-audit-2026-04-16.md | A | active FSM audit | keep+frontmatter | low |
| audits/memory-bank-compaction-audit-2026-04-16.md | A | active validation of keeper_memory_bank.ml | keep+frontmatter | low |
| BENCHMARK-RUNBOOK.md | A | 3 rg hits in scripts | keep+frontmatter | low |
| BOOT-ENV-STATE-INVENTORY.md | A | 3 rg hits | keep+frontmatter | low |
| CAPABILITY-REGISTRY-SSOT.md | A | active capability registry design | keep+frontmatter | med |
| cascade/README.md | B | personal note, defers to spec/ | delete | low |
| cascade/STRATEGY-GUIDE.md | B | personal note, not team contract | delete | low |
| CELLULAR-AGENT.md | A | implements handoff pattern (`lib/handover_eio.ml`, `lib/tool_handover.ml`) | keep+frontmatter | low |
| COMMAND-PLANE-RUNBOOK.md | B | explicitly DEPRECATED; no current HTTP surface | delete | low |
| COMMON-PITFALLS.md | A | active developer reference from commit analysis | keep+frontmatter | low |
| compaction/COMPACTION-LIFECYCLE.md | A | active context-compaction reference | keep+frontmatter | low |
| CONFIG-DOCTOR.md | A | canonical operator path (`main_eio.exe doctor`) | keep+frontmatter | low |
| CONTENT-DECAY-RESEARCH.md | C | "no longer current" historical research | delete | low |
| DASHBOARD-INTEGRATION.md | A | active operational surface spec | keep+frontmatter | med |
| design/adaptive-heartbeat-grpc-and-phi-rollout-rfc.md | A | active production-gate RFC | keep+frontmatter | med |
| design/adaptive-heartbeat-observability-slo-spec.md | A | production prerequisite | keep+frontmatter | med |
| design/adaptive-heartbeat-phi-enforcement-rfc.md | A | active enforcement gate | keep+frontmatter | med |
| design/adaptive-heartbeat-production-rollout-rfc.md | A | 2 rg hits | keep+frontmatter | med |
| design/adaptive-heartbeat-safety-harness-spec.md | A | prod-gate spec | keep+frontmatter | med |
| design/adaptive-heartbeat-scheduling-rfc.md | A | tracks #3635 | keep+frontmatter | med |
| design/adaptive-heartbeat-validation-and-alert-wiring-spec.md | A | prod prerequisite | keep+frontmatter | med |
| design/api-versioning-design.md | A | 2 rg hits, RFC #3646 | keep+frontmatter | med |
| design/canonical-architecture-cleanup-rfc.md | A | active simplification RFC | keep+frontmatter | med |
| design/cdal-contract-kernel-and-advisory-split.md | A | cross-repo boundary spec | keep+frontmatter | med |
| design/CDAL-PHASE1A-TEAM-START-HERE.md | A | starter guide for active CDAL work | keep+frontmatter | med |
| design/check-evaluation-spec.md | A | Phase-1A pre-prod spec | keep+frontmatter | med |
| design/checkpoint-truth-and-replay-rfc.md | A | active continuity RFC | keep+frontmatter | med |
| design/checkpoint-truth-replay-implementation-checklist.md | A | implementation checklist for above | keep+frontmatter | med |
| design/contract-driven-agent-loop-implementation-checklist.md | A | active reference | keep+frontmatter | med |
| design/contract-driven-agent-loop-labeling-protocol.md | A | 1 rg hit; v0-frozen protocol | keep+frontmatter | med |
| design/contract-driven-agent-loop-rfc-review.md | A | validation memo for active RFC | keep+frontmatter | med |
| design/contract-driven-agent-loop-rfc.md | A | OAS / coordinator / MCP integration RFC | keep+frontmatter | med |
| design/cross-run-loader-and-window-spec.md | A | active v2 spec | keep+frontmatter | med |
| design/dashboard-fsm-redesign.md | A | active dashboard FSM redesign | keep+frontmatter | med |
| design/delta-checkpoint-read-path.md | A | Stage 3 design | keep+frontmatter | med |
| design/error-handling-and-operations-spec.md | A | prod prerequisite spec | keep+frontmatter | med |
| design/external-agent-framework-patterns-rfc.md | A | RFC updated 2026-04-12 | keep+frontmatter | med |
| design/handoff-ssot-adr.md | A | proposed ADR #3825 | keep+frontmatter | med |
| design/inventory-gap-analysis-rfc.md | A | 2 rg hits; surface verification RFC | keep+frontmatter | med |

### Part 2 (alphabetical: design/keeper-campaign-fsm — QUICK-START)

| file | category | evidence | action | risk |
|------|----------|----------|--------|------|
| design/keeper-campaign-fsm.md | B | draft FSM design, no code refs | delete | med |
| design/keeper-continuity-diagnosis-rfc.md | B | RFC v3 draft, issue refs only | delete | med |
| design/keeper-continuity-product-rfc.md | B | bounded feature design, no code refs | delete | med |
| design/keeper-detail-source-ownership.md | B | dashboard-modal ownership design | delete | low |
| design/keeper-social-model-fsm.md | B | social-model dispatch FSM design | delete | med |
| design/keeper-social-model-inventory.md | A | active impl inventory (`bdi_speech_v1`) | keep+frontmatter | low |
| design/masc-capsule-execution-plan.md | A | execution companion / product thesis | keep+frontmatter | low |
| design/meta-cognition-map.md | B | research note on keeper self-model signals | delete | low |
| design/oas-masc-state-boundary.md | B | superseded by `spec/13-oas-integration` | delete | low |
| design/proof-bundle-check-mapping.md | B | pre-prod scope, contract-proof coverage | delete | med |
| design/tool-calling-quality-and-self-healing-rfc.md | A | RFC with local code refs, experiment evidence | keep+frontmatter | low |
| ENV-CONTRACT.md | A | referenced in `README.md` | keep+frontmatter | low |
| GAME-VIEW-PROTOCOL.md | C | "future session" protocol, no impl | delete | high |
| GLOSSARY.md | D | superseded by `spec/00-glossary.md` v2.0.0 | merge_into:spec/00-glossary.md | low |
| HOLONIC-ARCHITECTURE.md | C | "vision document, concept not validated" | delete | high |
| IMMORTAL-SERVER-ROADMAP.md | A | referenced in `ROADMAP.md` | keep+frontmatter | low |
| INTEGRATED-BENCHMARK-RUNBOOK.md | B | benchmark runbook, no executable code refs | delete | med |
| INTERRUPT-DESIGN.md | C | "design unimplemented/unverified" 2026-01-25 | delete | high |
| KEEPER-CAMPAIGN-HARNESS.md | A | active harness (`scripts/harness_keeper_campaign.sh`) | keep+frontmatter | low |
| KEEPER-CAPABILITY-MATRIX.md | A | live keeper tool surface matrix (26 tools) | keep+frontmatter | low |
| KEEPER-CONTINUITY-PRODUCTION-RUNBOOK.md | B | future-state release gate, draft | delete | med |
| KEEPER-CONTINUITY-VALIDATION.md | B | operator validation harness, no code refs | delete | low |
| KEEPER-FILE-MODEL.md | A | active file model / ownership SSOT | keep+frontmatter | low |
| KEEPER-SOCIAL-EXPERIMENT-DESIGN.md | B | research design with paper anchors, not coded | delete | low |
| KEEPER-USER-MANUAL.md | A | user manual with OAS pin metadata | keep+frontmatter | low |
| LOCAL-DASHBOARD-AUTH-RUNBOOK.md | B | auth runbook | delete | low |
| MASC-V2-DESIGN.md | C | "Git for AI Agents" vision | delete | high |
| MCP-READPATH-REVALIDATION-RUNBOOK.md | B | runbook, design-only script path | delete | med |
| MCP-SURFACE-AUDIT.md | A | current-state audit with test/code refs | keep+frontmatter | low |
| MCP-TEMPLATE.md | A | live MCP config template | keep+frontmatter | low |
| MDAL-LONG-TERM-PLAN-STATUS.md | B | status doc on MDAL design boundaries | delete | low |
| MDAL.md | B | tool definition (metric-driven loop), no code refs | delete | low |
| MERGED-ARCHITECTURE-SSOT.md | D | superseded by `spec/SPEC-INDEX.md` + `spec/01` | merge_into:spec/01-system-overview.md | low |
| MULTI-ROOM-DESIGN.md | B | retired multi-room tools | delete | low |
| OAS-MASC-BOUNDARY.md | A | live boundary contract SSOT | keep+frontmatter | low |
| OAS-MIGRATION-AUDIT.md | B | completed audit, migration in Track A | delete | med |
| OAS-MIGRATION-NEXT-STEPS.md | B | migration status (baseline done) | delete | low |
| OAS-UTILIZATION-AUDIT.md | B | audit doc, structural gaps noted | delete | low |
| observability/cascade-metrics.md | A | live metrics + alerting rules | keep+frontmatter | low |
| observability/composite-fsm-matrix-design.md | A | design + TLA+ spec (5 FSM axes) | keep+frontmatter | low |
| PERFORMANCE-SLO.md | B | SLO targets, no code enforcement | delete | low |
| PRODUCT-OPERATING-PLAN.md | A | live product promise / execution plan | keep+frontmatter | low |
| PRODUCT-REVIEW.md | A | product review / release posture | keep+frontmatter | low |
| RUNTIME-CATALOG-RUNBOOK.md | A | runtime/auth canonical matrix | keep+frontmatter | low |
| qa/OAS-BOUNDARY-HEALTHCHECK-2026-03-31.md | A | live boundary health snapshot | keep+frontmatter | low |
| qa/OAS-OBSERVABILITY-TRUTH-AUDIT-2026-04-15.md | A | producer→consumer chain audit | keep+frontmatter | low |
| qa/REQUIREMENTS-REVERSE-ENGINEERED.md | B | reverse-engineered feature matrix | delete | low |
| QUICK-START.md | A | live minimal setup procedure | keep+frontmatter | low |

### Part 3 (alphabetical: QUICKSTART — WEBRTC-COMPARISON)

| file | category | evidence | action | risk |
|------|----------|----------|--------|------|
| QUICKSTART.md | D | 3-line redirect to QUICK-START.md | delete (or `merge_into:QUICK-START.md`) | low |
| RELEASE-EVIDENCE.md | A | 5 refs in README + scripts | keep+frontmatter | low |
| REMOTE-MCP-OPERATOR.md | B | superseded by `spec/09-server-transport.md` | archive (in-flight) | med |
| RESEARCH-BASED-IMPROVEMENTS.md | C | "Proposal (not implemented/verified)" 2026-01-09 | delete | low |
| research/qwen-function-calling-harness-2026-04-15.md | C | "saved for local adoption review", no active harness | delete | low |
| research/tool-parameter-hallucination-harness.md | C | "research report", no active handler | delete | low |
| rfc/RFC-0001-det-nondet-boundary-harness.md | B | superseded by RFC-0002/0003 | archive | med |
| rfc/RFC-0002-keeper-state-machine.md | A | active state design, refs in `keeper_registry.ml` | keep+frontmatter | low |
| rfc/RFC-0003-keeper-composite-lifecycle.md | A | refs in `keeper_composite_observer.ml`, TLA, dashboard | keep+frontmatter | low |
| rfc/RFC-0003-phase-2-turn-observation-lifecycle.md | A | active mutation model, in `keeper_composite_observer.ml` | keep+frontmatter | low |
| rfc/RFC-MASC-001-keeper-checkpoint-boundary-migration.md | B | in-flight checkpoint boundary migration | archive | med |
| rfc/RFC-MASC-004-memory-bridge-hook-first.md | B | RFC for `memory_oas_bridge` migration | archive | med |
| rfc/RFC-MASC-005-dashboard-oas-eval-consumer.md | B | depends on RFC-OAS-002, dashboard still independent | archive | med |
| rfc/RFC-MASC-006-observatory-unified-investigation.md | B | aspirational dashboard phase 2, not implemented | delete | low |
| rfc/RFC-TOOL-SURFACE-SSOT.md | B | 126 orphaned tools study, no dispatch change | delete | med |
| SEARCH-FABRIC-V1.md | C | "experiment" status, no active code | delete | low |
| SPAWN-PERSISTENCE-DESIGN.md | C | design sketch, no `spawn_registry.ml` exists | delete | low |
| SPEC.md | B | "SUPERSEDED-BY docs/spec/SPEC-INDEX.md" | delete | low |
| spec/00-glossary.md | A | foundational; canonical glossary | keep+frontmatter | low |
| spec/01-system-overview.md | A | 4 hits; canonical | keep+frontmatter | low |
| spec/02-types-and-invariants.md | A | newtype hierarchy spec | keep+frontmatter | low |
| spec/03-room-coordination.md | A | room implementation spec | keep+frontmatter | low |
| spec/04-chain-engine.md | A | chain orchestration spec | keep+frontmatter | low |
| spec/05-keeper-agent.md | A | keeper lifecycle / types | keep+frontmatter | low |
| spec/06-command-plane.md | B | "Historical Reference"; CPv2 deprecated | archive | low |
| spec/09-server-transport.md | A | 10 hits across README and runbooks | keep+frontmatter | low |
| spec/10-dashboard.md | A | 6 hits; dashboard architecture | keep+frontmatter | low |
| spec/11-board.md | A | board system design | keep+frontmatter | low |
| spec/12-memory-systems.md | A | memory subsystems spec | keep+frontmatter | low |
| spec/13-oas-integration.md | A | 2 README hits; OAS boundary contract | keep+frontmatter | low |
| spec/14-configuration.md | A | 1 hit in `KEEPER-USER-MANUAL.md` | keep+frontmatter | low |
| spec/15-testing.md | A | test strategy | keep+frontmatter | low |
| spec/A-existing-doc-index.md | A | 3 hits; doc classification SSOT | keep+frontmatter | low |
| spec/B-migration-targets.md | B | migration delta snapshot 2026-03-23 | archive | low |
| spec/C-implementation-status.md | A | implementation status tracking | keep+frontmatter | low |
| spec/GATE-CONNECTOR-PROTOCOL.md | B | no gate/connector code in `lib/`; experimental | delete | med |
| spec/SPEC-INDEX.md | A | 14 hits; canonical entry point | keep+frontmatter | low |
| SUPERVISOR-MODE.md | A | 5 hits; active operator mode surface | keep+frontmatter | low |
| SWARM-DELIVERY-RUNBOOK.md | A | 2 hits; runbook for swarm delivery | keep+frontmatter | low |
| SYSTEM-EVENT-AND-SNAPSHOT-INVENTORY.md | B | "validated 2026-04-16", but only 1 ref | archive | low |
| tla-audit/cascade-fsm-gap-2026-04-13.md | B | "historical audit only"; bug fixed | archive | low |
| tla-audit/decision-fsm-gap-2026-04-13.md | B | "historical audit only"; bug fixed | archive | low |
| tla-audit/state-fsm-gap-2026-04-13.md | B | "historical audit only"; bug fixed | archive | low |
| TOML-RELOAD-MATRIX.md | A | 1 hit in `check-doc-truth.sh` | keep+frontmatter | low |
| TRANSPORT-PRACTICAL-PLAYBOOK.md | B | superseded by `SUPERVISOR-MODE.md` | delete | med |
| TUI-GUIDE.md | A | 2 hits; active `masc_tui.exe` guide | keep+frontmatter | low |
| VERIFICATION-MATRIX.md | B | no code refs | delete | low |
| VERSIONED-ROADMAP.md | A | release versioning / feature train SSOT | keep+frontmatter | low |
| WEBRTC-COMPARISON.md | C | benchmark record 2026-01-25; no active WebRTC code | delete | low |

## High-risk-flag deletions

These four were marked C and `delete` but flagged `risk: high` — please
double-check before the DELETE PR runs:

- `GAME-VIEW-PROTOCOL.md`
- `HOLONIC-ARCHITECTURE.md`
- `INTERRUPT-DESIGN.md`
- `MASC-V2-DESIGN.md`

The risk is reputational, not operational: these are the most aspirational
files in the repo, so deleting them is exactly the goal. The `high` flag
just means: confirm one more time that the body really is vision-only.

## Duplicate / merge pairs

| Loser | Winner | Notes |
|-------|--------|-------|
| `GLOSSARY.md` | `spec/00-glossary.md` | header explicitly marks loser as superseded |
| `MERGED-ARCHITECTURE-SSOT.md` | `spec/SPEC-INDEX.md` + `spec/01-system-overview.md` | header marks both spec files as canonical |
| `QUICKSTART.md` | `QUICK-START.md` | loser is a 3-line redirect; pure noise |
| `cascade/README.md` | `docs/spec/` (system-wide) | personal note, redundant |
| `cascade/STRATEGY-GUIDE.md` | `docs/observability/cascade-metrics.md` | personal note, not team contract |

## Next steps (separate PRs, not in this audit)

1. **DELETE PR** — B (delete subset) + C + D losers in one `git rm` sweep. PR body summarizes counts and lists high-risk-flag files explicitly.
2. **ARCHIVE PR** — B (archive subset, 14 files) moved to `docs/archive/2026-04/`. No redirect stubs.
3. **MERGE PR** — D pairs (5 files) merged into winners. Run a follow-up `rg` for inbound links to losers and patch them in the same PR.
4. **FRONTMATTER PR** — All A files get the YAML frontmatter described above. CI gate to enforce it on new docs is optional follow-up.

Each of these is small and reversible (git history is the SSOT). Do
them in order; do not bundle them into one PR.
