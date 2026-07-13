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

/** Canonical lower-cased phase token emitted by `keeperDisplayStatus`
 *  (`lib/keeper-runtime-display.ts:180`). The labels in PHASE_LABEL_KO and
 *  the tones in PHASE_TONE key on these tokens, NOT on the PascalCase
 *  `KeeperPhase` enum. This union is closed: any new lowercase token added
 *  by `keeperLifecycleStatus` (or any future status surface) forces the
 *  compiler to flag a missing entry here.
 *
 *  Derivation: `KeeperPhase` collapses via `keeperLifecycleStatus`
 *  to lowercase tokens, plus `unknown` for the fallback path.
 */
export type KeeperPhaseToken =
  | 'running'
  | 'paused'
  | 'compacting'
  | 'handoff'
  | 'draining'
  | 'restarting'
  | 'failing'
  | 'overflowed'
  | 'stopped'
  | 'unbooted'
  | 'crashed'
  | 'dead'
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
      compacting: 'busy',
      handoff: 'busy',
      restarting: 'busy',
      failing: 'bad',
      overflowed: 'bad',
      stopped: 'idle',
      unbooted: 'idle',
      crashed: 'bad',
      dead: 'bad',
      unknown: 'idle',
    }) as Record<KeeperPhaseToken, FleetTone>,
  )

/** Korean phase label shown in roster sub-rows + chat header state pills.
 *  Keyed on the same lowercase tokens as `PHASE_TONE` so the two tables
 *  cannot drift. Previously lived at the bottom of `keeper-workspace-
 *  shared.ts` and missed `Overflowed` / `Restarting` variants; lifted here
 *  so agent-roster can share it.
 *
 *  Same null-prototype + freeze rationale as `PHASE_TONE` — closed-sum
 *  boundary must hold for arbitrary backend wire strings. */
export const PHASE_LABEL_KO: Readonly<Record<KeeperPhaseToken, string>> =
  Object.freeze(
    Object.assign(Object.create(null), {
      running: '실행 중',
      paused: '일시정지',
      compacting: '압축 중',
      handoff: '인계 중',
      draining: '정리 중',
      restarting: '재시작 중',
      failing: '오류 발생',
      overflowed: '컨텍스트 초과',
      stopped: '중지됨',
      unbooted: '미기동',
      crashed: '비정상 종료',
      dead: '종료됨',
      unknown: '알 수 없음',
    }) as Record<KeeperPhaseToken, string>,
  )

// The runtime helper `phaseTokenFromPhase` is defined in the workspace
// surface (keeper-workspace-shared.ts) because it depends on
// `KeeperPhase | null | undefined` normalization rules that belong to
// the runtime display layer. This module stays pure data.
