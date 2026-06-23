// Keeper Workspace — roster pane (left). Ported to the keeper-v2 prototype DOM
// (rails.jsx Roster): `.roster` → `.roster-filters` (전체/실행/주의 + search
// toggle + sort) → `.roster-list` of `.roster-group` + `.kp-row`. Styled by the
// vendored SSOT CSS (keeper-v2/v2.css). All live wiring (the `keepers` store,
// filtering/sorting, the FSM action menu, route-on-select) is unchanged from the
// previous `.kw-*` implementation — only the emitted DOM/classes changed.

import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import type { VNode } from 'preact'
import { keepers } from '../../store'
import { navigate } from '../../router'
import { selectKeeper } from '../../keeper-runtime'
import { keeperMobilePane } from '../keeper-detail-state'
import { keeperActivityDisplay } from '../../lib/keeper-runtime-display'
import { keeperActionVisibility } from '../../lib/keeper-predicates'
import type { Keeper } from '../../types'
import { runKeeperAction, type KeeperActionKey } from '../keeper-action-panel'
import { VirtualList } from '../common/virtual-list'
import { kSlot, kSigil } from '../keeper-badge'
import { SigilBadge, Dot } from '../v2/primitives-v2'
import { phaseTone, phasePulse } from '../v2/keeper-fsm'
import {
  keeperBucket,
  keeperPhaseLabel,
  keeperRuntimeLabel,
  type KeeperBucket,
} from './keeper-workspace-shared'

type RosterFilter = 'all' | 'run' | 'att'
type RosterSort = 'status' | 'name' | 'att'
type KeeperWorkspaceRouteSurface = 'monitoring' | 'keepers'
type RosterMenuState = { keeper: Keeper; x: number; y: number } | null
type RosterHoverState = { keeper: Keeper; x: number; y: number } | null
type RosterFleetSummary = {
  total: number
  running: number
  paused: number
  offline: number
  attention: number
  approvalGate: number
  highContext: number
}

const LIFECYCLE_COPY: Record<KeeperActionKey, { label: string; title: string; glyph: string; danger?: boolean }> = {
  pause: { label: '일시정지', title: '일시정지: 실행 중인 keeper 를 일시 멈춥니다', glyph: '⏸' },
  resume: { label: '재개', title: '재개: 일시정지된 keeper 를 다시 실행합니다', glyph: '▶' },
  wakeup: { label: '깨우기', title: '깨우기: 다음 turn 을 즉시 시도합니다', glyph: '◉' },
  boot: { label: '기동', title: '기동: offline keeper 를 다시 시작합니다', glyph: '▶' },
  shutdown: { label: '종료', title: '종료: keeper 를 완전 종료합니다', glyph: '■', danger: true },
}
const MENU_WIDTH = 190
const MENU_ESTIMATED_HEIGHT = 246
const MENU_VIEWPORT_MARGIN = 8

// Prototype group order + the short header label it uses (rails.jsx groupLabel).
const GROUP_ORDER: { bucket: KeeperBucket; label: string; short: string; cls: string }[] = [
  { bucket: 'running', label: '실행 중', short: '실행 중', cls: 'run' },
  { bucket: 'paused', label: '대기 · 일시정지', short: '대기', cls: 'pause' },
  { bucket: 'offline', label: '중지 · 종료됨', short: '중지', cls: 'off' },
]
const GROUP_BY_BUCKET = Object.fromEntries(GROUP_ORDER.map((g) => [g.bucket, g])) as Record<KeeperBucket, (typeof GROUP_ORDER)[number]>

type RosterItem =
  | { type: 'header'; bucket: KeeperBucket; count: number }
  | { type: 'row'; keeper: Keeper }

const WINDOW_AT = 60

function attentionCount(keeper: Keeper): number {
  return keeper.blocked_task_count ?? (keeper.needs_attention === true ? 1 : 0)
}
function needsAttention(keeper: Keeper): boolean {
  return keeper.needs_attention === true || attentionCount(keeper) > 0
}

export function rosterFleetSummary(rows: readonly Keeper[]): RosterFleetSummary {
  const summary: RosterFleetSummary = {
    total: rows.length, running: 0, paused: 0, offline: 0, attention: 0, approvalGate: 0, highContext: 0,
  }
  for (const keeper of rows) {
    const bucket = keeperBucket(keeper)
    if (bucket === 'running') summary.running += 1
    if (bucket === 'paused') summary.paused += 1
    if (bucket === 'offline') summary.offline += 1
    if (needsAttention(keeper)) summary.attention += 1
    if (keeper.current_gate?.kind === 'approval_required') summary.approvalGate += 1
    if (typeof keeper.context_ratio === 'number' && Number.isFinite(keeper.context_ratio) && keeper.context_ratio >= 0.8) {
      summary.highContext += 1
    }
  }
  return summary
}

function attentionScore(keeper: Keeper): number {
  return needsAttention(keeper) ? Math.max(1, attentionCount(keeper)) : 0
}

function compareKeepers(a: Keeper, b: Keeper, sort: Exclude<RosterSort, 'status'>): number {
  if (sort === 'name') return a.name.localeCompare(b.name)
  return attentionScore(b) - attentionScore(a) || a.name.localeCompare(b.name)
}

function keeperScope(keeper: Keeper): string | null {
  return keeper.skill_primary ?? keeper.active_model ?? keeper.model ?? null
}

// The keeper's sandbox location — the prototype roster identity sub-line
// (rails.jsx renders `k.basepath`). Live field is `sandbox_target`.
function keeperBasepath(keeper: Keeper): string {
  return keeper.sandbox_target?.trim() ?? ''
}

function shortBasepath(value: string): string {
  if (!value.startsWith('/')) return value
  const parts = value.split('/').filter(Boolean)
  return parts.length <= 2 ? value : `…/${parts.slice(-2).join('/')}`
}

function matchesQuery(keeper: Keeper, q: string): boolean {
  if (!q) return true
  const hay = `${keeper.name} ${keeper.koreanName ?? ''} ${keeperScope(keeper) ?? ''} ${keeper.model ?? ''} ${keeperBasepath(keeper)}`.toLowerCase()
  return hay.includes(q.toLowerCase())
}

function formatHHMM(timestamp: string | null | undefined): string | null {
  if (!timestamp) return null
  const d = new Date(timestamp)
  if (Number.isNaN(d.getTime())) return null
  return d.toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit', hour12: false })
}

// Prototype kp-state shows the raw English FSM phase ("Running", "Compacting").
function phaseText(keeper: Keeper): string {
  return keeper.lifecycle_phase ?? keeper.phase ?? keeperPhaseLabel(keeper)
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
  const att = attentionCount(keeper)
  const basepath = keeperBasepath(keeper)
  const handle = basepath ? shortBasepath(basepath) : keeperScope(keeper)
  const handleTitle = basepath || keeperScope(keeper) || ''
  const activity = keeperActivityDisplay(keeper)
  const activityTime = formatHHMM(activity.timestamp)
  const select = () => onSelect(keeper.name)
  return html`
    <div
      role="button"
      tabindex="0"
      class=${`kp-row${active ? ' sel' : ''}`}
      style=${style}
      aria-current=${active ? 'true' : 'false'}
      onClick=${select}
      onContextMenu=${(event: MouseEvent) => onMenu(keeper, event)}
      onKeyDown=${(event: KeyboardEvent) => {
        if (event.key !== 'Enter' && event.key !== ' ') return
        event.preventDefault()
        select()
      }}
    >
      <${SigilBadge} slot=${kSlot(keeper.name)} sigil=${kSigil(keeper.name)} size=${38} beat=${bucket === 'running'} title=${keeper.name} />
      <div class="kp-meta">
        <div class="kp-name">${keeper.name}</div>
        <div class="kp-sub">
          <span class="kp-state"><${Dot} state=${phaseTone(keeper.lifecycle_phase)} pulse=${phasePulse(keeper.lifecycle_phase)} />${phaseText(keeper)}</span>
          ${handle ? html`<span aria-hidden="true">·</span><span class="kp-handle" title=${handleTitle}>${handle}</span>` : null}
        </div>
      </div>
      <div class="kp-right">
        ${activityTime ? html`<span class="kp-time" title=${activity.label}>${activityTime}</span>` : null}
        ${att > 0 ? html`<span class="kp-att" title=${`주의 ${att}건 — 컨텍스트 레일에서 확인`}>${att}</span>` : null}
      </div>
      <button
        type="button"
        class="kp-more"
        aria-label=${`${keeper.name} 명령`}
        title="명령 메뉴"
        onClick=${(event: MouseEvent) => onMenu(keeper, event)}
        data-testid=${`kw-roster-menu-${keeper.name}`}
      >
        <span aria-hidden="true">⋯</span>
      </button>
    </div>
  `
}

function MiniRosterRow({
  keeper,
  active,
  onSelect,
  onMenu,
  onHover,
}: {
  keeper: Keeper
  active: boolean
  onSelect: (name: string) => void
  onMenu: (keeper: Keeper, event: MouseEvent) => void
  onHover?: (keeper: Keeper | null, event?: MouseEvent) => void
}) {
  const bucket = keeperBucket(keeper)
  const label = `${keeper.name} · ${phaseText(keeper)}`
  const updateHover = (event: MouseEvent) => {
    onHover?.(keeper, event)
    event.stopPropagation()
  }
  return html`
    <button
      type="button"
      class=${`kp-row mini${active ? ' sel' : ''}`}
      aria-current=${active ? 'true' : 'false'}
      aria-label=${label}
      title=${label}
      onClick=${() => onSelect(keeper.name)}
      onContextMenu=${(event: MouseEvent) => onMenu(keeper, event)}
      onMouseEnter=${updateHover}
      onMouseMove=${updateHover}
      onMouseLeave=${() => onHover?.(null)}
    >
      <${SigilBadge} slot=${kSlot(keeper.name)} sigil=${kSigil(keeper.name)} size=${38} beat=${bucket === 'running'} title=${keeper.name} />
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
  const select = () => { onSelect(keeper.name); onClose() }
  const openConfig = () => {
    onSelect(keeper.name)
    if (onOpenConfig) onOpenConfig(keeper.name)
    onClose()
  }
  return html`
    <div
      class="kp-menu"
      role="menu"
      style=${{ left: `${state.x}px`, top: `${state.y}px` }}
      onClick=${(event: Event) => event.stopPropagation()}
      data-testid="kw-roster-menu"
    >
      <div class="kp-menu-h">
        <${SigilBadge} slot=${kSlot(keeper.name)} sigil=${kSigil(keeper.name)} size=${20} title=${keeper.name} />
        <span class="mono">${keeper.name}</span>
      </div>
      <button type="button" role="menuitem" class="kp-menu-i" onClick=${select} data-testid="kw-roster-menu-open-chat">
        <span aria-hidden="true">◈</span>
        <span>대화 열기</span>
      </button>
      ${actions.map(action => {
        const copy = LIFECYCLE_COPY[action]
        return html`
          <button
            key=${action}
            type="button"
            role="menuitem"
            class=${`kp-menu-i${copy.danger ? ' danger' : ''}`}
            title=${copy.title}
            onClick=${() => { void runKeeperAction(keeper.name, action); onClose() }}
            data-testid=${`kw-roster-menu-${action}`}
          >
            <span aria-hidden="true">${copy.glyph}</span>
            <span>${copy.label}</span>
          </button>
        `
      })}
      ${actions.length === 0
        ? html`<div class="kp-menu-note">${(keeper.lifecycle_phase ?? keeper.phase ?? '').toLowerCase() === 'dead' ? '복구 불가 — 명령 없음' : '전이 중 — 잠시 후'}</div>`
        : null}
      <div class="kp-menu-sep"></div>
      <button type="button" role="menuitem" class="kp-menu-i" onClick=${openConfig} data-testid="kw-roster-menu-config">
        <span aria-hidden="true">⚙</span>
        <span>keeper 설정</span>
      </button>
    </div>
  `
}

function RosterFlyout({ state }: { state: Exclude<RosterHoverState, null> }): VNode {
  const k = state.keeper
  const basepath = keeperBasepath(k)
  const runtime = keeperRuntimeLabel(k)
  const att = attentionCount(k)
  return html`
    <div class="kp-flyout" style=${{ left: `${state.x}px`, top: `${state.y}px` }}>
      <div class="kpf-h">
        <${SigilBadge} slot=${kSlot(k.name)} sigil=${kSigil(k.name)} size=${26} title=${k.name} />
        <div class="kpf-id">
          <div class="kpf-name">${k.name}</div>
          <div class="kpf-phase"><${Dot} state=${phaseTone(k.lifecycle_phase)} pulse=${phasePulse(k.lifecycle_phase)} />${phaseText(k)}</div>
        </div>
      </div>
      ${basepath ? html`<div class="kpf-row"><span class="kpf-k">basepath</span><span class="mono">${basepath}</span></div>` : null}
      ${runtime ? html`<div class="kpf-row"><span class="kpf-k">runtime</span><span class="mono">${runtime}</span></div>` : null}
      ${att > 0 ? html`<div class="kpf-att">${'⚠'} 주의 ${att}건</div>` : null}
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
  const [searchOpen, setSearchOpen] = useState(false)
  const [filter, setFilter] = useState<RosterFilter>('all')
  const [sort, setSort] = useState<RosterSort>('status')
  const [menu, setMenu] = useState<RosterMenuState>(null)
  const [peek, setPeek] = useState(false)
  const [hover, setHover] = useState<RosterHoverState>(null)

  const handleMiniHover = (keeper: Keeper | null, event?: MouseEvent) => {
    if (!keeper || !event) {
      setHover(null)
      return
    }
    const rect = (event.currentTarget as HTMLElement).getBoundingClientRect()
    setHover({ keeper, x: rect.right + 10, y: rect.top + rect.height / 2 })
  }

  useEffect(() => {
    if (!menu) return
    const close = () => setMenu(null)
    const onKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape') setMenu(null)
    }
    window.addEventListener('click', close)
    window.addEventListener('scroll', close, true)
    window.addEventListener('keydown', onKey)
    return () => {
      window.removeEventListener('click', close)
      window.removeEventListener('scroll', close, true)
      window.removeEventListener('keydown', onKey)
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

  const sortRows = (rows: Keeper[]): Keeper[] =>
    sort === 'status' ? rows : [...rows].sort((a, b) => compareKeepers(a, b, sort))

  const select = (name: string) => {
    setMenu(null)
    selectKeeper(name)
    keeperMobilePane.value = 'chat'
    if (routeSurface === 'keepers') {
      navigate('keepers', { keeper: name })
    } else {
      navigate('monitoring', { section: 'agents', keeper: name })
    }
    onSelect?.(name)
  }

  const openMenu = (keeper: Keeper, event: MouseEvent) => {
    event.preventDefault()
    event.stopPropagation()
    const target = event.currentTarget as HTMLElement
    const rosterRect = target.closest('.roster')?.getBoundingClientRect() ?? { left: 0, top: 0 }
    let anchorRight: number
    let anchorTop: number
    if (event.type === 'contextmenu') {
      anchorRight = event.clientX + MENU_WIDTH
      anchorTop = event.clientY
    } else {
      const rect = target.getBoundingClientRect()
      anchorRight = rect.right
      anchorTop = rect.bottom + MENU_VIEWPORT_MARGIN
    }
    const viewportX = Math.max(
      MENU_VIEWPORT_MARGIN,
      Math.min(anchorRight - MENU_WIDTH, window.innerWidth - MENU_WIDTH - MENU_VIEWPORT_MARGIN),
    )
    const viewportY = Math.max(
      MENU_VIEWPORT_MARGIN,
      Math.min(anchorTop, window.innerHeight - MENU_ESTIMATED_HEIGHT - MENU_VIEWPORT_MARGIN),
    )
    setMenu({ keeper, x: viewportX - rosterRect.left, y: viewportY - rosterRect.top })
  }

  const filterChips: { id: RosterFilter; label: string }[] = [
    { id: 'all', label: '전체' },
    { id: 'run', label: '실행' },
    { id: 'att', label: '주의' },
  ]

  const items: RosterItem[] = []
  if (sort === 'status') {
    for (const group of GROUP_ORDER) {
      const rows = visible.filter(k => keeperBucket(k) === group.bucket)
      if (rows.length === 0) continue
      items.push({ type: 'header', bucket: group.bucket, count: rows.length })
      for (const keeper of rows) items.push({ type: 'row', keeper })
    }
  } else {
    for (const keeper of sortRows(visible)) items.push({ type: 'row', keeper })
  }

  const useVirtual = items.length > WINDOW_AT
  const rowStyle = 'content-visibility:auto;contain-intrinsic-size:auto 58px'
  const miniRows = sortRows(all)

  function renderHeader(item: Extract<RosterItem, { type: 'header' }>): VNode {
    const g = GROUP_BY_BUCKET[item.bucket]
    return html`<div class=${`roster-group ${g.cls}`} title=${g.label} key=${`h:${item.bucket}`}><span class="rg-dot"></span>${g.short}<span class="rg-n">${item.count}</span></div>`
  }

  function renderItem(item: RosterItem): VNode {
    if (item.type === 'header') return renderHeader(item)
    return html`<${RosterRow} keeper=${item.keeper} active=${item.keeper.name === activeName} onSelect=${select} onMenu=${openMenu} />`
  }

  function getKey(item: RosterItem): string {
    return item.type === 'header' ? `h:${item.bucket}` : item.keeper.name
  }

  return html`
    <aside
      class=${`roster${mini ? ' mini' : ''}${mini && peek ? ' peek' : ''}`}
      aria-label="키퍼 로스터"
      onMouseEnter=${mini ? () => setPeek(true) : undefined}
      onMouseLeave=${mini ? () => { setPeek(false); setHover(null) } : undefined}
    >
      ${mini && !peek
        ? html`
          <div class="roster-list mini-list">
            ${miniRows.map(k => html`<${MiniRosterRow}
              key=${k.name}
              keeper=${k}
              active=${k.name === activeName}
              onSelect=${select}
              onMenu=${openMenu}
              onHover=${handleMiniHover}
            />`)}
          </div>
        `
        : html`
          <div class="roster-filters" role="group" aria-label="상태 필터">
            ${filterChips.map(chip => html`
              <button
                type="button"
                class=${`rfilter${filter === chip.id ? ' on' : ''}`}
                aria-pressed=${filter === chip.id ? 'true' : 'false'}
                onClick=${() => setFilter(chip.id)}
              >
                ${chip.label}<span class="n">${counts[chip.id]}</span>
              </button>
            `)}
            <button
              type="button"
              class=${`rfilter-icon${searchOpen ? ' on' : ''}`}
              title="검색"
              aria-label="키퍼 검색 토글"
              aria-pressed=${searchOpen ? 'true' : 'false'}
              onClick=${() => setSearchOpen(o => !o)}
            >${'⌕'}</button>
            <select
              class="roster-sort"
              aria-label="키퍼 정렬"
              value=${sort}
              onChange=${(e: Event) => setSort((e.target as HTMLSelectElement).value as RosterSort)}
            >
              <option value="status">상태순</option>
              <option value="name">이름순</option>
              <option value="att">주의순</option>
            </select>
          </div>
          ${searchOpen
            ? html`<div class="roster-head">
                <input
                  class="roster-search"
                  type="text"
                  placeholder="이름·basepath 검색…"
                  aria-label="키퍼 검색"
                  autofocus
                  value=${query}
                  onInput=${(e: Event) => setQuery((e.target as HTMLInputElement).value)}
                />
              </div>`
            : null}
          ${visible.length === 0
            ? html`<div class="roster-list"><div class="roster-empty" style="padding:30px 12px;text-align:center;color:var(--text-dim);font-size:12px">일치하는 Keeper가 없습니다</div></div>`
        : useVirtual
          ? html`<${VirtualList}
              items=${items}
              estimatedItemHeight=${58}
              className="roster-list"
              renderItem=${renderItem}
              getKey=${getKey}
            />`
          : html`<div class="roster-list">
              ${items.map(item => item.type === 'header'
                ? renderHeader(item)
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
      ${hover && mini && !peek ? html`<${RosterFlyout} state=${hover} />` : null}
    </aside>
  `
}
