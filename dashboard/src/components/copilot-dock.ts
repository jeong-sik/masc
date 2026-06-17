import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import { signal } from '@preact/signals'
import { persistentSignal } from '../lib/persistent-signal'
import { globalShortcutManager } from '../lib/global-shortcut-manager'
import { route } from '../router'
import { keepers } from '../store'
import { isSubmitEnter } from '../lib/keyboard'
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
  fields: Array<{ k: string; v: string; tone?: 'bad' | 'warn' | 'volt' }>
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

const SPARK_SVG = html`
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">
    <path d="M12 3l1.7 4.8L18.5 9.5l-4.8 1.7L12 16l-1.7-4.8L5.5 9.5l4.8-1.7z" />
    <path d="M18.5 14l.9 2.4 2.4.9-2.4.9-.9 2.4-.9-2.4-2.4-.9 2.4-.9z" />
  </svg>
`

const DOCK_STARTERS: Record<string, string[]> = {
  overview: ['주의 큐 4건 정리해줘', '평균 컨텍스트가 왜 높아?', '지금 가장 급한 건 뭐야?'],
  monitoring: ['이 keeper 지금 뭐 하고 있어?', '소유 태스크 요약', '컨텍스트 압박 풀어줘'],
  workspace: ['멘션 인박스 정리해줘', 'drifter 상태 블록 뭐야?'],
  code: ['이 lock 재진입 설명해줘', 'PR #7741 요약', '회귀 위험 어디야?'],
  connectors: ['stale 게이트 왜 그래?', '바인딩 현황 요약해줘'],
  command: ['다음 승인 대기 항목 뭐야?', 'governance 큐 요약'],
  lab: ['도구 등록 상태 요약', 'harness 결과 요약'],
}

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
  return map[name] ?? 'var(--volt-strong)'
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

function buildReply(keeper: DockKeeper, ctx: SurfaceContext): { body: string; sug: string[] } {
  if (ctx.route === '/overview') {
    return {
      body: `지금 **${ctx.label}**를 같이 보고 있네요. 실행 중 keeper와 주의 큐를 훑었어요.\n\n가장 급한 건 \`drifter\` — 컨텍스트가 **오버플로우**라 재시작이 필요합니다. \`nick0cave\`도 91%라 곧 compact가 걸릴 거예요.\n\n제가 ${keeper.kr}로서 주의 4건을 우선순위대로 정리핼까요?`,
      sug: ['drifter 재시작 절차 보기', '주의 4건 한 번에 트리아지', 'nick0cave compact 미리 돌리기'],
    }
  }
  if (ctx.route === '/code') {
    return {
      body: `\`round.ml\`의 lock 재진입 경로를 같이 보고 있어요. \`compact()\`가 라운드 락을 잡은 채 호출되는 **L93**이 의심됩니다.\n\nPR **#7741**은 테스트 84/84 통과지만 아직 리뷰 대기예요.`,
      sug: ['L93 FIXME 같이 보기', 'PR #7741 리뷰 코멘트 요약', 'sangsu에게 핸드오프'],
    }
  }
  if (ctx.route === '/workspace') {
    return {
      body: `**전체 피드**를 같이 보고 있어요. \`@operator\` 멘션 3건 중 \`drifter\`의 restart 승인 대기가 가장 급합니다.`,
      sug: ['멘션 인박스 정리', 'drifter 상태 블록 열기', 'scheduler 공지 스레드로'],
    }
  }
  if (ctx.route === '/connectors') {
    return {
      body: `**Gate** 상태를 같이 보고 있어요. iMessage 게이트가 **stale** — heartbeat 120s 초과로 응답이 지연되고 있어요.`,
      sug: ['stale 게이트 재연결', '바인딩 현황 요약', '최근 감사 로그 보기'],
    }
  }
  return {
    body: `\`${ctx.label}\` 화면을 같이 보고 있어요. \`${keeper.ns}\` 기준으로 관련 trace와 태스크를 모아둘게요. 무엇부터 볼까요?`,
    sug: ['이 화면 요약', '관련 태스크 보기', '다음 액션 추천'],
  }
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
  const labelMap: Record<string, string> = {
    overview: '운영 개요',
    monitoring: 'Keeper 대화',
    workspace: '보드 · 전체 피드',
    code: 'IDE · round.ml',
    connectors: '커넥터 · Gate',
    command: 'Command · Actions',
    lab: 'Lab · Tools',
    logs: 'Logs',
  }
  const sceneMap: Record<string, string> = {
    overview: '함대 전체 상태를 함께 보는 중',
    monitoring: ' keeper와 1:1 스레드',
    workspace: '네임스페이스 보드를 함께 보는 중',
    code: 'fix/round-lock-reentry 브랜치를 함께 보는 중',
    connectors: '외부 게이트 상태를 함께 보는 중',
    command: '운영 액션 패널을 함께 보는 중',
    lab: '실험 도구 패널을 함께 보는 중',
    logs: '시스템 로그 스트림을 함께 보는 중',
  }
  const base: SurfaceContext = {
    label: labelMap[tab] ?? tab,
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
        { k: '주의', v: String(att), tone: att > 0 ? 'bad' : undefined },
        { k: 'ctx', v: `${total > 0 ? Math.round((live.reduce((a, k) => a + (typeof k.context_ratio === 'number' ? k.context_ratio : 0), 0) / total) * 100) : 0}%`, tone: 'volt' },
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
          { k: 'ctx', v: `${Math.round(ctx * 100)}%`, tone: ctx >= 0.85 ? 'warn' : 'volt' },
          { k: 'ns', v: sel.runtime_canonical ?? sel.runtime_id ?? '-' },
        ]
      }
      break
    }
    case 'workspace':
      base.fields = [
        { k: '포스트', v: '5' },
        { k: '멘션', v: '3', tone: 'volt' },
        { k: '모더', v: '1', tone: 'warn' },
      ]
      break
    case 'code':
      base.fields = [
        { k: 'PR', v: '#7741', tone: 'volt' },
        { k: 'test', v: '84/84' },
        { k: 'risk', v: '1', tone: 'bad' },
      ]
      break
    case 'connectors':
      base.fields = [
        { k: 'gate', v: '4' },
        { k: 'active', v: '3', tone: 'volt' },
        { k: 'stale', v: '1', tone: 'warn' },
      ]
      break
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
  const defaults: DockKeeper[] = [
    { id: 'masc-improver', kr: 'MASC Improver', ns: 'fleet', phase: 'Running', status: 'run' },
    { id: 'nick0cave', kr: 'nick0cave', ns: 'ops', phase: 'Running', status: 'run' },
    { id: 'sangsu', kr: 'sangsu', ns: 'code', phase: 'Running', status: 'run' },
    { id: 'qa-king', kr: 'qa-king', ns: 'qa', phase: 'Idle', status: 'idle' },
    { id: 'rama', kr: 'rama', ns: 'memory', phase: 'Running', status: 'run' },
  ]
  if (keeperRows.length === 0) return defaults
  const mapped = keeperRows.map(k => ({
    id: k.keeper_id ?? k.name,
    kr: k.koreanName ?? k.name,
    ns: k.runtime_canonical ?? k.runtime_id ?? 'fleet',
    phase: k.phase ?? k.lifecycle_phase ?? k.status,
    status: statusLooksRunning(k.status) ? 'run' : k.status.toLowerCase(),
  }))
  // Merge defaults for any missing canonical keepers so the picker is never empty.
  const seen = new Set(mapped.map(k => k.id))
  return [...mapped, ...defaults.filter(d => !seen.has(d.id))]
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
      const { body, sug } = buildReply(keeper, ctx)
      window.setTimeout(() => {
        dockStreaming.value = { keeperId: kid, shown: '', full: body, sug }
        const start = typeof performance !== 'undefined' ? performance.now() : Date.now()
        const DUR = 900
        const timer = window.setInterval(() => {
          const now = typeof performance !== 'undefined' ? performance.now() : Date.now()
          const p = Math.min(1, (now - start) / DUR)
          if (p >= 1) {
            window.clearInterval(timer)
            dockStreaming.value = null
            dockThreads.value = {
              ...dockThreads.value,
              [kid]: [...(dockThreads.value[kid] ?? []), { role: 'assistant', ts: nowHM(), text: body, sug }],
            }
          } else {
            const n = Math.max(1, Math.floor(body.length * p))
            const current = dockStreaming.value
            if (current && current.keeperId === kid) {
              dockStreaming.value = { ...current, shown: body.slice(0, n) }
            }
          }
        }, 40)
      }, 220)
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
        description: 'Toggle Copilot Dock',
        scope: 'global',
        preserveInInputs: false,
        action: () => { dock.toggle() },
      }),
    )
    disposers.push(
      globalShortcutManager.register({
        id: 'copilot-dock.close',
        chord: { key: 'Escape', modifiers: [] },
        description: 'Close Copilot Dock',
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
  const keeperRows = deriveDockKeepers(keepers.value)
  const keeper = keeperRows.find(k => k.id === dock.state.value.keeperId) ?? keeperRows[0] ?? {
    id: 'masc-improver',
    kr: 'MASC Improver',
    ns: 'fleet',
    phase: 'Running',
    status: 'run',
  }
  const ctx = getSurfaceContext()
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
      class=${`dock ${docked ? 'docked' : 'float'}`}
      style=${floatStyle}
      data-screen-label="Copilot 도크"
      data-testid="copilot-dock"
    >
      <div
        class=${`dock-head ${docked ? '' : 'drag'}`}
        onMouseDown=${docked ? undefined : drag}
      >
        <div class="dock-title"><span class="dock-spark">${SPARK_SVG}</span>Copilot</div>
        <div class="spacer"></div>
        <button
          type="button"
          class="dock-iconbtn"
          title=${docked ? '플로팅으로 띄우기' : '오른쪽에 도킹'}
          onMouseDown=${(e: MouseEvent) => e.stopPropagation()}
          onClick=${() => dock.setMode(docked ? 'float' : 'dock')}
        >
          ${docked ? '⧉' : '▭'}
        </button>
        <button
          type="button"
          class="dock-iconbtn"
          title="닫기 (Esc)"
          onMouseDown=${(e: MouseEvent) => e.stopPropagation()}
          onClick=${dock.close}
        >
          ✕
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
            <span class="cv">▾</span>
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
                <div class="ico">◈</div>
                <div class="t">${ctx.label}</div>
                <div class="s">이 화면에 대해 ${keeper.kr}에게 바로 물어보세요. 같은 맥락을 보고 답합니다.</div>
                <div class="dsug" style=${{ width: '100%' }}>
                  ${(DOCK_STARTERS[route.value.tab] ?? ['이 화면 요약해줘', '다음 액션 추천']).map((s, i) => html`
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
            disabled=${!val.trim() || !!dock.streaming.value}
            onClick=${() => doSend()}
          >
            ↑
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
      class="dock-fab"
      onClick=${dock.open}
      data-testid="copilot-dock-fab"
      aria-label="Open Copilot Dock"
    >
      <span class="spark">${SPARK_SVG}</span>
      <span>Copilot</span>
      <kbd>⌘J</kbd>
    </button>
  `
}

export function CopilotDockTopBarButton({ dock }: { dock: CopilotDockApi }) {
  const on = dock.state.value.open
  return html`
    <button
      type="button"
      class=${`topbar-copilot ${on ? 'on' : ''}`}
      onClick=${dock.toggle}
      data-testid="copilot-dock-topbar-button"
      aria-label="Toggle Copilot Dock"
    >
      <span class="spark">${SPARK_SVG}</span>
      <span>Copilot</span>
      <kbd>⌘J</kbd>
    </button>
  `
}
