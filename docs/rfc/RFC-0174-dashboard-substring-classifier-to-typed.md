---
rfc: "0174"
title: "Dashboard substring classifier to typed — TypeScript"
status: Draft
created: 2026-05-24
updated: 2026-05-24
author: vincent
supersedes: []
superseded_by: null
related: ["0089"]
implementation_prs: []
---

# RFC-0174 — Dashboard substring classifier to typed variant

## §1 Context

RFC-0089 closed 215+ OCaml `String.starts_with ~prefix:"..."` sites in `lib/`
by replacing them with typed variant constructors. Its scope was backend-only.

The TypeScript dashboard (`dashboard/src/`) has **8 sites** that classify
backend wire-format strings via `.includes()`, `.startsWith()`, and inline
array literals. These patterns are structurally identical to RFC-0089 §2's
anti-pattern: when the backend adds a new variant, the dashboard silently
falls through to an untyped fallback instead of surfacing a typecheck failure.

The existing `keeper-store-normalize.ts` already demonstrates the correct
pattern — closed `ReadonlySet`/`Record` maps with compile-time coverage
checks (`_BACKEND_PHASE_COVERAGE_CHECK`). This RFC extends that pattern to
the remaining 8 scattered sites.

## §2 Scope

### §2.1 In-scope (8 sites)

| # | File | Line(s) | Pattern | Typed replacement |
|---|------|---------|---------|-------------------|
| S1 | `status-tray.ts` | 158 | `.startsWith('satisfied')` | `isAttentionCodeSatisfied(code)` |
| S2 | `keeper-supervisor-helpers.ts` | 37-38 | `CRASH_CATEGORY_KEYS` + prefix map | `classifyCrashReason(raw): CrashCategory` |
| S3 | `fsm-hub-types.ts` | 677 | `.startsWith(prefix)` for terminal reason labels | `terminalReasonLabel(code): string` |
| S4 | `journey-waterfall-state.ts` | 306-307 | `['active','running',...].includes(status)` | `keeperPriority(status): 1|2|3` |
| S5 | `session-trace-view.ts` | 152 | `['offline','inactive','dead'].includes(...)` | `isOfflineStatus(status): boolean` |
| S6 | `tool-call-shared.ts` | 66 | `.includes('bash')` etc. for tool categories | `classifyToolCategory(name): ToolCategory` |
| S7 | `harness-health-sections.ts` | 177 | `.startsWith('approve')` | `isApproveVerdict(verdict): boolean` |
| S8 | `harness-health-sections.ts` | 193-194 | `.includes('warning')` / `.includes('stale')` | `railStatusMessage(statuses): string` |

### §2.2 Out of scope

- Search/filter `.includes(needle)` where `needle` is user input (governance.ts, history.ts, etc.) — these are text search, not classification.
- `keeper-store-normalize.ts` — already typed via `toKeeperPhase`/`toPipelineStage`/`normalizeKeeperAgentStatus`.
- Backend OCaml changes — RFC-0089 territory.

## §3 Design

### §3.1 New file: `dashboard/src/lib/keeper-classifiers.ts`

Central typed classifier module. Every function takes `string` input and
returns a typed result. Unknown inputs map to explicit fallback values
(`null`, `false`, or a `'unknown'` variant) — never silently accepted.

```typescript
// keeper-classifiers.ts

/** Keeper priority for waterfall/journey sorting. */
export type KeeperPriority = 1 | 2 | 3

/** Closed set of offline-status strings. */
const OFFLINE_STATUSES: ReadonlySet<string> = new Set([
  'offline', 'inactive', 'dead', 'crashed',
])

/** Active-status strings → priority 1. */
const ACTIVE_STATUSES: ReadonlySet<string> = new Set([
  'active', 'running', 'thinking', 'tool_use', 'claimed', 'in_progress',
])

/** Satisfied attention code prefixes. */
const SATISFIED_PREFIXES: readonly string[] = ['satisfied']

/** Crash reason classification. */
export type CrashCategory = 'heartbeat' | 'turn' | 'fiber' | 'exception' | 'unknown'

const CRASH_PREFIX_MAP: readonly { prefix: string; category: CrashCategory }[] = [
  { prefix: 'heartbeat', category: 'heartbeat' },
  { prefix: 'turn', category: 'turn' },
  { prefix: 'fiber', category: 'fiber' },
  { prefix: 'exception', category: 'exception' },
]

export function isOfflineStatus(status: string): boolean {
  return OFFLINE_STATUSES.has(status)
}

export function keeperPriority(status: string): KeeperPriority {
  if (ACTIVE_STATUSES.has(status)) return 1
  if (OFFLINE_STATUSES.has(status)) return 3
  return 2
}

export function isAttentionCodeSatisfied(code: string): boolean {
  return SATISFIED_PREFIXES.some(p => code.startsWith(p))
}

export function classifyCrashReason(raw: string): CrashCategory {
  const lower = raw.toLowerCase()
  for (const { prefix, category } of CRASH_PREFIX_MAP) {
    if (lower.startsWith(prefix)) return category
  }
  return 'unknown'
}

export function isApproveVerdict(verdict: string): boolean {
  return verdict.startsWith('approve')
}

export function railStatusMessage(statuses: string[]): string | null {
  if (statuses.includes('warning')) return '감시 채널에 주의가 필요합니다.'
  if (statuses.includes('stale')) return '신호는 있지만 최신성이 떨어집니다.'
  return null
}
```

### §3.2 Tool category classifier

`tool-call-shared.ts` has a `TOOL_CATEGORIES` array of `{ match, icon, label }`
where `match` is `(n: string) => boolean` using `.includes()`. This stays
where it is but gains typed return via a `ToolCategory` union:

```typescript
export type ToolCategory =
  | 'shell' | 'github' | 'git' | 'status' | 'dashboard'
  | 'agent' | 'memory' | 'search' | 'other'
```

The match functions remain inline (they're rendering logic, not wire-format
parsing) but the category label becomes the typed union instead of a free
string.

### §3.3 Terminal reason label map

`fsm-hub-types.ts` line 677 uses a `REASON_LABEL_MAP` array of
`{ prefix, label }` objects. This is display-only (Korean labels) and the
prefix set mirrors the backend closed sum. This stays where it is but gains
a compile-time completeness assertion via a `satisfies` constraint against
the `KeeperTrustTerminalReason` union.

## §4 Migration plan

Single PR, 8 consumer files + 1 new utility file:

1. Create `dashboard/src/lib/keeper-classifiers.ts`
2. Write tests in `dashboard/src/lib/keeper-classifiers.test.ts`
3. Replace S1-S8 call sites one by one
4. Run `tsc --noEmit` + existing tests to verify no regressions

No flag-gating. Direct replacement.

## §5 Test requirements

- `isOfflineStatus`: test all 4 known values + unknown → false
- `keeperPriority`: test each priority tier + unknown → 2
- `isAttentionCodeSatisfied`: test "satisfied", "satisfied_*" prefix → true; "violated" → false
- `classifyCrashReason`: test 4 known prefixes + unknown → 'unknown'
- `isApproveVerdict`: test "approve", "approve_*" → true; "reject:*" → false
- `railStatusMessage`: test ['warning'], ['stale'], ['ok'], [] → correct message or null

## §6 Non-goals

- TypeScript strict enum enforcement (TS union types provide adequate exhaustiveness via `never`)
- Dashboard-wide lint rule for `.includes` (RFC-0089 §2 rationale: lint for string classifiers is self-referential workaround)
- Backend wire-format changes (OCaml territory)
