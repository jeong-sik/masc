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
import { keeperMobilePane } from '../keeper-detail-state'
import { keeperActivityDisplay, keeperWorkPreview } from '../../lib/keeper-runtime-display'
import type { Keeper } from '../../types'
import { VirtualList } from '../common/virtual-list'
import {
  WorkspaceSigil,
  StatusDot,
  keeperBucket,
  keeperStatusTone,
  keeperPhaseLabel,
  type KeeperBucket,
} from './keeper-workspace-shared'

type RosterFilter = 'all' | 'run' | 'att'
type RosterSort = 'status' | 'name' | 'att'

const GROUP_ORDER: { bucket: KeeperBucket; label: string }[] = [
  { bucket: 'running', label: '실행 중' },
  { bucket: 'paused', label: '대기 · 일시정지' },
  { bucket: 'offline', label: '중지 · 종료됨' },
]

/** Flattened roster item used by the virtualized render path. */
type RosterItem =
  | { type: 'header'; bucket: KeeperBucket; label: string }
  | { type: 'row'; keeper: Keeper }

/** Switch to the shared VirtualList once the roster is long enough that DOM
 *  weight matters. Below this we keep the identical grouped DOM structure and
 *  rely on content-visibility:auto for cheap off-screen skipping. */
const WINDOW_AT = 60

/** Blocked tasks + explicit attention flag → the roster attention badge. */
function attentionCount(keeper: Keeper): number {
  return keeper.blocked_task_count ?? 0
}
function needsAttention(keeper: Keeper): boolean {
  return keeper.needs_attention === true || attentionCount(keeper) > 0
}

/** Numeric attention weight for the 'att' sort: attention-needing keepers rank
 *  above the rest, ordered by blocked-task count (min 1 when only the flag is
 *  set, so a flagged-but-unblocked keeper still outranks a calm one). Mirrors
 *  the v2 roster's numeric `k.att` sort key. */
function attentionScore(keeper: Keeper): number {
  return needsAttention(keeper) ? Math.max(1, attentionCount(keeper)) : 0
}

/** Comparator for the flat sort modes ('name'/'att'). 'status' keeps the bucket
 *  grouping instead and never reaches here. Name ties break alphabetically so
 *  the order is stable. */
function compareKeepers(a: Keeper, b: Keeper, sort: Exclude<RosterSort, 'status'>): number {
  if (sort === 'name') return a.name.localeCompare(b.name)
  return attentionScore(b) - attentionScore(a) || a.name.localeCompare(b.name)
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

function RosterRow({
  keeper,
  active,
  onSelect,
  style,
}: {
  keeper: Keeper
  active: boolean
  onSelect: (name: string) => void
  style?: string
}) {
  const bucket = keeperBucket(keeper)
  const tone = keeperStatusTone(keeper)
  const att = attentionCount(keeper)
  const scope = keeperScope(keeper)
  const activity = keeperActivityDisplay(keeper)
  const work = keeperWorkPreview(keeper)
  return html`
    <button
      type="button"
      class="kw-kp-row v2-monitoring-row"
      style=${style}
      aria-current=${active ? 'true' : 'false'}
      onClick=${() => onSelect(keeper.name)}
    >
      <${WorkspaceSigil} id=${keeper.name} size=${40} beat=${bucket === 'running'} />
      <div class="kw-kp-meta">
        <div class="kw-kp-name">${keeper.koreanName ?? keeper.name}</div>
        <div class="kw-kp-sub">
          <span class="kw-kp-state"><${StatusDot} tone=${tone} pulse=${bucket === 'running'} />${keeperPhaseLabel(keeper)}</span>
          ${scope ? html`<span aria-hidden="true">·</span><span class="kw-kp-handle">${scope}</span>` : null}
        </div>
        <div class="kw-kp-work" title=${work ?? ''}>${work ?? '최근 작업 요약 없음'}</div>
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
  const [sort, setSort] = useState<RosterSort>('status')

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
    // On mobile the roster and conversation share one column; picking a keeper
    // should reveal that keeper's chat (the roster is the "back" target).
    keeperMobilePane.value = 'chat'
    navigate('monitoring', { section: 'agents', keeper: name })
    onSelect?.(name)
  }

  const filterChips: { id: RosterFilter; label: string }[] = [
    { id: 'all', label: '전체' },
    { id: 'run', label: '실행중' },
    { id: 'att', label: '주의' },
  ]

  // Flatten to [{ type: 'header'|'row', ... }] for windowing. 'status' keeps the
  // bucket grouping with headers; 'name'/'att' produce a flat sorted list with no
  // headers, mirroring the v2 roster sort modes (rails.jsx Roster).
  const items: RosterItem[] = []
  if (sort === 'status') {
    for (const group of GROUP_ORDER) {
      const rows = visible.filter(k => keeperBucket(k) === group.bucket)
      if (rows.length === 0) continue
      items.push({ type: 'header', bucket: group.bucket, label: group.label })
      for (const keeper of rows) {
        items.push({ type: 'row', keeper })
      }
    }
  } else {
    for (const keeper of [...visible].sort((a, b) => compareKeepers(a, b, sort))) {
      items.push({ type: 'row', keeper })
    }
  }

  const useVirtual = items.length > WINDOW_AT
  const rowStyle = 'content-visibility:auto;contain-intrinsic-size:auto 58px'

  function renderItem(item: RosterItem): VNode {
    if (item.type === 'header') {
      return html`<div class="kw-roster-group v2-monitoring-row">${item.label}</div>`
    }
    return html`<${RosterRow} keeper=${item.keeper} active=${item.keeper.name === activeName} onSelect=${select} />`
  }

  function getKey(item: RosterItem): string {
    return item.type === 'header' ? `h:${item.bucket}` : item.keeper.name
  }

  return html`
    <aside class="kw-roster v2-monitoring-surface" aria-label="키퍼 로스터">
      <div class="kw-roster-head v2-monitoring-toolbar">
        <input
          class="kw-roster-search"
          type="text"
          placeholder="이름 · 스코프 검색…"
          aria-label="키퍼 검색"
          value=${query}
          onInput=${(e: Event) => setQuery((e.target as HTMLInputElement).value)}
        />
      </div>
      <div class="kw-roster-filters v2-monitoring-toolbar" role="group" aria-label="상태 필터">
        ${filterChips.map(chip => html`
          <button
            type="button"
            class="kw-rfilter v2-monitoring-action"
            aria-pressed=${filter === chip.id ? 'true' : 'false'}
            onClick=${() => setFilter(chip.id)}
          >
            ${chip.label}<span class="n">${counts[chip.id]}</span>
          </button>
        `)}
        <select
          class="kw-roster-sort"
          aria-label="키퍼 정렬 기준"
          title="정렬 기준"
          value=${sort}
          onChange=${(e: Event) => setSort((e.target as HTMLSelectElement).value as RosterSort)}
        >
          <option value="status">상태순</option>
          <option value="name">이름순</option>
          <option value="att">주의순</option>
        </select>
      </div>
      ${visible.length === 0
        ? html`<div class="kw-roster-list"><div class="kw-roster-empty v2-monitoring-row">일치하는 키퍼가 없습니다</div></div>`
        : useVirtual
          ? html`<${VirtualList}
              items=${items}
              estimatedItemHeight=${58}
              className="kw-roster-list"
              renderItem=${renderItem}
              getKey=${getKey}
            />`
          : html`<div class="kw-roster-list">
              ${items.map(item =>
                item.type === 'header'
                  ? html`<div class="kw-roster-group v2-monitoring-row">${item.label}</div>`
                  : html`<${RosterRow} key=${item.keeper.name} keeper=${item.keeper} active=${item.keeper.name === activeName} onSelect=${select} style=${rowStyle} />`,
              )}
            </div>`}
    </aside>
  `
}
