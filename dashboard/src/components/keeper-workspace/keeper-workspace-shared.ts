// Keeper Workspace — shared presentational helpers (sigil avatar, status dot,
// phase/group derivation). Kept separate so the roster + chat header + rail
// agree on a single status vocabulary instead of each re-deriving it.

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { kSlot, kSigil } from '../keeper-badge'
import { keeperDisplayStatus } from '../../lib/keeper-runtime-display'
import { isKeeperOffline, isKeeperPaused } from '../../lib/keeper-predicates'
import type { Keeper } from '../../types'

/** Coarse lifecycle bucket used both for the dot tone and roster grouping. */
export type KeeperBucket = 'running' | 'paused' | 'offline'

export function keeperBucket(keeper: Keeper): KeeperBucket {
  if (isKeeperOffline(keeper)) return 'offline'
  if (isKeeperPaused(keeper)) return 'paused'
  return 'running'
}

export type DotTone = 'ok' | 'warn' | 'bad' | 'idle'

const DOT_CLASS: Record<DotTone, string> = {
  ok: 'kw-dot ok',
  warn: 'kw-dot warn',
  bad: 'kw-dot bad',
  idle: 'kw-dot',
}

export function StatusDot({ tone, pulse }: { tone: DotTone; pulse?: boolean }): VNode {
  return html`<span class=${`${DOT_CLASS[tone]}${pulse ? ' pulse' : ''}`} aria-hidden="true"></span>`
}

/** Canonical color + 2-letter sigil avatar at an arbitrary size (KeeperBadge
 *  tops out at 24px; the chat hero needs 46px). Reuses the same kSlot/kSigil
 *  registry so colors match the rest of the dashboard. */
export function WorkspaceSigil({
  id,
  size,
  beat = false,
}: {
  id: string
  size: number
  beat?: boolean
}): VNode {
  const slot = kSlot(id)
  const sigil = kSigil(id)
  // B4: expose the slot glow as --sigil-glow so the CSS kw-sigil-beat keyframe
  // can pulse it (replacing the old static box-shadow). Always set so a
  // non-beating sigil that later starts beating already has the color wired.
  const style = {
    width: `${size}px`,
    height: `${size}px`,
    fontSize: `${Math.round(size * 0.42)}px`,
    background: `var(--color-keeper-${slot})`,
    '--sigil-glow': `var(--color-keeper-${slot}-glow)`,
  }
  return html`<span class=${`kw-sigil${beat ? ' kw-sigil-beat' : ''}`} style=${style} title=${id} aria-label=${id}>${sigil}</span>`
}

/** Friendly (Korean) label per canonical status token. Keyed on the tokens
 *  keeperDisplayStatus emits (lib/keeper-runtime-display.ts keeperLifecycleStatus),
 *  so the roster row + header pill read the same vocabulary as the rest of the
 *  dashboard instead of the raw PascalCase FSM enum (e.g. "Compacting"). */
const PHASE_LABEL_KO: Record<string, string> = {
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
  idle: '유휴',
  unknown: '알 수 없음',
}

/** Phase label shown in the roster sub-row and the chat header state pill.
 *  Routes through keeperDisplayStatus so error/transient phases surface with
 *  the same token vocabulary the rest of the dashboard uses, then maps to a
 *  Korean label. Previously returned the raw `lifecycle_phase` enum, which
 *  leaked "Running"/"Compacting"/"HandingOff" into the UI. */
export function keeperPhaseLabel(keeper: Keeper): string {
  const token = keeperDisplayStatus(keeper)
  return PHASE_LABEL_KO[token] ?? token
}

/** Error phases that must not render as a healthy green dot. */
const ERROR_STATUS_TOKENS = new Set(['failing', 'overflowed', 'crashed', 'dead', 'zombie'])
/** Transient / attention phases that warrant a warn (amber) dot. */
const WARN_STATUS_TOKENS = new Set(['paused', 'compacting', 'handoff', 'draining', 'restarting'])

/** Health tone for the status dot + header pill.
 *
 *  Distinct from keeperBucket, which only groups running/paused/offline for
 *  the roster: a Failing or Overflowed keeper is neither offline nor paused,
 *  so the bucket classifies it as "running" and it would render a green dot
 *  while actually degraded. This maps the canonical status token to a tone so
 *  error phases surface as `bad` (the .kw-dot.bad / .kw-state-pill.bad styles
 *  that were otherwise unreachable). */
export function keeperStatusTone(keeper: Keeper): DotTone {
  const token = keeperDisplayStatus(keeper)
  if (ERROR_STATUS_TOKENS.has(token)) return 'bad'
  if (WARN_STATUS_TOKENS.has(token)) return 'warn'
  if (token === 'running') return 'ok'
  return 'idle'
}

/** The state-pill modifier class for the chat header, derived from the health
 *  tone so error phases get the `bad` pill rather than collapsing to `off`. */
export function statePillTone(tone: DotTone): 'run' | 'warn' | 'bad' | 'off' {
  if (tone === 'ok') return 'run'
  if (tone === 'warn') return 'warn'
  if (tone === 'bad') return 'bad'
  return 'off'
}

/** Current model label, reading the populated fields directly
 *  (keeperDisplayModel is a stub that returns null upstream). */
export function keeperModelLabel(keeper: Keeper): string | null {
  return keeper.active_model_label ?? keeper.active_model ?? keeper.model ?? null
}

/** Current runtime label for the header/rail. */
export function keeperRuntimeLabel(keeper: Keeper): string | null {
  return keeper.runtime_canonical ?? keeper.selected_runtime_canonical ?? null
}
