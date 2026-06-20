import { html } from 'htm/preact'
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { signal } from '@preact/signals'
import { ChevronDown, MessageCircle, PanelRightClose, PanelRightOpen, Send, Sparkles, X } from 'lucide-preact'
import { persistentSignal } from '../lib/persistent-signal'
import { globalShortcutManager } from '../lib/global-shortcut-manager'
import { route } from '../router'
import { keepers } from '../store'
import { DASHBOARD_NAV_ITEMS } from '../config/navigation'
import { isSubmitEnter } from '../lib/keyboard'
import { streamKeeperMessage } from '../api/keeper'
import { currentDashboardActor } from '../api/core'
import type { Keeper } from '../types'

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
  fields: Array<{ k: string; v: string; tone?: 'err' | 'warn' | 'brass' }>
}

interface DockMessage {
  role: 'user' | 'assistant'
  ts: string
  text: string
  sug?: string[]
}

interface DockStreaming {
  keeperId: string
  shown: string
  full: string
  sug: string[]
}

const DOCK_STARTERS: string[] = [
  '이 화면 요약해줘',
  '다음 액션 추천',
  '주의 항목 정리해줘',
]

function nowHM(): string {
  const d = new Date()
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`
}

function statusLooksRunning(status?: string | null): boolean {
  const s = (status ?? '').toLowerCase()
  return s === 'running' || s === 'run' || s === 'online' || s === 'healthy'
}

function keeperColor(name: string): string {
  const map: Record<string, string> = {
    nick0cave: 'var(--k-nick)',
    'masc-improver': 'var(--k-masc)',
    sangsu: 'var(--k-sangsu)',
    'qa-king': 'var(--k-qa)',
    rama: 'var(--k-rama)',
  }
  return map[name] ?? 'var(--brass-1)'
}

function keeperGlow(name: string): string {
  const map: Record<string, string> = {
    nick0cave: 'var(--k-nick-glow)',
    'masc-improver': 'var(--k-masc-glow)',
    sangsu: 'var(--k-sangsu-glow)',
    'qa-king': 'var(--k-qa-glow)',
    rama: 'var(--k-rama-glow)',
  }
  return map[name] ?? 'var(--brass-glow)'
}

function mdInline(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
}

function Para({ text }: { text: string }) {
  return text.split('\n\n').map((p, i) => html`<p key=${i} dangerouslySetInnerHTML=${{ __html: mdInline(p) }} />`)
}

export function getSurfaceContext(): SurfaceContext {
  const tab = route.value.tab
  const section = route.value.params.section ?? ''
  const navItem = DASHBOARD_NAV_ITEMS.find(item => item.id === tab)
  const sceneMap: Record<string, string> = {
    overview: '함대 전체 상태를 함께 보는 중',
    monitoring: 'keeper와 1:1 스레드',
    workspace: '네임스페이스 보드를 함께 보는 중',
    code: '코드 모드에서 함께 보는 중',
    connectors: '외부 게이트 상태를 함께 보는 중',
    command: '운영 액션 패널을 함께 보는 중',
    lab: '실험 도구 패널을 함께 보는 중',
    logs: '시스템 로그 스트림을 함께 보는 중',
  }
  const base: SurfaceContext = {
    label: navItem?.label ?? tab,
    route: `/${tab}${section ? `/${section}` : ''}`,
    scene: sceneMap[tab] ?? `${tab} 화면을 함께 보는 중`,
    fields: [],
  }

  const live = keepers.value.filter(k => statusLooksRunning(k.status))
  const run = live.length
  const total = keepers.value.length
  const att = keepers.value.filter(k => k.needs_attention).length
  const traces = keepers.value.reduce((a, k) => a + (typeof k.total_turns === 'number' ? k.total_turns : 0), 0)

  switch (tab) {
    case 'overview':
      base.fields = [
        { k: '실행', v: `${run}/${total}` },
        { k: '주의', v: String(att), tone: att > 0 ? 'err' : undefined },
        { k: 'ctx', v: `${total > 0 ? Math.round((live.reduce((a, k) => a + (typeof k.context_ratio === 'number' ? k.context_ratio : 0), 0) / total) * 100) : 0}%`, tone: 'brass' },
        { k: 'trace', v: traces.toLocaleString() },
      ]
      break
    case 'monitoring': {
      const keeperName = route.value.params.keeper
      const sel = keeperName ? keepers.value.find(k => k.name === keeperName || k.keeper_id === keeperName) : null
      if (sel) {
        const ctx = typeof sel.context_ratio === 'number' ? sel.context_ratio : 0
        base.scene = `${sel.koreanName ?? sel.name}와 1:1 스레드`
        base.fields = [
          { k: 'state', v: sel.phase ?? sel.status },
          { k: 'ctx', v: `${Math.round(ctx * 100)}%`, tone: ctx >= 0.85 ? 'warn' : 'brass' },
          { k: 'ns', v: sel.runtime_canonical ?? sel.runtime_id ?? '-' },
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
const dockThreads = signal<Record<string, DockMessage[]>>({})
const dockStreaming = signal<DockStreaming | null>(null)

export function useCopilotDock() {
  return {
    state: dockOpen,
    threads: dockThreads,
    streaming: dockStreaming,
    open: () => { dockOpen.value = { ...dockOpen.value, open: true } },
    close: () => { dockOpen.value = { ...dockOpen.value, open: false } },
    toggle: () => { dockOpen.value = { ...dockOpen.value, open: !dockOpen.value.open } },
    setMode: (mode: 'dock' | 'float') => { dockOpen.value = { ...dockOpen.value, mode } },
    setKeeper: (keeperId: string) => { dockOpen.value = { ...dockOpen.value, keeperId } },
    patch: (patch: Partial<DockState>) => { dockOpen.value = { ...dockOpen.value, ...patch } },
    send: (text: string, keeper: DockKeeper, ctx: SurfaceContext) => {
      if (!text.trim() || dockStreaming.value) return
      const kid = keeper.id
      dockThreads.value = {
        ...dockThreads.value,
        [kid]: [...(dockThreads.value[kid] ?? []), { role: 'user', ts: nowHM(), text: text.trim() }],
      }
      const abortController = new AbortController()
      dockStreaming.value = { keeperId: kid, shown: '', full: '', sug: [] }
      let replyText = ''
      streamKeeperMessage(kid, text.trim(), {
        signal: abortController.signal,
        channel: 'copilot',
        channelWorkspaceId: currentDashboardActor(),
        surfaceContext: ctx,
        onEvent: (event) => {
          if (event.type === 'TEXT_MESSAGE_CONTENT' && typeof event.delta === 'string') {
            replyText += event.delta
            const current = dockStreaming.value
            if (current && current.keeperId === kid) {
              dockStreaming.value = { ...current, shown: replyText }
            }
          }
        },
      })
        .then((outcome) => {
          dockStreaming.value = null
          const finalText = replyText.trim() || (outcome.terminal ? '(empty reply)' : '(stream ended unexpectedly)')
          dockThreads.value = {
            ...dockThreads.value,
            [kid]: [...(dockThreads.value[kid] ?? []), { role: 'assistant', ts: nowHM(), text: finalText }],
          }
        })
        .catch((err) => {
          dockStreaming.value = null
          const message = err instanceof Error ? err.message : 'Keeper stream failed'
          dockThreads.value = {
            ...dockThreads.value,
            [kid]: [...(dockThreads.value[kid] ?? []), { role: 'assistant', ts: nowHM(), text: `Error: ${message}` }],
          }
        })
    },
  }
}

export type CopilotDockApi = ReturnType<typeof useCopilotDock>

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

function DockAvatar({ keeper, size = 26, beat = false }: { keeper: DockKeeper; size?: number; beat?: boolean }) {
  const color = keeperColor(keeper.id)
  const glow = keeperGlow(keeper.id)
  const initials = keeper.kr.slice(0, 2).toUpperCase()
  return html`
    <div
      class="dmsg-av k"
      style=${{
        width: `${size}px`,
        height: `${size}px`,
        background: color,
        boxShadow: beat ? `0 0 6px rgb(${glow} / .6)` : undefined,
      }}
      title=${keeper.kr}
    >
      ${initials}
    </div>
  `
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

function DockMessageRow({ m, keeper, onPick }: { m: DockMessage; keeper: DockKeeper; onPick: (s: string) => void }) {
  const isUser = m.role === 'user'
  return html`
    <div class=${`dmsg ${isUser ? 'user' : ''}`} data-dock-message=${m.role}>
      ${isUser
        ? html`<div class="dmsg-av op">YOU<//>`
        : html`<${DockAvatar} keeper=${keeper} size=${26} beat=${statusLooksRunning(keeper.status)} />`}
      <div class="dmsg-col">
        <div class="dmsg-hd">
          <span class="who">${isUser ? 'operator' : keeper.kr}</span>
          <span class="ts mono">${m.ts}</span>
        </div>
        <div class=${`dbubble ${isUser ? 'user' : ''}`}><${Para} text=${m.text} /></div>
        ${!isUser && m.sug
          ? html`
              <div class="dsug">
                ${m.sug.map((s, i) => html`
                  <button key=${i} onClick=${() => onPick(s)}><span class="pre">›</span>${s}</button>
                `)}
              </div>
            `
          : null}
      </div>
    </div>
  `
}

export function CopilotDock({ dock }: { dock: CopilotDockApi }) {
  // deriveDockKeepers/getSurfaceContext are pure derivations of keepers + route.
  // Memoized so the 40ms streaming-animation re-renders (dockStreaming.value)
  // skip the O(N) keeper map/merge and the surface-context rebuild.
  const keeperRows = useMemo(() => deriveDockKeepers(keepers.value), [keepers.value])
  const keeper = keeperRows.find(k => k.id === dock.state.value.keeperId) ?? keeperRows[0] ?? {
    id: 'masc-improver',
    kr: 'MASC Improver',
    ns: 'fleet',
    phase: 'Running',
    status: 'run',
  }
  const ctx = useMemo(() => getSurfaceContext(), [route.value, keepers.value])
  const msgs = dock.threads.value[keeper.id] ?? []
  const streaming = dock.streaming.value && dock.streaming.value.keeperId === keeper.id ? dock.streaming.value : null
  const [val, setVal] = useState('')
  const [focus, setFocus] = useState(false)
  const [pickOpen, setPickOpen] = useState(false)
  const taRef = useRef<HTMLTextAreaElement | null>(null)
  const threadRef = useRef<HTMLDivElement | null>(null)
  const rootRef = useRef<HTMLElement | null>(null)

  useEffect(() => {
    const el = threadRef.current
    if (el) el.scrollTop = el.scrollHeight
  }, [msgs.length, streaming?.shown, keeper.id])

  const doSend = (text?: string) => {
    const v = (text !== undefined ? text : val).trim()
    if (!v) return
    dock.send(v, keeper, ctx)
    setVal('')
    if (taRef.current) taRef.current.style.height = 'auto'
  }

  const onKey = (e: KeyboardEvent) => {
    if (isSubmitEnter(e) && !e.shiftKey) {
      e.preventDefault()
      doSend()
    }
  }

  const grow = (e: Event) => {
    const target = e.target as HTMLTextAreaElement
    setVal(target.value)
    target.style.height = 'auto'
    target.style.height = `${Math.min(target.scrollHeight, 120)}px`
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

  const docked = dock.state.value.mode === 'dock'
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
    >
      <div
        class=${`dock-head ${docked ? '' : 'drag'}`}
        onMouseDown=${docked ? undefined : drag}
      >
        <div class="dock-title"><span class="dock-spark"><${Sparkles} size=${16} aria-hidden="true" /></span>Chat</div>
        <div class="spacer"></div>
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
            <${DockAvatar} keeper=${keeper} size=${20} beat=${statusLooksRunning(keeper.status)} />
            <span class="nm">${keeper.kr}</span>
            <span class="cv"><${ChevronDown} size=${12} aria-hidden="true" /></span>
          </button>
          ${pickOpen
            ? html`
                <div class="dock-menu" onMouseDown=${(e: MouseEvent) => e.stopPropagation()}>
                  ${keeperRows.map(k => html`
                    <div
                      key=${k.id}
                      class=${`dock-menu-row ${k.id === keeper.id ? 'on' : ''}`}
                      onClick=${() => { dock.setKeeper(k.id); setPickOpen(false) }}
                    >
                      <${DockAvatar} keeper=${k} size=${26} beat=${statusLooksRunning(k.status)} />
                      <div class="minfo">
                        <div class="nm">${k.kr} <span class="h">${k.id}</span></div>
                        <div class="sub"><${StatusDot} status=${k.status} />${k.phase} · ${k.ns}</div>
                      </div>
                    </div>
                  `)}
                </div>
              `
            : null}
        </div>
        <span class="dock-idrow-hint">와 대화 중 · <span class="mono">${keeper.ns}</span></span>
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
        ${msgs.length === 0 && !streaming
          ? html`
              <div class="dock-empty">
                <div class="ico"><${MessageCircle} size=${26} aria-hidden="true" /></div>
                <div class="t">${ctx.label}</div>
                <div class="s">이 화면에 대해 ${keeper.kr}에게 바로 물어보세요. 같은 맥락을 보고 답합니다.</div>
                <div class="dsug" style=${{ width: '100%' }}>
                  ${DOCK_STARTERS.map((s, i) => html`
                    <button key=${i} onClick=${() => doSend(s)}><span class="pre">›</span>${s}</button>
                  `)}
                </div>
              </div>
            `
          : html`
              ${msgs.map((m, i) => html`<${DockMessageRow} key=${i} m=${m} keeper=${keeper} onPick=${doSend} />`)}
              ${streaming
                ? html`
                    <div class="dmsg" data-dock-message="assistant">
                      <${DockAvatar} keeper=${keeper} size=${26} beat=${true} />
                      <div class="dmsg-col">
                        <div class="dmsg-hd"><span class="who">${keeper.kr}</span><span class="ts mono">작성 중…</span></div>
                        <div class="dbubble"><${Para} text=${streaming.shown} /><span class="dcaret"></span></div>
                      </div>
                    </div>
                  `
                : null}
            `}
      </div>

      <div class="dock-composer">
        <div class=${`dock-comp-box ${focus ? 'focus' : ''}`}>
          <textarea
            ref=${taRef}
            rows=${1}
            value=${val}
            placeholder=${`${keeper.kr}에게… (이 화면 기준)`}
            onInput=${grow}
            onKeyDown=${onKey}
            onFocus=${() => setFocus(true)}
            onBlur=${() => setFocus(false)}
            onMouseDown=${(e: MouseEvent) => e.stopPropagation()}
            data-testid="copilot-dock-textarea"
          />
          <button
            type="button"
            class="dock-send"
            aria-label="메시지 전송"
            disabled=${!val.trim() || !!dock.streaming.value}
            onClick=${() => doSend()}
          >
            <${Send} size=${14} aria-hidden="true" />
          </button>
        </div>
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
      <span class="spark"><${MessageCircle} size=${22} strokeWidth=${2.4} aria-hidden="true" /></span>
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
      <${MessageCircle} class="spark" size=${14} strokeWidth=${2.2} aria-hidden="true" />
      <span>Chat</span>
      <kbd>⌘J</kbd>
    </button>
  `
}
