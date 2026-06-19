// Keeper Workspace — roster pane (left). Search + status filter chips +
// status-grouped keeper rows. Ported from the v2 design (rails.jsx Roster),
// wired to the live `keepers` store. Selecting a row routes to that keeper,
// which swaps the conversation + rail panes (same route shape the detail
// page already used, so deep links keep working).

import { html } from 'htm/preact'
import {
  MessageSquare,
  MoreHorizontal,
  Pause,
  Play,
  RotateCcw,
  Settings,
  Square,
} from 'lucide-preact'
import { useEffect, useState } from 'preact/hooks'
import type { VNode } from 'preact'
import { keepers } from '../../store'
import { navigate } from '../../router'
import { selectKeeper } from '../../keeper-runtime'
import { keeperMobilePane } from '../keeper-detail-state'
import { keeperActivityDisplay, keeperWorkPreview } from '../../lib/keeper-runtime-display'
import { keeperActionVisibility } from '../../lib/keeper-predicates'
import type { Keeper } from '../../types'
import { runKeeperAction, type KeeperActionKey } from '../keeper-action-panel'
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
type KeeperWorkspaceRouteSurface = 'monitoring' | 'keepers'
type RosterMenuState = { keeper: Keeper; x: number; y: number } | null
type IconComponent = typeof Play

const LIFECYCLE_COPY: Record<KeeperActionKey, { label: string; title: string; icon: IconComponent; danger?: boolean }> = {
  pause: {
    label: '일시정지',
    title: '일시정지: 실행 중인 keeper 를 일시 멈춥니다',
    icon: Pause,
  },
  resume: {
    label: '재개',
    title: '재개: 일시정지된 keeper 를 다시 실행합니다',
    icon: Play,
  },
  wakeup: {
    label: '깨우기',
    title: '깨우기: 다음 turn 을 즉시 시도합니다',
    icon: RotateCcw,
  },
  boot: {
    label: '기동',
    title: '기동: offline keeper 를 다시 시작합니다',
    icon: Play,
  },
  shutdown: {
    label: '종료',
    title: '종료: keeper 를 완전 종료합니다',
    icon: Square,
    danger: true,
  },
}
const MENU_WIDTH = 190
const MENU_ESTIMATED_HEIGHT = 246
const MENU_VIEWPORT_MARGIN = 8

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
  return keeper.blocked_task_count ?? (keeper.needs_attention === true ? 1 : 0)
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
  onMenu,
  style,
}: {
  keeper: Keeper
  active: boolean
  onSelect: (name: string) => void
  onMenu: (keeper: Keeper, event: MouseEvent) => void
  style?: string
}) {
  const bucket = keeperBucket(keeper)
  const tone = keeperStatusTone(keeper)
  const att = attentionCount(keeper)
  const scope = keeperScope(keeper)
  const activity = keeperActivityDisplay(keeper)
  const work = keeperWorkPreview(keeper)
  const select = () => onSelect(keeper.name)
  return html`
    <div
      role="button"
      tabindex="0"
      class="kw-kp-row v2-monitoring-row"
      style=${style}
      aria-current=${active ? 'true' : 'false'}
      onClick=${select}
      onKeyDown=${(event: KeyboardEvent) => {
        if (event.key !== 'Enter' && event.key !== ' ') return
        event.preventDefault()
        select()
      }}
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
      <button
        type="button"
        class="kw-kp-more v2-monitoring-action"
        aria-label=${`${keeper.name} 명령`}
        title="keeper 명령"
        onClick=${(event: MouseEvent) => {
          event.preventDefault()
          event.stopPropagation()
          onMenu(keeper, event)
        }}
        data-testid=${`kw-roster-menu-${keeper.name}`}
      >
        <${MoreHorizontal} size=${15} aria-hidden="true" />
      </button>
    </div>
  `
}

function MiniRosterRow({
  keeper,
  active,
  onSelect,
}: {
  keeper: Keeper
  active: boolean
  onSelect: (name: string) => void
}) {
  const bucket = keeperBucket(keeper)
  const tone = keeperStatusTone(keeper)
  const label = `${keeper.name} · ${keeperPhaseLabel(keeper)}`
  return html`
    <button
      type="button"
      class="kw-kp-mini v2-monitoring-action"
      aria-current=${active ? 'true' : 'false'}
      aria-label=${label}
      title=${label}
      onClick=${() => onSelect(keeper.name)}
    >
      <${WorkspaceSigil} id=${keeper.name} size=${38} beat=${bucket === 'running'} />
      <${StatusDot} tone=${tone} pulse=${bucket === 'running'} />
    </button>
  `
}

function lifecycleActions(keeper: Keeper): KeeperActionKey[] {
  const visibility = keeperActionVisibility(keeper)
  const actions: KeeperActionKey[] = []
  if (visibility.canBoot) actions.push('boot')
  if (visibility.canResume) actions.push('resume')
  if (visibility.canWake && !visibility.canBoot) actions.push('wakeup')
  if (visibility.canPause) actions.push('pause')
  if (visibility.canShutdown) actions.push('shutdown')
  return actions
}

function KeeperRosterMenu({
  state,
  onClose,
  onSelect,
  onOpenConfig,
}: {
  state: Exclude<RosterMenuState, null>
  onClose: () => void
  onSelect: (name: string) => void
  onOpenConfig?: (name: string) => void
}): VNode {
  const keeper = state.keeper
  const actions = lifecycleActions(keeper)
  const select = () => {
    onSelect(keeper.name)
    onClose()
  }
  const openConfig = () => {
    onSelect(keeper.name)
    if (onOpenConfig) {
      onOpenConfig(keeper.name)
    }
    onClose()
  }

  return html`
    <div
      class="kw-kp-menu v2-monitoring-surface"
      role="menu"
      style=${{ left: `${state.x}px`, top: `${state.y}px` }}
      onClick=${(event: Event) => event.stopPropagation()}
      data-testid="kw-roster-menu"
    >
      <div class="kw-kp-menu-head v2-monitoring-toolbar">
        <${WorkspaceSigil} id=${keeper.name} size=${22} beat=${keeperBucket(keeper) === 'running'} />
        <span>${keeper.name}</span>
      </div>
      <button type="button" role="menuitem" class="kw-kp-menu-item" onClick=${select} data-testid="kw-roster-menu-open-chat">
        <${MessageSquare} size=${14} aria-hidden="true" />
        <span>대화 열기</span>
      </button>
      ${actions.map(action => {
        const copy = LIFECYCLE_COPY[action]
        const Icon = copy.icon
        return html`
          <button
            key=${action}
            type="button"
            role="menuitem"
            class=${`kw-kp-menu-item${copy.danger ? ' danger' : ''}`}
            title=${copy.title}
            onClick=${() => {
              void runKeeperAction(keeper.name, action)
              onClose()
            }}
            data-testid=${`kw-roster-menu-${action}`}
          >
            <${Icon} size=${14} aria-hidden="true" />
            <span>${copy.label}</span>
          </button>
        `
      })}
      ${actions.length === 0
        ? html`<div class="kw-kp-menu-note">현재 실행 가능한 명령 없음</div>`
        : null}
      <div class="kw-kp-menu-sep"></div>
      <button type="button" role="menuitem" class="kw-kp-menu-item" onClick=${openConfig} data-testid="kw-roster-menu-config">
        <${Settings} size=${14} aria-hidden="true" />
        <span>keeper 설정</span>
      </button>
    </div>
  `
}

export function KeeperWorkspaceRoster({
  activeName,
  onSelect,
  onOpenConfig,
  routeSurface = 'monitoring',
  mini = false,
}: {
  activeName: string
  onSelect?: (name: string) => void
  onOpenConfig?: (name: string) => void
  routeSurface?: KeeperWorkspaceRouteSurface
  mini?: boolean
}): VNode {
  const [query, setQuery] = useState('')
  const [filter, setFilter] = useState<RosterFilter>('all')
  const [sort, setSort] = useState<RosterSort>('status')
  const [menu, setMenu] = useState<RosterMenuState>(null)

  useEffect(() => {
    if (!menu) return
    const close = () => setMenu(null)
    window.addEventListener('click', close)
    window.addEventListener('keydown', close)
    return () => {
      window.removeEventListener('click', close)
      window.removeEventListener('keydown', close)
    }
  }, [menu])

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

  const sortRows = (rows: Keeper[]): Keeper[] => {
    return sort === 'status' ? rows : [...rows].sort((a, b) => compareKeepers(a, b, sort))
  }

  const select = (name: string) => {
    setMenu(null)
    selectKeeper(name)
    // On mobile the roster and conversation share one column; picking a keeper
    // should reveal that keeper's chat (the roster is the "back" target).
    keeperMobilePane.value = 'chat'
    if (routeSurface === 'keepers') {
      navigate('keepers', { keeper: name })
    } else {
      navigate('monitoring', { section: 'agents', keeper: name })
    }
    onSelect?.(name)
  }

  const openMenu = (keeper: Keeper, event: MouseEvent) => {
    const target = event.currentTarget as HTMLElement
    const rect = target.getBoundingClientRect()
    const rosterRect = target.closest('.kw-roster')?.getBoundingClientRect() ?? { left: 0, top: 0 }
    const viewportX = Math.max(
      MENU_VIEWPORT_MARGIN,
      Math.min(rect.right - MENU_WIDTH, window.innerWidth - MENU_WIDTH - MENU_VIEWPORT_MARGIN),
    )
    const viewportY = Math.max(
      MENU_VIEWPORT_MARGIN,
      Math.min(rect.bottom + MENU_VIEWPORT_MARGIN, window.innerHeight - MENU_ESTIMATED_HEIGHT - MENU_VIEWPORT_MARGIN),
    )
    setMenu({
      keeper,
      x: viewportX - rosterRect.left,
      y: viewportY - rosterRect.top,
    })
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
    for (const keeper of sortRows(visible)) {
      items.push({ type: 'row', keeper })
    }
  }

  const useVirtual = items.length > WINDOW_AT
  const rowStyle = 'content-visibility:auto;contain-intrinsic-size:auto 58px'
  const miniRows = sortRows(all)

  function renderItem(item: RosterItem): VNode {
    if (item.type === 'header') {
      return html`<div class="kw-roster-group v2-monitoring-row">${item.label}</div>`
    }
    return html`<${RosterRow} keeper=${item.keeper} active=${item.keeper.name === activeName} onSelect=${select} onMenu=${openMenu} />`
  }

  function getKey(item: RosterItem): string {
    return item.type === 'header' ? `h:${item.bucket}` : item.keeper.name
  }

  return html`
    <aside class=${`kw-roster${mini ? ' mini' : ''} v2-monitoring-surface`} aria-label="키퍼 로스터">
      ${mini
        ? html`<div class="kw-roster-mini-list">
            ${miniRows.map(k => html`<${MiniRosterRow} key=${k.name} keeper=${k} active=${k.name === activeName} onSelect=${select} />`)}
          </div>`
        : html`
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
              class="kw-roster-sort v2-monitoring-action"
              aria-label="키퍼 정렬"
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
              ${items.map(item => item.type === 'header'
                ? html`<div class="kw-roster-group v2-monitoring-row" key=${`h:${item.bucket}`}>${item.label}</div>`
                : html`<${RosterRow} key=${item.keeper.name} keeper=${item.keeper} active=${item.keeper.name === activeName} onSelect=${select} onMenu=${openMenu} style=${rowStyle} />`)}
            </div>`}
        `}
      ${menu
        ? html`<${KeeperRosterMenu}
            state=${menu}
            onClose=${() => setMenu(null)}
            onSelect=${select}
            onOpenConfig=${onOpenConfig}
          />`
        : null}
    </aside>
  `
}
