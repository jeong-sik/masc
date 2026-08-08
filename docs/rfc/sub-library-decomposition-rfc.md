# RFC: agent_sdk Sub-Library Decomposition (PR-A1)

**Status**: Draft
**Date**: 2026-05-04
**Priority**: P0
**Supersedes**: progress-evaluation.md PR-A1

## Problem

`agent_sdk` has 195 `.ml` files (~48K LOC) in a single dune library. All modules
see each other. No compile-time isolation between domains. Change any file and
all 195 modules recompile.

Compare: masc-mcp decomposed into 25+ sub-libraries over 10 weeks (806 commits).

## Current State

```
lib/
├── agent/         → 11 files, 3933 LOC  (agent lifecycle, turn, tools)
├── pipeline/      → 11 files, 2791 LOC  (6-stage turn pipeline)
├── protocol/      →  6 files, 1866 LOC  (A2A, MCP, Agent Card)
├── llm_provider/  → separate library     (already extracted)
└── *.ml           → 165 files, ~39K LOC  (everything else mixed)
```

Dependency graph (→ = "depends on"):

```
protocol/  → Types only (isolated, no runtime/sessions refs)
pipeline/  → Types, Agent_types, Provider (no runtime/sessions refs)
agent/     → Types, Agent_types, Result_syntax (no runtime/sessions refs)
runtime*   → sessions (bidirectional), evidence
sessions*  → runtime (bidirectional)
```

## Proposed Decomposition

### Phase 1: Immediate (no shared types needed)

Three sub-libraries that have zero cross-domain dependencies:

| Library | Files | LOC | Dependencies |
|---------|-------|-----|-------------|
| `agent_sdk.protocol` | `lib/protocol/` | ~1866 | agent_sdk (Types only) |
| `agent_sdk.pipeline` | `lib/pipeline/` | ~2791 | agent_sdk (Types, Agent_types, Provider) |
| `agent_sdk.agent` | `lib/agent/` | ~3933 | agent_sdk (Types, Agent_types) |

Implementation: Each gets its own `dune` with `(libraries agent_sdk)` and
`(include_subdirs unqualified)`. The parent `lib/dune` adds them to `(libraries ...)`.
Modules in these subdirectories are removed from the main library via dune's
automatic exclusion when a subdirectory has its own library stanza.

### Phase 2: Shared types extraction

Extract `types.ml` → `agent_sdk.types` as a separate library that both
`agent_sdk` and sub-libraries depend on.

This breaks the circular dependency where sub-libraries depend on agent_sdk
(which contains Types) and agent_sdk depends on sub-libraries.

### Phase 3: Domain extraction from root

After Phase 2 enables clean dependency direction:

| Library | Files | LOC | Notes |
|---------|-------|-----|-------|
| `agent_sdk.runtime` | `runtime*.ml` (13) | ~4167 | sessions bidirectional, needs shared types |
| `agent_sdk.sessions` | `sessions*.ml` (5) | ~1429 | runtime bidirectional |
| `agent_sdk.evidence` | `*evidence*.ml` (3) | ~1649 | depends on runtime |
| `agent_sdk.memory` | `memory*.ml` (8) | ~1836 | relatively isolated |

## Dependency Direction (target)

```
agent_sdk.types  ← (everyone depends on this)
    ↑
agent_sdk.protocol  (leaf, no deps beyond types)
    ↑
agent_sdk.agent     (depends on types)
    ↑
agent_sdk.pipeline  (depends on types, agent_types, provider)
    ↑
agent_sdk.runtime   (depends on types, sessions, evidence)
    ↑
agent_sdk.sessions  (depends on types, runtime — bidirectional via shared types)
    ↑
agent_sdk           (core: context, api, provider, error, etc.)
```

## Verification

Each phase requires:
1. `dune build` passes
2. `dune runtest` passes
3. Coverage threshold maintained (≥22%)
4. No circular dependencies (`dune` enforces at link time)

## Risk

- **Types re-export**: `include Llm_provider.Types` in `types.ml` means sub-libraries
  need both `agent_sdk.types` and `llm_provider` as dependencies.
- **Bidirectional runtime↔sessions**: Phase 3 requires shared interface modules
  or callback pattern to break the cycle.
- **Open Types everywhere**: 64 files reference `Types.` — renaming/moving Types
  has high blast radius.

## Implementation Order (revised)

**Prerequisite**: protocol/ ↔ agent_sdk bidirectional dependency means
extraction requires shared base first. Error (70 refs), Types (64 refs),
Result_syntax (32 refs, no deps) are leaf modules.

1. **Phase 0**: Extract `agent_sdk.base` — Types, Error, Result_syntax (~460 LOC)
   - These are leaf modules with no internal dependencies beyond `llm_provider`
   - Unblocks all subsequent phases
2. **Phase 1a**: `agent_sdk.protocol` — depends on base only
3. **Phase 1b**: `agent_sdk.agent` — depends on base + Agent_types
4. **Phase 1c**: `agent_sdk.pipeline` — depends on base + agent
5. **Phase 2a**: `agent_sdk.memory` — relatively isolated
6. **Phase 2b**: `agent_sdk.sessions` + `agent_sdk.runtime` together (bidirectional)
7. **Phase 2c**: `agent_sdk.evidence`

Estimated: 1 phase per sprint (2 weeks), 7 phases across 3.5 months.
