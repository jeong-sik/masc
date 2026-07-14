import { KEEPER_RUNTIME_BLOCKER_CLASSES, type KeeperRuntimeBlockerClass } from '../types'

const RUNTIME_BLOCKER_CLASS_SET: ReadonlySet<string> = new Set(
  KEEPER_RUNTIME_BLOCKER_CLASSES,
)

export function isKeeperRuntimeBlockerClass(
  value: string,
): value is KeeperRuntimeBlockerClass {
  return RUNTIME_BLOCKER_CLASS_SET.has(value)
}

export function asKeeperRuntimeBlockerClass(
  value: unknown,
): KeeperRuntimeBlockerClass | null {
  if (typeof value !== 'string') return null
  const trimmed = value.trim()
  if (trimmed === '') return null
  return isKeeperRuntimeBlockerClass(trimmed) ? trimmed : null
}

// ─────────────────────────────────────────────────────────────────────
// Backend ↔ frontend variant coverage check
//
// Source of truth: `lib/keeper/keeper_meta_contract.ml:91 type blocker_class`
//   + `blocker_class_to_string` (`lib/keeper/keeper_meta_contract.ml:137–164`).
//
// Backend can still decode these 24 lowercase wire strings (verified by
// `Keeper_synthetic_marker` audit, 2026-05-19). The list below is the
// *frozen* mirror — keep it 1:1 with `keeper_meta_contract.ml`.//
// Status bridge (`lib/keeper/keeper_status_bridge.ml`) emits two
// additional dashboard-only synthetic classes (`synthetic_stall`,
// `self_imposed_idle`) and the runtime trust pipeline emits
// dashboard-conditioned ones (`provider_runtime_error`,
// `stale_termination_storm`,
// `heartbeat_failures`, `turn_failures`, `exception`,
// `awaiting_operator`, `awaiting_sandbox_egress`, `supervisor_paused`).
// These are NOT in `keeper_meta_contract` and so do not appear in this
// coverage list; they are validated separately by
// `KEEPER_RUNTIME_BLOCKER_CLASSES` membership.
//
// Drift discipline:
//   - new backend `keeper_meta_contract` variant → add a lowercase
//     entry here AND to `types/core.ts:KEEPER_RUNTIME_BLOCKER_CLASSES`
//   - if the lowercase entry is added here but not in the frontend
//     union, `_BackendCoverageDelta` resolves to that string literal
//     and the `true` constant below fails to assign — typecheck stops
//     the drift at build time.

const BACKEND_KEEPER_META_BLOCKER_CLASSES = [
  'runtime_exhausted',
  'turn_timeout',
  'fiber_unresolved',
  'stale_turn_timeout',
  'stale_fleet_batch',
  'sdk_context_window_exceeded',
  'sdk_unrecognized_stop_reason',
  'sdk_idle_detected',
  'sdk_guardrail_violation',
  'sdk_tripwire_violation',
  'sdk_exit_condition_met',
] as const

type BackendKeeperMetaBlockerClass = typeof BACKEND_KEEPER_META_BLOCKER_CLASSES[number]
type _BackendCoverageDelta = Exclude<BackendKeeperMetaBlockerClass, KeeperRuntimeBlockerClass>
const _BACKEND_KEEPER_META_COVERAGE_CHECK:
  [_BackendCoverageDelta] extends [never] ? true : _BackendCoverageDelta = true
void _BACKEND_KEEPER_META_COVERAGE_CHECK
