// Keeper Workspace — roster pane (left). Search + status filter chips +
// status-grouped keeper rows. Ported from the v2 design (rails.jsx Roster),
// wired to the live `keepers` store. Selecting a row routes to that keeper,
// which swaps the conversation + rail panes (same route shape the detail
// page already used, so deep links keep working).

import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import type { VNode } from 'preact'
import { keepers } from '../../store'
import { navigate } from '../../router'
import { selectKeeper } from '../../keeper-runtime'
import { keeperActivityDisplay } from '../../lib/keeper-runtime-display'
import type { Keeper } from '../../types'
import {
  WorkspaceSigil,
  StatusDot,
  keeperBucket,
  bucketDotTone,
  keeperPhaseLabel,
  type KeeperBucket,
} from './keeper-workspace-shared'

type RosterFilter = 'all' | 'run' | 'att'

const GROUP_ORDER: { bucket: KeeperBucket; label: string }[] = [
  { bucket: 'running', label: '실행 중' },
  { bucket: 'paused', label: '대기 · 일시정지' },
  { bucket: 'offline', label: '중지 · 종료됨' },
]

/** Blocked tasks + explicit attention flag → the roster attention badge. */
function attentionCount(keeper: Keeper): number {
  return keeper.blocked_task_count ?? 0
}
function needsAttention(keeper: Keeper): boolean {
  return keeper.needs_attention === true || attentionCount(keeper) > 0
}

/** ns proxy: keepers have no namespace field; the skill path is the closest
 *  real scope signal, with the model as fallback. */
function keeperScope(keeper: Keeper): string | null {
  return keeper.skill_primary ?? keeper.active_model ?? keeper.model ?? null
}

function matchesQuery(keeper: Keeper, q: string): boolean {
  if (!q) return true
  const hay = `${keeper.name} ${keeper.koreanName ?? ''} ${keeperScope(keeper) ?? ''} ${keeper.model ?? ''}`.toLowerCase()
  return hay.includes(q.toLowerCase())
}

function RosterRow({ keeper, active, onSelect }: { keeper: Keeper; active: boolean; onSelect: (name: string) => void }) {
  const bucket = keeperBucket(keeper)
  const tone = bucketDotTone(bucket)
  const att = attentionCount(keeper)
  const scope = keeperScope(keeper)
  const activity = keeperActivityDisplay(keeper)
  return html`
    <button
      type="button"
      class="kw-kp-row"
      aria-current=${active ? 'true' : 'false'}
      onClick=${() => onSelect(keeper.name)}
    >
      <${WorkspaceSigil} id=${keeper.name} size=${38} beat=${bucket === 'running'} />
      <div class="kw-kp-meta">
        <div class="kw-kp-name">${keeper.koreanName ?? keeper.name}</div>
        <div class="kw-kp-sub">
          <span class="kw-kp-state"><${StatusDot} tone=${tone} pulse=${bucket === 'running'} />${keeperPhaseLabel(keeper)}</span>
          ${scope ? html`<span aria-hidden="true">·</span><span class="kw-kp-handle">${scope}</span>` : null}
        </div>
      </div>
      <div class="kw-kp-right">
        ${activity.source !== 'none' ? html`<span class="kw-kp-time">${activity.label}</span>` : null}
        ${att > 0 ? html`<span class="kw-kp-att" title=${`주의 ${att}건`}>${att}</span>` : null}
      </div>
    </button>
  `
}

export function KeeperWorkspaceRoster({
  activeName,
  onSelect,
}: {
  activeName: string
  onSelect?: (name: string) => void
}): VNode {
  const [query, setQuery] = useState('')
  const [filter, setFilter] = useState<RosterFilter>('all')

  const all = keepers.value
  const counts = {
    all: all.length,
    run: all.filter(k => keeperBucket(k) === 'running').length,
    att: all.filter(needsAttention).length,
  }

  const visible = all.filter(k => {
    if (filter === 'run' && keeperBucket(k) !== 'running') return false
    if (filter === 'att' && !needsAttention(k)) return false
    return matchesQuery(k, query)
  })

  const select = (name: string) => {
    selectKeeper(name)
    navigate('monitoring', { section: 'agents', keeper: name })
    onSelect?.(name)
  }

  const filterChips: { id: RosterFilter; label: string }[] = [
    { id: 'all', label: '전체' },
    { id: 'run', label: '실행중' },
    { id: 'att', label: '주의' },
  ]

  return html`
    <aside class="kw-roster" aria-label="키퍼 로스터">
      <div class="kw-roster-head">
        <input
          class="kw-roster-search"
          type="text"
          placeholder="이름 · 스코프 검색…"
          aria-label="키퍼 검색"
          value=${query}
          onInput=${(e: Event) => setQuery((e.target as HTMLInputElement).value)}
        />
      </div>
      <div class="kw-roster-filters" role="group" aria-label="상태 필터">
        ${filterChips.map(chip => html`
          <button
            type="button"
            class="kw-rfilter"
            aria-pressed=${filter === chip.id ? 'true' : 'false'}
            onClick=${() => setFilter(chip.id)}
          >
            ${chip.label}<span class="n">${counts[chip.id]}</span>
          </button>
        `)}
      </div>
      <div class="kw-roster-list">
        ${GROUP_ORDER.map(group => {
          const rows = visible.filter(k => keeperBucket(k) === group.bucket)
          if (rows.length === 0) return null
          return html`
            <div>
              <div class="kw-roster-group">${group.label}</div>
              ${rows.map(k => html`<${RosterRow} key=${k.name} keeper=${k} active=${k.name === activeName} onSelect=${select} />`)}
            </div>
          `
        })}
        ${visible.length === 0 ? html`<div class="kw-roster-empty">일치하는 키퍼가 없습니다</div>` : null}
      </div>
    </aside>
  `
}
