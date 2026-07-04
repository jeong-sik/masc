// Keeper Workspace — roster pane (left). Search + status filter chips +
// status-grouped keeper rows. Ported from the v2 design (rails.jsx Roster),
// wired to the live `keepers` store. Selecting a row routes to that keeper,
// which swaps the conversation + rail panes (same route shape the detail
// page already used, so deep links keep working).

import { html } from 'htm/preact'
import {
  MessageSquare,
  MoreVertical,
  Pause,
  Play,
  RotateCcw,
  Search,
  Settings,
  Square,
} from 'lucide-preact'
import { useEffect, useState } from 'preact/hooks'
import type { VNode } from 'preact'
import { keepers } from '../../store'
import { navigate } from '../../router'
import { selectKeeper } from '../../keeper-actions'
import { keeperMobilePane } from '../keeper-detail-state'
import { formatRelativeSec } from '../../lib/format-time'
import { keeperActivityDisplay, keeperDisplayRuntime } from '../../lib/keeper-runtime-display'
import type { KeeperActivityDisplay } from '../../lib/keeper-runtime-display'
import { keeperActionVisibility } from '../../lib/keeper-predicates'
import { sortByRecency } from '../../lib/keeper-recency'
import type { Keeper } from '../../types'
import { runKeeperAction, type KeeperActionKey } from '../keeper-action-panel'
import { VirtualList } from '../common/virtual-list'
import {
  WorkspaceSigil,
  StatusDot,
  keeperBucket,
  keeperFleetTone,
  keeperStatusTone,
  keeperPhaseLabel,
  type KeeperBucket,
} from './keeper-workspace-shared'
import { phasePulse } from '../v2/keeper-fsm'

type RosterFilter = 'all' | 'run' | 'att'
type RosterSort = 'status' | 'recent' | 'name' | 'att'
type KeeperWorkspaceRouteSurface = 'monitoring' | 'keepers'
type RosterMenuState = { keeper: Keeper; x: number; y: number } | null
type IconComponent = typeof Play
type RosterHeaderBucket = KeeperBucket | 'attention'
type RosterFleetSummary = {
  total: number
  running: number
  paused: number
  offline: number
  attention: number
  approvalGate: number
  highContext: number
}

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
  | { type: 'header'; bucket: RosterHeaderBucket; label: string; count: number }
  | { type: 'row'; keeper: Keeper }

/** Switch to the shared VirtualList once the roster is long enough that DOM
 *  weight matters. Below this we keep the identical grouped DOM structure and
 *  rely on content-visibility:auto for cheap off-screen skipping. */
const WINDOW_AT = 60
const ROSTER_ROW_ESTIMATED_HEIGHT = 92

/** Blocked tasks + explicit attention flag → the roster attention badge. */
function attentionCount(keeper: Keeper): number {
  return keeper.blocked_task_count ?? (keeper.needs_attention === true ? 1 : 0)
}
function needsAttention(keeper: Keeper): boolean {
  return keeper.needs_attention === true || attentionCount(keeper) > 0
}

function keeperContextRatio(keeper: Keeper): number {
  if (typeof keeper.context_ratio === 'number' && Number.isFinite(keeper.context_ratio)) {
    return Math.max(0, Math.min(1, keeper.context_ratio))
  }
  const current = keeper.context_tokens ?? keeper.context?.context_tokens ?? 0
  const max = keeper.context_max ?? keeper.context?.context_max ?? 0
  return max > 0 ? Math.max(0, Math.min(1, current / max)) : 0
}

function keeperStatusRank(keeper: Keeper): number {
  const bucket = keeperBucket(keeper)
  if (bucket === 'running') return 0
  if (bucket === 'paused') return 1
  return 2
}

function compareFleetRows(a: Keeper, b: Keeper): number {
  return keeperStatusRank(a) - keeperStatusRank(b)
    || keeperContextRatio(b) - keeperContextRatio(a)
    || a.name.localeCompare(b.name)
}

export function rosterFleetSummary(rows: readonly Keeper[]): RosterFleetSummary {
  const summary: RosterFleetSummary = {
    total: rows.length,
    running: 0,
    paused: 0,
    offline: 0,
    attention: 0,
    approvalGate: 0,
    highContext: 0,
  }

  for (const keeper of rows) {
    const bucket = keeperBucket(keeper)
    if (bucket === 'running') summary.running += 1
    if (bucket === 'paused') summary.paused += 1
    if (bucket === 'offline') summary.offline += 1
    if (needsAttention(keeper)) summary.attention += 1
    if (keeper.current_gate?.kind === 'approval_required') summary.approvalGate += 1
    if (keeperContextRatio(keeper) >= 0.8) {
      summary.highContext += 1
    }
  }

  return summary
}

/** Numeric attention weight for the 'att' sort: attention-needing keepers rank
 *  above the rest, ordered by blocked-task count (min 1 when only the flag is
 *  set, so a flagged-but-unblocked keeper still outranks a calm one). Mirrors
 *  the v2 roster's numeric `k.att` sort key. */
function attentionScore(keeper: Keeper): number {
  return needsAttention(keeper) ? Math.max(1, attentionCount(keeper)) : 0
}

/** Comparator for the 'name'/'att' flat sort modes. 'status' keeps the bucket
 *  grouping and 'recent' uses sortByRecency (decorate-sort-undecorate); neither
 *  reaches here. Name ties break alphabetically so the order is stable. */
function compareKeepers(a: Keeper, b: Keeper, sort: 'name' | 'att'): number {
  if (sort === 'name') return a.name.localeCompare(b.name)
  return attentionScore(b) - attentionScore(a) || keeperContextRatio(b) - keeperContextRatio(a) || a.name.localeCompare(b.name)
}

/** ns proxy: keepers have no namespace field; the skill path is the closest
 *  real scope signal, with runtime identity as fallback. */
function keeperScope(keeper: Keeper): string | null {
  return keeper.skill_primary ?? keeperDisplayRuntime(keeper)?.value ?? null
}

/** The keeper's sandbox location — the design's roster identity sub-line
 *  (rails.jsx renders `k.basepath` here). The live field is `sandbox_target`
 *  (keeper-detail-alert-strip.ts:252 uses the same field); for a `local`
 *  profile it is the worktree root path, for `docker` the container target.
 *  Unlike the alert strip, this deliberately does NOT fall back to
 *  `sandbox_profile`: a bare 'local'/'docker' literal is not a useful roster
 *  identity, so RosterRow falls through to the scope proxy (skill/runtime) instead. */
function keeperBasepath(keeper: Keeper): string {
  return keeper.sandbox_target?.trim() ?? ''
}

/** Local worktree roots are long absolute paths that end-ellipsis to an
 *  unhelpful common prefix in the narrow column, so show the last two segments
 *  (the identifying tail) with the full path in `title`. Non-path targets
 *  (e.g. a docker target) are shown verbatim. */
function shortBasepath(value: string): string {
  if (!value.startsWith('/')) return value
  const parts = value.split('/').filter(Boolean)
  return parts.length <= 2 ? value : `…/${parts.slice(-2).join('/')}`
}

function cleanToolNames(names: readonly string[] | null | undefined): string[] {
  return (names ?? []).map(name => name.trim()).filter(Boolean)
}

/** Recent-tool signal for v2 fleet parity.
 *  Prefer the dashboard summary's latest_tool_names, then the older
 *  recent_tool_names field. Do not fetch row-local tool-call logs here: the
 *  roster is a fleet-wide surface and must stay backed by the already-loaded
 *  keeper snapshot instead of N per-row network requests or prototype seeds. */
function keeperRecentTool(keeper: Keeper): { label: string; title: string } | null {
  const latest = cleanToolNames(keeper.latest_tool_names)
  const recent = latest.length > 0 ? latest : cleanToolNames(keeper.recent_tool_names)
  const count = keeper.latest_tool_call_count
  const hasCount = typeof count === 'number' && Number.isFinite(count) && count > 0
  if (recent.length === 0 && !hasCount) return null
  const label = recent[0] ?? `${count} tool calls`
  const countSuffix = hasCount ? ` · ${count} calls` : ''
  return {
    label,
    title: `${recent.join(', ') || label}${countSuffix}`,
  }
}

function matchesQuery(keeper: Keeper, q: string): boolean {
  if (!q) return true
  const hay = `${keeper.name} ${keeper.koreanName ?? ''} ${keeperScope(keeper) ?? ''} ${keeperBasepath(keeper)}`.toLowerCase()
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
  const tone = keeperFleetTone(keeper)
  const att = attentionCount(keeper)
  const scope = keeperScope(keeper)
  const basepath = keeperBasepath(keeper)
  // Design roster identity sub-line = basepath; fall back to the scope proxy
  // when a keeper has no sandbox target yet so the row never loses its sub-label.
  const handle = basepath ? shortBasepath(basepath) : scope
  const handleTitle = basepath || scope || ''
  const contextRatio =
    typeof keeper.context_ratio === 'number' && Number.isFinite(keeper.context_ratio)
      ? Math.min(1, Math.max(0, keeper.context_ratio))
      : null
  const contextPct = contextRatio === null ? null : Math.round(contextRatio * 100)
  const contextHot = contextRatio !== null && contextRatio >= 0.8
  const activity = keeperActivityDisplay(keeper, undefined, { includeCreated: false })
  const activityText = rosterActivityText(activity)
  const recentTool = keeperRecentTool(keeper)
  const phaseLabel = keeperPhaseLabel(keeper)
  const beat = phasePulse(keeper.lifecycle_phase)
  const select = () => onSelect(keeper.name)
  return html`
    <div
      role="button"
      tabindex="0"
      class="kw-kp-row kp-row v2-monitoring-row"
      data-tone=${tone}
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
      <${WorkspaceSigil} id=${keeper.name} size=${38} beat=${beat} />
      <div class="kw-kp-meta">
        <div class="kw-kp-name">${keeper.koreanName ?? keeper.name}</div>
        <div class="kw-kp-sub">
          <span class="kw-kp-state"><${StatusDot} tone=${tone} pulse=${beat} />${phaseLabel}</span>
          ${handle ? html`<span aria-hidden="true">·</span><span class="kw-kp-handle kp-handle" title=${handleTitle}>${handle}</span>` : null}
        </div>
        ${contextPct !== null
          ? html`
              <div class="kw-kp-context" title=${`context ${contextPct}%`}>
                <div class="kw-kp-context-bar" aria-hidden="true">
                  <span class=${contextHot ? 'hot' : ''} style=${{ width: `${contextPct}%` }}></span>
                </div>
                <span class=${`kw-kp-context-val${contextHot ? ' hot' : ''}`}>${contextPct}%</span>
              </div>
            `
          : null}
        ${recentTool
          ? html`
              <div class="kw-kp-tool" title=${recentTool.title}>
                <span class="kw-kp-tool-k">tool</span>
                <span class="kw-kp-tool-v">${recentTool.label}</span>
              </div>
            `
          : null}
      </div>
      <div class="kw-kp-right">
        ${activityText ? html`<span class="kw-kp-time" title=${activity.timestamp ?? activityText}>${activityText}</span>` : null}
        ${att > 0
          ? html`<span class="kw-kp-att kp-att" title=${`주의 신호 ${att}건 · 메시지 수가 아니라 blocked/attention 상태입니다`}>주의 ${att}</span>`
          : null}
      </div>
      <button
        type="button"
        class="kw-kp-more v2-monitoring-action"
        aria-label=${`${keeper.name} 명령 메뉴`}
        title="keeper 명령 메뉴"
        onClick=${(event: MouseEvent) => onMenu(keeper, event)}
        data-testid=${`kw-roster-menu-${keeper.name}`}
      >
        <${MoreVertical} size=${16} focusable="false" aria-hidden="true" />
      </button>
    </div>
  `
}

function MiniRosterRow({
  keeper,
  active,
  onSelect,
  onMenu,
}: {
  keeper: Keeper
  active: boolean
  onSelect: (name: string) => void
  onMenu: (keeper: Keeper, event: MouseEvent) => void
}) {
  const tone = keeperStatusTone(keeper)
  const lifecycle = keeper.phase || keeper.lifecycle_phase
  const beat = phasePulse(lifecycle)
  const label = `${keeper.name} · ${keeperPhaseLabel(keeper)}`
  return html`
    <button
      type="button"
      class="kw-kp-mini kp-row mini v2-monitoring-action"
      aria-current=${active ? 'true' : 'false'}
      aria-label=${label}
      title=${label}
      onClick=${() => onSelect(keeper.name)}
      onContextMenu=${(event: MouseEvent) => onMenu(keeper, event)}
    >
      <${WorkspaceSigil} id=${keeper.name} size=${38} beat=${beat} />
      <${StatusDot} tone=${tone} pulse=${beat} />
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

async function runRosterKeeperAction(name: string, action: KeeperActionKey): Promise<void> {
  await runKeeperAction(name, action)
}

function rosterActivityText(activity: KeeperActivityDisplay): string | null {
  if (activity.source === 'none' || activity.ageSeconds === null) return null
  return `${activity.label} ${formatRelativeSec(activity.ageSeconds)}`
}

function groupBucketClass(bucket: RosterHeaderBucket): string {
  if (bucket === 'attention') return 'att'
  if (bucket === 'running') return 'run'
  if (bucket === 'paused') return 'pause'
  return 'off'
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
        <${WorkspaceSigil} id=${keeper.name} size=${22} beat=${phasePulse(keeper.lifecycle_phase)} />
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
              void runRosterKeeperAction(keeper.name, action)
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
  const [searchOpen, setSearchOpen] = useState(false)
  const [filter, setFilter] = useState<RosterFilter>('all')
  // Default '최근순' (most-recent-first): returning to #keepers should surface the
  // keeper that just did something, not an alphabetically-first name. 상태순 remains
  // available in the sort menu for operators who want running-first grouping.
  const [sort, setSort] = useState<RosterSort>('recent')
  const [menu, setMenu] = useState<RosterMenuState>(null)

  useEffect(() => {
    if (!menu) return
    const close = () => setMenu(null)
    // Esc closes the menu (was: any key — typing in the search box dismissed it);
    // scroll closes it too (capture phase) so the row-anchored menu can't drift
    // away from its row. Mirrors the design roster menu (rails.jsx).
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

  // One clock read per render anchors every 'recent' comparison in this pass so
  // relative (`*_ago_s`) fallbacks stay mutually consistent.
  const nowMs = Date.now()
  const sortRows = (rows: Keeper[]): Keeper[] => {
    if (sort === 'status') return rows
    if (sort === 'recent') return sortByRecency(rows, nowMs)
    return [...rows].sort((a, b) => compareKeepers(a, b, sort))
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
    // Centralized here so both entry points behave: the ⋯ button click and a
    // right-click on the row. preventDefault suppresses the browser's native
    // context menu on right-click; stopPropagation keeps a ⋯ click from also
    // selecting the row (the click would otherwise bubble to the row onClick).
    event.preventDefault()
    event.stopPropagation()
    const target = event.currentTarget as HTMLElement
    const rosterRect = target.closest('.kw-roster')?.getBoundingClientRect() ?? { left: 0, top: 0 }
    // Right-click anchors the menu at the cursor (design rails.jsx openMenu); the
    // ⋯ button right-aligns the menu just below itself.
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
    setMenu({
      keeper,
      x: viewportX - rosterRect.left,
      y: viewportY - rosterRect.top,
    })
  }

  const filterChips: { id: RosterFilter; label: string }[] = [
    { id: 'all', label: '전체' },
    { id: 'run', label: '실행' },
    { id: 'att', label: '주의' },
  ]

  // Flatten to [{ type: 'header'|'row', ... }] for windowing. 'status' keeps the
  // bucket grouping with headers; 'name'/'att' produce a flat sorted list with no
  // headers, mirroring the v2 roster sort modes (rails.jsx Roster).
  const items: RosterItem[] = []
  if (sort === 'status') {
    const attentionRows = visible.filter(needsAttention).sort((a, b) =>
      attentionScore(b) - attentionScore(a)
      || keeperContextRatio(b) - keeperContextRatio(a)
      || a.name.localeCompare(b.name),
    )
    if (attentionRows.length > 0) {
      items.push({ type: 'header', bucket: 'attention', label: '주의 필요', count: attentionRows.length })
      for (const keeper of attentionRows) items.push({ type: 'row', keeper })
    }
    for (const group of GROUP_ORDER) {
      const rows = visible
        .filter(k => !needsAttention(k) && keeperBucket(k) === group.bucket)
        .sort(compareFleetRows)
      if (rows.length === 0) continue
      items.push({ type: 'header', bucket: group.bucket, label: group.label, count: rows.length })
      for (const keeper of rows) items.push({ type: 'row', keeper })
    }
  } else {
    for (const keeper of sortRows(visible)) {
      items.push({ type: 'row', keeper })
    }
  }

  const useVirtual = items.length > WINDOW_AT
  const rowStyle = `content-visibility:auto;contain-intrinsic-size:auto ${ROSTER_ROW_ESTIMATED_HEIGHT}px`
  const miniRows = sortRows(all)

  // Single source for the group header so the windowed and non-windowed render
  // paths can't drift (they previously inlined the header markup separately).
  function renderHeader(item: Extract<RosterItem, { type: 'header' }>): VNode {
    const bucketClass = groupBucketClass(item.bucket)
    return html`
      <div
        class=${`kw-roster-group roster-group ${bucketClass} v2-monitoring-row`}
        key=${`h:${item.bucket}`}
        title=${item.label}
      >
        <span class="rg-dot" aria-hidden="true"></span>
        <span class="kw-roster-group-label">${item.label}</span>
        <span class="kw-roster-group-n rg-n">${item.count}</span>
      </div>
    `
  }

  function renderItem(item: RosterItem): VNode {
    if (item.type === 'header') {
      return renderHeader(item)
    }
    return html`<${RosterRow} keeper=${item.keeper} active=${item.keeper.name === activeName} onSelect=${select} onMenu=${openMenu} />`
  }

  function getKey(item: RosterItem): string {
    return item.type === 'header' ? `h:${item.bucket}` : item.keeper.name
  }

  return html`
    <aside class=${`kw-roster roster${mini ? ' mini' : ''} v2-monitoring-surface`} aria-label="키퍼 로스터">
      ${mini
        ? html`<div class="kw-roster-mini-list">
            ${miniRows.map(k => html`<${MiniRosterRow} key=${k.name} keeper=${k} active=${k.name === activeName} onSelect=${select} onMenu=${openMenu} />`)}
          </div>`
        : html`
          <div class="kw-roster-head v2-monitoring-toolbar">
            <div class="kw-roster-filters roster-filters" role="group" aria-label="상태 필터">
              ${filterChips.map(chip => html`
                <button
                  type="button"
                  class="kw-rfilter rfilter v2-monitoring-action"
                  aria-pressed=${filter === chip.id ? 'true' : 'false'}
                  onClick=${() => setFilter(chip.id)}
                >
                  ${chip.label}<span class="n">${counts[chip.id]}</span>
                </button>
              `)}
              <button
                type="button"
                class="kw-rfilter-icon rfilter-icon v2-monitoring-action"
                aria-label="키퍼 검색"
                title="키퍼 검색"
                aria-pressed=${searchOpen ? 'true' : 'false'}
                aria-expanded=${searchOpen ? 'true' : 'false'}
                onClick=${() => setSearchOpen(open => !open)}
              >
                <${Search} size=${14} aria-hidden="true" />
              </button>
              <select
                class="kw-roster-sort roster-sort v2-monitoring-action"
                aria-label="키퍼 정렬"
                value=${sort}
                onChange=${(e: Event) => setSort((e.target as HTMLSelectElement).value as RosterSort)}
              >
                <option value="recent">최근순</option>
                <option value="status">상태순</option>
                <option value="name">이름순</option>
                <option value="att">주의순</option>
              </select>
            </div>
            ${searchOpen || query
              ? html`
                  <input
                    class="kw-roster-search roster-search"
                    type="text"
                    placeholder="이름 · 스코프 검색…"
                    aria-label="키퍼 검색"
                    value=${query}
                    onInput=${(e: Event) => setQuery((e.target as HTMLInputElement).value)}
                  />
                `
              : null}
          </div>
          ${visible.length === 0
            ? html`<div class="kw-roster-list roster-list"><div class="kw-roster-empty v2-monitoring-row">일치하는 키퍼가 없습니다</div></div>`
        : useVirtual
          ? html`<${VirtualList}
              items=${items}
              estimatedItemHeight=${ROSTER_ROW_ESTIMATED_HEIGHT}
              className="kw-roster-list roster-list"
              renderItem=${renderItem}
              getKey=${getKey}
            />`
          : html`<div class="kw-roster-list roster-list">
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
    </aside>
  `
}
