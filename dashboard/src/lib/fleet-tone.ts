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
// The 'info' name is a drift — agent-roster already shipped 'busy', the
// vendored fleet.css and the prototype (~/Downloads/v2 4/project/keeper-v2/
// data.jsx:36-39 / fleet.jsx:28) both use 'busy'. Lifting the SSOT here
// makes the broader convention win.

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
 *  Derivation: `KeeperPhase` (13 variants) collapses via `keeperLifecycleStatus`
 *  to 13 lowercase tokens, plus `unknown` for the fallback path. We
 *  promote `Zombie` to a first-class entry even though the prototype
 *  `PHASE_TONE` table only has 12 — the live wire emits `Zombie` as a
 *  distinct phase (`KeeperPhase | null`), so the closed sum must cover it.
 *  Zombie is classified as `bad` (degraded, operator must act).
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
  | 'zombie'
  | 'unknown'

/** Closed tone map. Keys MUST match `KeeperPhaseToken` and MUST be kept in
 *  sync with `PHASE_LABEL_KO` below (same keyspace, different value shape).
 *
 *  Authoritative SSOT: the prototype (~/Downloads/v2 4/project/keeper-v2/
 *  data.jsx:36-39) `PHASE_TONE` table. Lowercased here to match the live
 *  `keeperDisplayStatus` wire tokens.
 *
 *  Notable divergence from prototype: prototype marks `Draining` as `warn`
 *  (operator-initiated destructive stop), while
 *  `monitoring-runtime.ts:171` `TRANSIENT_KEEPER_PHASES` treats it as a
 *  transient FSM phase. We follow the prototype — Draining is operator
 *  intent (the `stop` action's danger:true via-phase), not a working-
 *  through state. The RuntimeBand `transient` band divergence is out of
 *  scope here (deferred to a separate PR per the iter-3 plan). */
export const PHASE_TONE: Readonly<Record<KeeperPhaseToken, FleetTone>> = {
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
  zombie: 'bad',
  unknown: 'idle',
}

/** Korean phase label shown in roster sub-rows + chat header state pills.
 *  Keyed on the same lowercase tokens as `PHASE_TONE` so the two tables
 *  cannot drift. Previously lived at the bottom of `keeper-workspace-
 *  shared.ts` and missed `Overflowed` / `Restarting` variants; lifted here
 *  so agent-roster can share it. */
export const PHASE_LABEL_KO: Readonly<Record<KeeperPhaseToken, string>> = {
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
  zombie: '응답 없음',
  unknown: '알 수 없음',
}

// The runtime helper `phaseTokenFromPhase` is defined in the workspace
// surface (keeper-workspace-shared.ts) because it depends on
// `KeeperPhase | null | undefined` normalization rules that belong to
// the runtime display layer. This module stays pure data.