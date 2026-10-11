import { html } from 'htm/preact'
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { ChevronDown, MessageCircle, PanelRightClose, PanelRightOpen, Sparkles, X } from 'lucide-preact'
import { persistentSignal } from '../lib/persistent-signal'
import { globalShortcutManager } from '../lib/global-shortcut-manager'
import { route } from '../router'
import { keepers } from '../store'
import { DASHBOARD_NAV_ITEMS } from '../config/navigation'
import { currentDashboardActor, currentStoredTokenRevision } from '../api/core'
import { storedTokenRevision } from '../api/token-revision'
import { sendKeeperThreadMessage } from '../keeper-actions'
import { keeperSending, keeperThreads, isDefaultVisibleConversationEntry, isAutonomousTurnEntry } from '../keeper-state'
import { chatShowInternal, chatShowAutonomous, chatShowMetadata, chatExpandAutonomousRuns } from '../lib/chat-view-prefs'
import { ChatTranscript, ChatComposer, type ChatComposerSendPayload } from './chat/primitives'
import { composerMessageOptions } from './chat/composer-message'
import { KeeperBadge } from './keeper-badge'
import type { Keeper } from '../types'
import { useIsMobile } from '../hooks/use-is-mobile'

interface DockState {
  open: boolean
  mode: 'dock' | 'float'
  keeperId: string
  x: number | null
  y: number | null
}

interface SurfaceContext {
  label: string
  route: string
  scene: string
  fields: Array<{ k: string; v: string; tone?: 'bad' | 'warn' | 'volt' }>
}

const FALLBACK_DOCK_STARTERS: string[] = [
  '이 화면 요약해줘',
  '다음 액션 추천',
  '주의 항목 정리해줘',
]

const DOCK_STARTERS_BY_ROUTE: Record<string, string[]> = {
  '/overview': ['주의 큐 정리해줘', '컨텍스트가 높은 keeper 찾아줘', '지금 가장 급한 건 뭐야?'],
  '/keepers': ['이 keeper 지금 뭐 하고 있어?', '소유 태스크 요약', '컨텍스트 압박 풀어줘'],
  '/board': ['멘션 인박스 정리해줘', '최근 보드 흐름 요약', '다음 답글 추천'],
  '/schedule': ['승인 차단 예약 정리', '다음 due 항목 요약', 'wake signal 이상 징후'],
  '/approvals': ['가장 위험한 승인 요청', '승인 전 확인할 맥락', 'keeper별 대기 요약'],
  '/fusion': ['판단 근거 요약', '패널 의견 차이 정리', '다음 검증 추천'],
  '/code': ['현재 코드 화면 요약', '회귀 위험 어디야?', '테스트/검증 경로 추천'],
  '/connectors': ['stale 게이트 확인', '바인딩 현황 요약', '최근 오류 정리'],
  '/settings': ['런타임 바인딩 요약', '위험한 설정 변경점', 'provider 상태 확인'],
  '/logs': ['최근 오류만 정리', '경고 패턴 묶어줘', '다음 조사 경로 추천'],
}

function statusLooksRunning(status?: string | null): boolean {
  const s = (status ?? '').toLowerCase()
  return s === 'running' || s === 'run' || s === 'online' || s === 'healthy'
}

export function starterPromptsForContext(ctx: Pick<SurfaceContext, 'route'>): string[] {
  const routePath = ctx.route.split('?')[0] ?? ctx.route
  const match = Object.keys(DOCK_STARTERS_BY_ROUTE)
    .sort((a, b) => b.length - a.length)
    .find(prefix => routePath === prefix || routePath.startsWith(`${prefix}/`))
  return match ? (DOCK_STARTERS_BY_ROUTE[match] ?? FALLBACK_DOCK_STARTERS) : FALLBACK_DOCK_STARTERS
}

export function getSurfaceContext(selectedKeeperId?: string | null): SurfaceContext {
  const tab = route.value.tab
  const section = route.value.params.section ?? ''
  const navItem = DASHBOARD_NAV_ITEMS.find(item => item.id === tab)
  const sceneMap: Record<string, string> = {
    overview: '함대 전체 상태를 함께 보는 중',
    monitoring: 'keeper와 1:1 스레드',
    keepers: 'Keeper workspace를 함께 보는 중',
    board: 'Board 게시글과 작업 흐름을 함께 보는 중',
    schedule: '예약 자동화와 wake signal을 함께 보는 중',
    approvals: '승인 대기와 HITL gate를 함께 보는 중',
    fusion: 'Fusion 판단/근거 흐름을 함께 보는 중',
    workspace: '네임스페이스 보드를 함께 보는 중',
    code: '코드 모드에서 함께 보는 중',
    connectors: '외부 게이트 상태를 함께 보는 중',
    command: '운영 액션 패널을 함께 보는 중',
    lab: '실험 도구 패널을 함께 보는 중',
    logs: '시스템 로그 스트림을 함께 보는 중',
    settings: '런타임 설정과 provider binding을 함께 보는 중',
  }
  const base: SurfaceContext = {
    label: navItem?.label ?? tab,
    route: `/${tab}${section ? `/${section}` : ''}`,
    scene: sceneMap[tab] ?? `${tab} 화면을 함께 보는 중`,
    fields: [],
  }

  const keeperIdFromRoute = route.value.params.keeper?.trim() || null
  const selectedKeeperKey = keeperIdFromRoute || selectedKeeperId?.trim() || null
  const selectedKeeper = selectedKeeperKey
    ? keepers.value.find(k => k.name === selectedKeeperKey || k.keeper_id === selectedKeeperKey)
    : null
  const live = keepers.value.filter(k => statusLooksRunning(k.status))
  const run = live.length
  const total = keepers.value.length
  const att = keepers.value.filter(k => k.needs_attention).length
  const traces = keepers.value.reduce((a, k) => a + (typeof k.total_turns === 'number' ? k.total_turns : 0), 0)
  const observedContextRatios = keepers.value
    .map(k => k.context_ratio)
    .filter((ratio): ratio is number => typeof ratio === 'number')
  const avgContextRatio = observedContextRatios.length > 0
    ? observedContextRatios.reduce((sum, ratio) => sum + ratio, 0) / observedContextRatios.length
    : null
  const fleetFields: SurfaceContext['fields'] = [
    { k: '실행', v: `${run}/${total}` },
    { k: '주의', v: String(att), tone: att > 0 ? 'bad' : undefined },
    {
      k: 'ctx',
      v: avgContextRatio == null ? '미관측' : `${Math.round(avgContextRatio * 100)}%`,
      tone: avgContextRatio == null ? undefined : avgContextRatio >= 0.85 ? 'warn' : 'volt',
    },
  ]

  switch (tab) {
    case 'overview':
      base.fields = [
        ...fleetFields,
        { k: 'trace', v: traces.toLocaleString() },
      ]
      break
    case 'keepers':
      if (selectedKeeper) {
        const ctx = typeof selectedKeeper.context_ratio === 'number' ? selectedKeeper.context_ratio : null
        base.scene = `${selectedKeeper.koreanName ?? selectedKeeper.name}와 1:1 스레드`
        base.fields = [
          { k: 'state', v: selectedKeeper.phase ?? selectedKeeper.status },
          {
            k: 'ctx',
            v: ctx == null ? '미관측' : `${Math.round(ctx * 100)}%`,
            tone: ctx == null ? undefined : ctx >= 0.85 ? 'warn' : 'volt',
          },
          { k: 'ns', v: selectedKeeper.runtime_canonical ?? selectedKeeper.runtime_id ?? '-' },
        ]
      } else {
        base.fields = [
          ...fleetFields,
          { k: 'trace', v: traces.toLocaleString() },
        ]
      }
      break
    case 'board':
      base.fields = [
        { k: 'keepers', v: String(total), tone: total > 0 ? 'volt' : undefined },
        { k: '주의', v: String(att), tone: att > 0 ? 'bad' : undefined },
        { k: 'trace', v: traces.toLocaleString() },
      ]
      break
    case 'approvals':
      base.fields = [
        { k: '주의', v: String(att), tone: att > 0 ? 'bad' : undefined },
        { k: '실행', v: `${run}/${total}` },
      ]
      break
    case 'fusion':
    case 'registry':
    case 'settings':
      base.fields = fleetFields
      break
    case 'monitoring': {
      if (selectedKeeper) {
        const ctx = typeof selectedKeeper.context_ratio === 'number' ? selectedKeeper.context_ratio : null
        base.scene = `${selectedKeeper.koreanName ?? selectedKeeper.name}와 1:1 스레드`
        base.fields = [
          { k: 'state', v: selectedKeeper.phase ?? selectedKeeper.status },
          {
            k: 'ctx',
            v: ctx == null ? '미관측' : `${Math.round(ctx * 100)}%`,
            tone: ctx == null ? undefined : ctx >= 0.85 ? 'warn' : 'volt',
          },
          { k: 'ns', v: selectedKeeper.runtime_canonical ?? selectedKeeper.runtime_id ?? '-' },
        ]
      }
      break
    }
  }
  return base
}

interface DockKeeper {
  id: string
  kr: string
  ns: string
  phase: string
  status: string
}

function deriveDockKeepers(keeperRows: Keeper[]): DockKeeper[] {
  if (keeperRows.length === 0) {
    // Minimal fallback only when the store has not hydrated yet.
    return [
      { id: 'masc-improver', kr: 'MASC Improver', ns: 'fleet', phase: 'Running', status: 'run' },
    ]
  }
  return keeperRows.map(k => ({
    id: k.keeper_id ?? k.name,
    kr: k.koreanName ?? k.name,
    ns: k.runtime_canonical ?? k.runtime_id ?? 'fleet',
    phase: k.phase ?? k.lifecycle_phase ?? k.status,
    status: statusLooksRunning(k.status) ? 'run' : k.status.toLowerCase(),
  }))
}

const dockOpen = persistentSignal<DockState>({
  key: 'dashboard:copilot-dock',
  defaultValue: { open: false, mode: 'dock', keeperId: 'masc-improver', x: null, y: null },
})
export function useCopilotDock() {
  return {
    state: dockOpen,
    threads: keeperThreads,
    sending: keeperSending,
    open: () => { dockOpen.value = { ...dockOpen.value, open: true } },
    close: () => { dockOpen.value = { ...dockOpen.value, open: false } },
    toggle: () => { dockOpen.value = { ...dockOpen.value, open: !dockOpen.value.open } },
    setMode: (mode: 'dock' | 'float') => { dockOpen.value = { ...dockOpen.value, mode } },
    setKeeper: (keeperId: string) => { dockOpen.value = { ...dockOpen.value, keeperId } },
    patch: (patch: Partial<DockState>) => { dockOpen.value = { ...dockOpen.value, ...patch } },
    send: (text: string, keeper: DockKeeper, ctx: SurfaceContext, options: Partial<ReturnType<typeof composerMessageOptions>> = {}) => {
      if (!text.trim() && !options.userBlocks?.length && !options.attachments?.length) return
      void sendKeeperThreadMessage(keeper.id, text, {
        ...options, channel: 'copilot', resolveChannelWorkspaceId: currentDashboardActor, surfaceContext: ctx,
      }).catch(() => { /* The shared action records delivery and error on its canonical entry. */ })
    },
  }
}

export type CopilotDockApi = ReturnType<typeof useCopilotDock>

/** Toggle the chat dock from outside the shell hook tree (command palette). */
export function toggleCopilotDock(): void {
  dockOpen.value = { ...dockOpen.value, open: !dockOpen.value.open }
}

export function useCopilotDockShortcuts(dock: CopilotDockApi): void {
  useEffect(() => {
    const disposers: Array<() => void> = []
    disposers.push(
      globalShortcutManager.register({
        id: 'copilot-dock.toggle',
        chord: { key: 'j', modifiers: ['Mod'] },
        description: 'Toggle Chat Dock',
        scope: 'global',
        preserveInInputs: false,
        action: () => { dock.toggle() },
      }),
    )
    disposers.push(
      globalShortcutManager.register({
        id: 'copilot-dock.close',
        chord: { key: 'Escape', modifiers: [] },
        description: 'Close Chat Dock',
        scope: 'global',
        preserveInInputs: false,
        action: () => { dock.close() },
      }),
    )
    return () => {
      for (const dispose of disposers) dispose()
    }
  }, [dock])
}

function StatusDot({ status }: { status: string }) {
  const running = status === 'run'
  return html`
    <span
      class="inline-block rounded-full"
      style=${{
        width: '6px',
        height: '6px',
        background: running ? 'var(--status-ok)' : 'var(--status-idle)',
        boxShadow: running ? '0 0 6px var(--status-ok)' : undefined,
      }}
      aria-hidden="true"
    />
  `
}

export function CopilotDock({ dock }: { dock: CopilotDockApi }) {
  // deriveDockKeepers/getSurfaceContext are pure derivations of keepers + route.
  // Reuse context derivations while canonical stream entries update.
  const keeperRows = useMemo(() => deriveDockKeepers(keepers.value), [keepers.value])
  const keeper = keeperRows.find(k => k.id === dock.state.value.keeperId) ?? keeperRows[0] ?? {
    id: 'masc-improver',
    kr: 'MASC Improver',
    ns: 'fleet',
    phase: 'Running',
    status: 'run',
  }
  const contextRoute = route.value
  const ctx = useMemo(() => getSurfaceContext(keeper.id), [route.value, keepers.value, keeper.id])
  const starterPrompts = useMemo(() => starterPromptsForContext(ctx), [ctx.route])
  const rawThread = dock.threads.value[keeper.id] ?? []
  const showInternal = chatShowInternal.value
  const showAutonomous = chatShowAutonomous.value
  const msgs = useMemo(() => rawThread.filter(entry =>
    (showInternal || isDefaultVisibleConversationEntry(entry))
      && (showAutonomous || !isAutonomousTurnEntry(entry))),
  [rawThread, showInternal, showAutonomous])
  const sending = dock.sending.value[keeper.id] === true
  const authRevision = storedTokenRevision.value
  const selectedKeeperId = dock.state.value.keeperId
  const [pickOpen, setPickOpen] = useState(false)
  const threadRef = useRef<HTMLDivElement | null>(null)
  const rootRef = useRef<HTMLElement | null>(null)
  const isMobile = useIsMobile()

  useEffect(() => {
    const el = threadRef.current
    if (el) el.scrollTop = el.scrollHeight
  }, [msgs, keeper.id])

  const ownsInput = () => authRevision === currentStoredTokenRevision()
    && selectedKeeperId === dock.state.value.keeperId
    && contextRoute === route.value
  const doSend = (text: string) => {
    if (!ownsInput()) return
    dock.send(text, keeper, ctx)
  }
  const submit = (payload: ChatComposerSendPayload) => {
    if (!ownsInput()) return
    dock.send(payload.text, keeper, ctx, composerMessageOptions(payload))
  }

  const drag = (e: MouseEvent) => {
    if (dock.state.value.mode === 'dock') return
    const root = rootRef.current
    if (!root) return
    const r = root.getBoundingClientRect()
    const offx = e.clientX - r.left
    const offy = e.clientY - r.top
    const move = (ev: MouseEvent) => {
      dock.patch({
        x: Math.max(8, Math.min(window.innerWidth - r.width - 8, ev.clientX - offx)),
        y: Math.max(8, Math.min(window.innerHeight - r.height - 8, ev.clientY - offy)),
      })
    }
    const up = () => {
      window.removeEventListener('mousemove', move as EventListener)
      window.removeEventListener('mouseup', up as EventListener)
    }
    window.addEventListener('mousemove', move as EventListener)
    window.addEventListener('mouseup', up as EventListener)
  }

  const docked = isMobile || dock.state.value.mode === 'dock'
  const mobileDocked = isMobile && docked
  const floatStyle = !docked
    ? {
      left: dock.state.value.x != null ? `${dock.state.value.x}px` : 'auto',
      top: dock.state.value.y != null ? `${dock.state.value.y}px` : 'auto',
      right: dock.state.value.x != null ? 'auto' : '22px',
      bottom: dock.state.value.y != null ? 'auto' : '22px',
    }
    : undefined

  return html`
    <aside
      ref=${rootRef}
      class=${`v2-shell-surface dock ${docked ? 'docked' : 'float'}`}
      style=${floatStyle}
      data-screen-label="Chat 도크"
      data-testid="copilot-dock"
      data-mobile-docked=${mobileDocked ? 'true' : 'false'}
    >
      <div
        class=${`dock-head ${docked ? '' : 'drag'}`}
        onMouseDown=${docked ? undefined : drag}
      >
        <div class="dock-title"><span class="dock-spark"><${Sparkles} size=${16} aria-hidden="true" /></span>Chat</div>
        <div class="spacer"></div>
        ${mobileDocked ? null : html`
          <button
            type="button"
            class="dock-iconbtn"
            aria-label=${docked ? '플로팅으로 띄우기' : '오른쪽에 도킹'}
            title=${docked ? '플로팅으로 띄우기' : '오른쪽에 도킹'}
            onMouseDown=${(e: MouseEvent) => e.stopPropagation()}
            onClick=${() => dock.setMode(docked ? 'float' : 'dock')}
          >
            ${docked
              ? html`<${PanelRightOpen} size=${15} aria-hidden="true" />`
              : html`<${PanelRightClose} size=${15} aria-hidden="true" />`}
          </button>
        `}
        <button
          type="button"
          class="dock-iconbtn"
          aria-label="닫기"
          title="닫기 (Esc)"
          onMouseDown=${(e: MouseEvent) => e.stopPropagation()}
          onClick=${dock.close}
        >
          <${X} size=${15} aria-hidden="true" />
        </button>
      </div>

      <div class="dock-idrow">
        <div class="dock-picker">
          <button
            type="button"
            class="dock-picker-btn"
            onMouseDown=${(e: MouseEvent) => e.stopPropagation()}
            onClick=${() => setPickOpen(o => !o)}
            data-testid="copilot-dock-picker"
          >
            <${KeeperBadge} id=${keeper.id} name=${keeper.kr} variant="sigil" size="md" beat=${statusLooksRunning(keeper.status)} />
            <span class="nm">${keeper.kr}</span>
            <span class="cv"><${ChevronDown} size=${12} aria-hidden="true" /></span>
          </button>
          ${pickOpen
            ? html`
                <div class="dock-menu" onMouseDown=${(e: MouseEvent) => e.stopPropagation()}>
                  ${keeperRows.map(k => html`
                    <button
                      type="button"
                      key=${k.id}
                      class=${`dock-menu-row ${k.id === keeper.id ? 'on' : ''}`}
                      aria-current=${k.id === keeper.id ? 'true' : undefined}
                      aria-label=${`${k.kr}로 전환`}
                      onClick=${() => { dock.setKeeper(k.id); setPickOpen(false) }}
                    >
                      <${KeeperBadge} id=${k.id} name=${k.kr} variant="sigil" size="lg" beat=${statusLooksRunning(k.status)} />
                      <div class="minfo">
                        <div class="nm">${k.kr} <span class="h">${k.id}</span></div>
                        <div class="sub"><${StatusDot} status=${k.status} />${k.phase}</div>
                      </div>
                    </button>
                  `)}
                </div>
              `
            : null}
        </div>
        <span class="dock-idrow-hint">와 대화 중</span>
      </div>

      <div class="dock-coview" data-testid="copilot-dock-coview">
        <div class="dock-coview-h">
          <span class="lbl">지금 함께 보는 화면 · ${ctx.label}</span>
          <span class="route mono">${ctx.route}</span>
        </div>
        <div class="scene">${ctx.label}</div>
        ${ctx.fields.length > 0
          ? html`
              <div class="dock-coview-fields">
                ${ctx.fields.map((f, i) => html`
                  <span key=${i} class=${`dock-field ${f.tone || ''}`}><span class="k">${f.k}</span><span class="v">${f.v}</span></span>
                `)}
              </div>
            `
          : null}
        <div class="sync"><span class="d"></span>${ctx.scene}</div>
      </div>

      <div class="dock-thread" ref=${threadRef}>
        ${msgs.length === 0 && !sending
          ? html`
              <div class="dock-empty">
                <div class="ico"><${MessageCircle} size=${26} aria-hidden="true" /></div>
                <div class="t">${ctx.label}</div>
                <div class="s">이 화면에 대해 ${keeper.kr}에게 바로 물어보세요. 같은 맥락을 보고 답합니다.</div>
                <div class="dsug" style=${{ width: '100%' }}>
                  ${starterPrompts.map((s, i) => html`
                    <button key=${i} data-dock-starter=${i} onClick=${() => doSend(s)}><span class="pre">›</span>${s}</button>
                  `)}
                </div>
              </div>
            `
          : html`
              <${ChatTranscript} entries=${msgs} keeperName=${keeper.id} emptyText="표시할 대화 없음" variant="messenger" groupToolCalls=${true}
                showMetadata=${chatShowMetadata.value} expandAutonomousRuns=${chatExpandAutonomousRuns.value} />
            `}
      </div>

      <div class="dock-composer">
        <${ChatComposer}
          key=${keeper.id}
          draftPersistKey=${keeper.id}
          keeperLabel=${keeper.kr}
          placeholder=${`${keeper.kr}에게… (이 화면 기준)`}
          disabled=${false}
          streaming=${sending}
          allowSendWhileStreaming=${true}
          isSubmissionCurrent=${ownsInput}
          onSend=${submit}
          footerMode="activity"
        />
        <div class="dock-foot">
          <span>발신 <b>@operator</b></span>
          <span style=${{ marginLeft: 'auto' }}><kbd>↵</kbd> 전송 · <kbd>Esc</kbd> 닫기</span>
        </div>
      </div>
    </aside>
  `
}

export function CopilotDockFab({ dock }: { dock: CopilotDockApi }) {
  return html`
    <button
      type="button"
      class="v2-shell-action dock-fab"
      onClick=${dock.open}
      data-testid="copilot-dock-fab"
      aria-label="Open Chat Dock"
      title="Chat Dock 열기 (⌘J)"
    >
      <span class="spark"><${Sparkles} size=${17} aria-hidden="true" /></span>
      <span class="dock-fab-label">Chat</span>
    </button>
  `
}

export function CopilotDockTopBarButton({ dock }: { dock: CopilotDockApi }) {
  const on = dock.state.value.open
  return html`
    <button
      type="button"
      class=${`v2-shell-action topbar-copilot ${on ? 'on' : ''}`}
      onClick=${dock.toggle}
      data-testid="copilot-dock-topbar-button"
      aria-label="Toggle Chat Dock"
    >
      <${Sparkles} class="spark" size=${14} aria-hidden="true" />
      <span>Chat</span>
      <kbd>⌘J</kbd>
    </button>
  `
}
