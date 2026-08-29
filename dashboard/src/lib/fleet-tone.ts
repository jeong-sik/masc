// Fleet tone vocabulary — the single SSOT for the 5-tone health badge /
// dot / pill / aside tone that the keeper workspace + agent-roster share.
//
// Two prior surfaces re-declared this vocabulary in parallel:
//   - dashboard/src/components/agent-roster.ts (PR #22441, MERGED):
//       `type FleetTone = 'ok' | 'warn' | 'bad' | 'busy' | 'idle'`
//       `FL_TONE_LABEL = { ok:'실행', warn:'대기', bad:'주의', busy:'전이', idle:'정지' }`
//   - dashboard/src/components/keeper-workspace/keeper-workspace-shared.ts
//     (iter-2 PR #22466, DRAFT): local `DotTone = 'ok' | 'warn' | 'bad' | 'info' | 'idle'`
//
// The 'info' name is a drift: agent-roster and the repo-owned keeper-v2
// fleet.css already shipped 'busy'. Lifting the SSOT here makes that
// checked-in convention win.

import { UNKNOWN_STATUS_LABEL } from './format-string'

/** 5-tone health vocabulary shared across the Fleet surfaces. */
export type FleetTone = 'ok' | 'warn' | 'bad' | 'busy' | 'idle'

/** Korean tone label, used as the aside "selected runtime" state line. */
export const FL_TONE_LABEL: Readonly<Record<FleetTone, string>> = {
  ok: '실행',
  warn: '대기',
  bad: '주의',
  busy: '전이',
  idle: '정지',
}

/** The complete codomain of `keeperDisplayStatus`
 *  (`lib/keeper-runtime-display.ts`), as lower-cased tokens. The labels in
 *  PHASE_LABEL_KO and the tones in PHASE_TONE key on these tokens, NOT on
 *  the PascalCase `KeeperPhase` enum. `keeperDisplayStatus` declares this
 *  as its return type, so a new emission that is not listed here is a
 *  compile error rather than a runtime collapse to `'unknown'`.
 *
 *  Two groups:
 *   - Lifecycle phases: `KeeperPhase` collapses onto these via
 *     `keeperLifecycleStatus`. `Offline` maps to `unbooted`, not `offline`.
 *   - Non-phase display states: `idle` / `listening` come from the agent
 *     status axis (a keeper that is alive between turns), and `offline` is
 *     the residual `refineOfflineStatus` case (registered, agent record
 *     exists, never ran a turn, heartbeat stale). These are not FSM phases,
 *     which is why `KeeperPhase` has no counterpart for them.
 *
 *  Before 2026-07-27 the union covered only the lifecycle group. The three
 *  non-phase tokens were emitted anyway and collapsed to `'unknown'` at
 *  `phaseTokenFromKeeper`, which renders as `확인 필요` — an alarm word for
 *  a healthy idle keeper. Measured: 5 distinct inputs hit that path.
 */
export type KeeperPhaseToken =
  | 'running'
  | 'paused'
  | 'draining'
  | 'restarting'
  | 'failing'
  | 'stopped'
  | 'unbooted'
  | 'crashed'
  | 'idle'
  | 'listening'
  | 'offline'
  | 'unknown'

/** Closed tone map. Keys MUST match `KeeperPhaseToken` and MUST be kept in
 *  sync with `PHASE_LABEL_KO` below (same keyspace, different value shape).
 *
 *  Runtime SSOT: this repo-owned table. Keys are lowercased to match the
 *  live `keeperDisplayStatus` wire tokens, and consumers import this module
 *  instead of keeping parallel string classifiers.
 *
 *  `Draining` is `warn` here because it represents operator intent via
 *  the `stop` action's danger:true via-phase. The runtime band agrees:
 *  `monitoring-runtime.ts:keeperBand` routes `Draining` to the `paused`
 *  band, which `ROSTER_BAND_TONE` (`agent-roster.ts`) maps to `warn` —
 *  the workspace tone (`PHASE_TONE.draining = 'warn'`) and the rail
 *  agree.
 *
 *  Why `Object.create(null)` instead of a plain object literal: the
 *  `isKeeperPhaseToken` guard uses own-property checks, and JS `in` /
 *  bracket-access on a plain object leak `Object.prototype` members
 *  (`constructor`, `toString`, `__proto__`, `hasOwnProperty`, …). A
 *  malformed wire token like `'constructor'` would otherwise bypass
 *  the `'unknown'` fallback and surface inherited members in
 *  `keeperStatusTone` / `keeperPhaseLabel`. The null-prototype factory
 *  closes that hole at the data-structure level so future lookup style
 *  changes (e.g. switching from `hasOwnProperty` to `Map.get`) cannot
 *  silently re-introduce it. The `Object.freeze` makes the map truly
 *  immutable at runtime — there is no legitimate path that mutates it. */
export const PHASE_TONE: Readonly<Record<KeeperPhaseToken, FleetTone>> =
  Object.freeze(
    Object.assign(Object.create(null), {
      running: 'ok',
      paused: 'warn',
      draining: 'warn',
      restarting: 'busy',
      failing: 'bad',
      stopped: 'idle',
      unbooted: 'idle',
      crashed: 'bad',
      // Alive between turns. `ROSTER_BAND_TONE.active = 'ok'`
      // (`agent-roster.ts`) already routes this band to `ok`; matching it
      // keeps the dot colour of an idle keeper the same on both surfaces.
      idle: 'ok',
      listening: 'ok',
      // Residual offline case — same "not running, not an error" bucket as
      // `stopped` / `unbooted`.
      offline: 'idle',
      unknown: 'idle',
    }) as Record<KeeperPhaseToken, FleetTone>,
  )

/** Korean phase label shown in roster sub-rows + chat header state pills.
 *  Keyed on the same lowercase tokens as `PHASE_TONE` so the two tables
 *  cannot drift. Previously lived at the bottom of `keeper-workspace-
 *  shared.ts` and missed the `Restarting` variant; lifted here
 *  so agent-roster can share it.
 *
 *  Same null-prototype + freeze rationale as `PHASE_TONE` — closed-sum
 *  boundary must hold for arbitrary backend wire strings. */
export const PHASE_LABEL_KO: Readonly<Record<KeeperPhaseToken, string>> =
  Object.freeze(
    Object.assign(Object.create(null), {
      running: '실행 중',
      paused: '일시정지',
      draining: '정리 중',
      restarting: '재시작 중',
      failing: '오류 발생',
      stopped: '중지',
      unbooted: '미기동',
      crashed: '비정상 종료',
      // Words taken from the existing `statusLabel` SSOT
      // (`lib/status-label.ts`) rather than coined here, so the generic
      // status vocabulary and the keeper vocabulary agree on these keys.
      idle: '대기',
      listening: '수신 대기',
      offline: '오프라인',
      unknown: UNKNOWN_STATUS_LABEL,
    }) as Record<KeeperPhaseToken, string>,
  )

/** One-sentence operator explanation per token — the tooltip / secondary
 *  line that sits under the label.
 *
 *  Lifted verbatim from `PHASE_LABELS` in `lib/monitoring-runtime.ts`,
 *  which owned the only such table. It moved here so the label, the tone
 *  and the explanation share one keyspace; `monitoring-runtime` now reads
 *  from this map instead of holding a parallel copy.
 *
 *  One collapse during the move: `Stopped` and the lowercase `stopped`
 *  entry carried different sentences ('정상 정지된 런타임입니다.' vs
 *  '이전에 실행되었지만 현재는 정지 상태입니다.') for the same token. The
 *  PascalCase one wins because it is the FSM phase; the lowercase entry
 *  was the status-field alias for the same condition. */
export const PHASE_DESCRIPTION_KO: Readonly<Record<KeeperPhaseToken, string>> =
  Object.freeze(
    Object.assign(Object.create(null), {
      running: 'keeper_state_machine 기준으로 정상 실행 상태입니다.',
      paused: 'keeper가 재개 대기 상태로 멈춰 있습니다.',
      draining: '현재 작업을 마무리하는 중입니다.',
      restarting: '복구를 시도하고 있습니다.',
      failing: '최근 실행에서 오류를 감지했습니다.',
      stopped: '정상 정지된 런타임입니다.',
      unbooted: '등록만 되어 있고 아직 부팅되지 않았습니다.',
      crashed: 'fiber가 비정상적으로 종료되었습니다.',
      idle: '프로세스는 살아 있지만 현재 턴 작업 없음',
      listening: '프로세스는 살아 있고 입력을 기다리고 있습니다.',
      offline: '런타임 연결을 확인하지 못했습니다.',
      unknown: 'phase 정보가 부족해 수동 확인이 필요합니다.',
    }) as Record<KeeperPhaseToken, string>,
  )

/** Wire-status synonyms that mean an already-modelled token.
 *
 *  Sourced from the alias arms that `KEEPER_STATUS_LABEL_KO`
 *  (`lib/keeper-operational-state.ts`) already carries — that table lists
 *  `active` / `live` / `busy` / `executing` and maps all four to `실행 중`,
 *  which is the evidence that the backend emits them as `keeper.status`.
 *  They are folded here instead of being re-listed as separate tokens so
 *  the tone and label tables stay one-entry-per-meaning.
 *
 *  Not an open extension point: anything absent from both this map and
 *  `PHASE_TONE` parses to `null`, and the caller decides the fallback. */
const KEEPER_STATUS_ALIASES: Readonly<Record<string, KeeperPhaseToken>> =
  Object.freeze(
    Object.assign(Object.create(null), {
      active: 'running',
      live: 'running',
      busy: 'running',
      executing: 'running',
      inactive: 'offline',
    }) as Record<string, KeeperPhaseToken>,
  )

/** Boundary parse for the token union — the only sanctioned way to turn an
 *  arbitrary wire string into a `KeeperPhaseToken`. Returns `null` on an
 *  unrecognized value rather than guessing, so callers state their own
 *  fallback at the call site instead of inheriting a silent one.
 *
 *  `hasOwnProperty` rather than `in`: `PHASE_TONE` is null-prototype today,
 *  but the guard must keep holding if it is ever rebuilt as a plain object
 *  literal, where a wire token like `'constructor'` would otherwise pass. */
export function toKeeperPhaseToken(
  value: string | null | undefined,
): KeeperPhaseToken | null {
  const normalized = (value ?? '').trim().toLowerCase()
  if (!normalized) return null
  if (Object.prototype.hasOwnProperty.call(PHASE_TONE, normalized)) {
    return normalized as KeeperPhaseToken
  }
  if (Object.prototype.hasOwnProperty.call(KEEPER_STATUS_ALIASES, normalized)) {
    return KEEPER_STATUS_ALIASES[normalized] ?? null
  }
  return null
}

// The runtime helper `phaseTokenFromPhase` is defined in the workspace
// surface (keeper-workspace-shared.ts) because it depends on
// `KeeperPhase | null | undefined` normalization rules that belong to
// the runtime display layer. This module stays pure data.
