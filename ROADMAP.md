# masc-mcp Roadmap

> Current: v2.102.1 | Updated: 2026-03-17

This is the single source of truth for masc-mcp planning.
For versioning rules and intake/triage, see `docs/VERSIONED-ROADMAP.md`.

## Short-term (v2.103-v2.104, next 2-4 weeks)

Source: `docs/ARCHITECTURE-COMPLEXITY-ANALYSIS.md` (Phase 2-3)

| Item | Module | Est. lines affected | Status |
|------|--------|---------------------|--------|
| TRPG + protocol_game_view extraction to `masc-games` | tool_trpg, tool_protocol_game_view | 3600+ | Not started |
| risc + autoresearch + council + experiment extraction | tool_risc, tool_autoresearch, tool_council, tool_experiment | 3800+ | Not started |
| dune optional library separation | dune, lib/ | - | Not started |
| tool_team_session split (4412 -> 5 modules) | tool_team_session | 4412 | Design done |
| TRPG dm-keeper -> on-demand conversion | keeper_autonomy | - | Not started |
| Test noise cleanup: merge 32 duplicate coverage files | test/ | ~12K lines | Audit done |

## Mid-term (v2.105-v2.108, 1-3 months)

| Item | Source | Notes |
|------|--------|-------|
| Mode/profile system (core 5 / standard 17 / full 72) | ARCHITECTURE-COMPLEXITY Phase 3 | Reduces default tool exposure |
| Environment variables -> config file consolidation | ARCHITECTURE-COMPLEXITY Phase 3 | 50+ env vars currently |
| Binary distribution (brew/npm install) | IDEAS #6 | No owner |
| Worktree diff broadcast | IDEAS #7 | No owner |
| Lodge identity v2 Tier 1 (confidence, decay, thresholds) | docs/lodge-identity-v2/ROADMAP.md | Design exists, no implementation |

## Long-term (v2.109+, 3+ months, directional)

These are directions, not commitments. Each needs a trigger condition or owner to activate.

| Direction | Source | Trigger |
|-----------|--------|---------|
| Lodge identity v2 Tier 2-3 (ToM, archetypes) | docs/lodge-identity-v2/ROADMAP.md | Tier 1 proves value |
| Figma-MCP integration (visual heartbeat) | docs/archive/EVOLUTION-PLAN-FIGMA-MCP.md | figma-mcp stabilizes |
| Cluster mode / multi-node HA | docs/IMMORTAL-SERVER-ROADMAP.md Phase 3 | Single-node limits hit |
| Chaos engineering framework | docs/IMMORTAL-SERVER-ROADMAP.md Phase 3 | Production incident pattern |
| Adaptive orchestration (dynamic org) | docs/archive/IMPROVEMENT-PLAN-2026-01.md P3 | Agent count > 30 |

## Completed milestones

See `CHANGELOG.md` for release-by-release details.

| Version range | Theme | Key deliverables |
|---------------|-------|------------------|
| v2.87.0 | Release closeout | CI green, CHANGELOG honest |
| v2.88.0 | Reliable Swarm | Provider fallback, dispatch serialization |
| v2.89.0 | Visible Swarm | Heartbeat tracking, zombie detection |
| v2.90.0 | Recoverable Swarm | Checkpointing, schema validation |
| v2.91.0 | Immortal Base | Supervision, health, graceful shutdown |
| v2.92.0 | Product Portfolio Trim | TRPG/Voice/Autoresearch review |
| v2.93.0-v2.102.1 | Incremental | See CHANGELOG.md |

## Archived plans

Previous planning documents moved to `docs/archive/`:

| File | Why archived |
|------|-------------|
| `IDEAS-2026-01.md` | 9/11 items done, 2 stale |
| `IMPROVEMENT-BACKLOG-MITOSIS.md` | 25/25 items complete |
| `EVOLUTION-PLAN-FIGMA-MCP.md` | Targets different repo, never started |
| `RELEASE-ROADMAP-v287.md` | v2.87.0 long past |
| `IMPROVEMENT-PLAN-2026-01.md` | Superseded by VERSIONED-ROADMAP |

## Design references (active, not archived)

| File | Value |
|------|-------|
| `docs/ARCHITECTURE-COMPLEXITY-ANALYSIS.md` | Tier classification, split plans, reduction phases |
| `docs/IMMORTAL-SERVER-ROADMAP.md` | OCaml type signatures for supervision tree |
| `docs/lodge-identity-v2/ROADMAP.md` | Lodge identity system design |
| `docs/VERSIONED-ROADMAP.md` | Versioning rules, intake/triage process |
