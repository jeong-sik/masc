// Keeper Workspace — conversation pane (center). A spacious ChatHeader
// (identity + lifecycle actions) above the reused KeeperConversationPanel
// (layout="workspace"). The header replaces the old narrow detail-page
// header; the panel reuses the full chat engine unchanged.

import { html } from 'htm/preact'
import { ChevronLeft } from 'lucide-preact'
import { useEffect, useState } from 'preact/hooks'
import type { VNode } from 'preact'
import type { Keeper, KeeperConversationEntry } from '../../types'
import { KeeperConversationPanel } from '../keeper-shared'
import { keeperMobilePane } from '../keeper-detail-state'
import { TurnInspectorDrawer as SharedTurnInspectorDrawer } from '../keeper-turn-inspector-drawer'
import { keeperDisplayStatus } from '../../lib/keeper-runtime-display'
import { keeperActionVisibility } from '../../lib/keeper-predicates'
import { runKeeperAction, type KeeperActionKey } from '../keeper-action-panel'
import { Pill, type PillTone } from '../v2/primitives-v2'
import { phaseTone, phasePulse } from '../v2/keeper-fsm'
import {
  WorkspaceSigil,
  keeperBucket,
  keeperPhaseLabel,
} from './keeper-workspace-shared'

type WorkspaceCommandId = KeeperActionKey | 'config'

interface WorkspaceCommand {
  id: WorkspaceCommandId
  label: string
  title: string
  glyph: string
  danger?: boolean
  onClick: () => void | Promise<void>
}

const LIFECYCLE_COPY: Record<
  KeeperActionKey,
  { label: string; title: string; glyph: string; danger?: boolean }
> = {
  pause: {
    label: '일시정지',
    title: '일시정지: 실행 중인 keeper 를 일시 멈춥니다',
    glyph: '⏸',
  },
  resume: {
    label: '재개',
    title: '재개: 일시정지된 keeper 를 다시 실행합니다',
    glyph: '▶',
  },
  wakeup: {
    label: '깨우기',
    title: '깨우기: 다음 turn 을 즉시 시도합니다',
    glyph: '◉',
  },
  boot: {
    label: '기동',
    title: '기동: offline keeper 를 다시 시작합니다',
    glyph: '▶',
  },
  shutdown: {
    label: '종료',
    title: '종료: keeper 를 완전 종료합니다',
    glyph: '■',
    danger: true,
  },
}

function lifecycleCommands(keeper: Keeper): WorkspaceCommand[] {
  const visibility = keeperActionVisibility(keeper)
  const keys: KeeperActionKey[] = []
  if (visibility.canBoot) keys.push('boot')
  if (visibility.canResume) keys.push('resume')
  if (visibility.canWake && !visibility.canBoot) keys.push('wakeup')
  if (visibility.canPause) keys.push('pause')
  if (visibility.canShutdown) keys.push('shutdown')

  return keys.map(key => {
    const copy = LIFECYCLE_COPY[key]
    return {
      id: key,
      label: copy.label,
      title: copy.title,
      glyph: copy.glyph,
      danger: copy.danger,
      onClick: () => runKeeperAction(keeper.name, key),
    }
  })
}

function WorkspaceCommandButtons({
  keeper,
  mobile,
  onOpenConfig,
}: {
  keeper: Keeper
  mobile: boolean
  onOpenConfig?: () => void
}): VNode {
  const [menuOpen, setMenuOpen] = useState(false)
  const [busyAction, setBusyAction] = useState<WorkspaceCommandId | null>(null)
  useEffect(() => {
    setMenuOpen(false)
  }, [keeper.name])
  useEffect(() => {
    if (!menuOpen) return
    const close = () => setMenuOpen(false)
    window.addEventListener('click', close)
    return () => window.removeEventListener('click', close)
  }, [menuOpen])

  const config: WorkspaceCommand = {
    id: 'config',
    label: 'keeper 설정',
    title: 'keeper 설정',
    glyph: '⚙',
    onClick: onOpenConfig ?? (() => {}),
  }
  const lifecycle = lifecycleCommands(keeper)
  const commands: WorkspaceCommand[] = [...lifecycle, config]

  async function run(command: WorkspaceCommand) {
    if (busyAction) return
    setBusyAction(command.id)
    try {
      await command.onClick()
      setMenuOpen(false)
    } finally {
      setBusyAction(null)
    }
  }

  if (mobile) {
    return html`
      <div class="kw-chat-mobile-actions">
        <div class="kw-chat-command-menu">
          <button
            type="button"
            class="kw-chat-command-menu-toggle v2-monitoring-action"
            aria-label="keeper 명령"
            aria-haspopup="menu"
            aria-expanded=${menuOpen ? 'true' : 'false'}
            title="keeper 명령"
            onClick=${(event: Event) => {
              event.stopPropagation()
              setMenuOpen(open => !open)
            }}
            data-testid="kw-chat-command-menu-toggle"
          >
            <span aria-hidden="true">⋯</span>
          </button>
          ${menuOpen
            ? html`
                <div class="kw-chat-command-popover v2-monitoring-surface" role="menu" onClick=${(event: Event) => event.stopPropagation()}>
                  ${commands.map(command => html`
                    <button
                      key=${command.id}
                      type="button"
                      role="menuitem"
                      class=${`kw-chat-command-item${command.danger ? ' danger' : ''}`}
                      disabled=${busyAction !== null}
                      onClick=${() => { void run(command) }}
                      data-testid=${`kw-chat-command-${command.id}`}
                    >
                      <span aria-hidden="true">${command.glyph}</span>
                      <span>${command.label}</span>
                    </button>
                  `)}
                </div>
              `
            : null}
        </div>
      </div>
    `
  }

  return html`
    <div class="chat-actions" data-testid="kw-chat-command-icons">
      ${lifecycle.length === 0
        ? html`<span class="act-quiet" title=${keeperDisplayStatus(keeper)}>전이 중…</span>`
        : lifecycle.map(command => html`
            <button
              key=${command.id}
              type="button"
              class=${`act icon${command.danger ? ' danger' : ''}`}
              aria-label=${command.label}
              title=${command.title}
              disabled=${busyAction !== null}
              onClick=${() => { void run(command) }}
              data-testid=${`kw-chat-command-${command.id}`}
            >
              <span aria-hidden="true">${command.glyph}</span>
            </button>
          `)}
      <button
        type="button"
        class="act icon"
        aria-label="keeper 설정"
        title="keeper 설정"
        disabled=${busyAction !== null}
        onClick=${() => { void run(config) }}
        data-testid="kw-chat-command-config"
      >
        <span aria-hidden="true">⚙</span>
      </button>
    </div>
  `
}

function ChatHeader({
  keeper,
  mobile = false,
  onBack,
  onOpenRail,
  onOpenConfig,
  onOpenDetail,
}: {
  keeper: Keeper
  mobile?: boolean
  onBack?: () => void
  onOpenRail?: () => void
  onOpenConfig?: () => void
  onOpenDetail?: () => void
}): VNode {
  const bucket = keeperBucket(keeper)
  const live = bucket === 'running'
  const tone = phaseTone(keeper.lifecycle_phase)
  const pillTone: PillTone = tone === 'idle' ? 'neutral' : tone === 'busy' ? 'warn' : tone
  const pulse = phasePulse(keeper.lifecycle_phase)
  const phase = keeper.lifecycle_phase ?? keeper.phase ?? keeperPhaseLabel(keeper)
  // Prototype ChatHeader sub-line shows the keeper's sandbox basepath only.
  const basepath = keeper.sandbox_target ?? ''

  // Prototype ChatHeader (shell.jsx): avatar + identity (name + phase pill) +
  // basepath sub + action icons. The back button is mobile-only (desktop keeps
  // the roster visible). Runtime/model/throughput live in the context rail.
  return html`
    <div class=${`chat-head${mobile ? ' is-mobile' : ''}`}>
      ${mobile
        ? html`<button
            type="button"
            class="chat-back"
            title="키퍼 로스터"
            aria-label="키퍼 로스터로 돌아가기"
            onClick=${() => {
              keeperMobilePane.value = 'roster'
              onBack?.()
            }}
            data-testid="kw-chat-back-to-roster"
          ><${ChevronLeft} size=${16} aria-hidden="true" /></button>`
        : null}
      <${WorkspaceSigil} id=${keeper.name} size=${40} beat=${live} />
      <div class="chat-id">
        <div class="name-row">
          <h2>${keeper.name}</h2>
          <${Pill} tone=${pillTone} dot=${pillTone === 'neutral' ? 'idle' : pillTone} dotPulse=${pulse} title=${keeperDisplayStatus(keeper)}>${phase}</${Pill}>
        </div>
        <div class="sub">
          <span class="sub-ns" title="basepath — 이 keeper의 격리된 worktree 루트"><span class="mono">${basepath || '—'}</span></span>
        </div>
      </div>
      <div class="chat-actions">
        <${WorkspaceCommandButtons}
          keeper=${keeper}
          mobile=${mobile}
          onOpenConfig=${onOpenConfig}
        />
        ${onOpenDetail
          ? html`
              <button
                type="button"
                class="act icon"
                aria-label="상세"
                title="운영 상세"
                onClick=${onOpenDetail}
                data-testid="kw-chat-detail"
              >
                <span aria-hidden="true">ℹ</span>
              </button>
            `
          : null}
        ${mobile
          ? html`
              <button
                type="button"
                class="kw-chat-ctx-mobile v2-monitoring-action"
                title="컨텍스트"
                onClick=${onOpenRail}
                data-testid="kw-chat-mobile-context"
              >
                <span aria-hidden="true">ⓘ</span>
                <span>컨텍스트</span>
              </button>
            `
          : null}
      </div>
    </div>
  `
}

function TurnInspectorDrawer({
  keeperName,
  triggerEntry,
  open,
  onClose,
}: {
  keeperName: string
  triggerEntry?: KeeperConversationEntry | null
  open: boolean
  onClose: () => void
}) {
  // Thin chat-specific wrapper over the shared TurnInspectorDrawer: maps the
  // chat entry to the drawer's anchor props (turnRef + timestamp window) and
  // header label. The shared component owns the overlay markup so the board
  // surface (post-detail) reuses the identical drawer. testId is preserved so
  // existing chat tests keep their `kw-chat-turn-inspector-*` selectors.
  return html`
    <${SharedTurnInspectorDrawer}
      testId="kw-chat-turn-inspector"
      keeperName=${keeperName}
      subtitle=${triggerEntry
        ? `메시지 ${triggerEntry.label} · ${triggerEntry.timestamp ?? triggerEntry.id}`
        : null}
      initialTurnRef=${triggerEntry?.turnRef ?? null}
      initialTurnTimestamp=${triggerEntry?.timestamp ?? null}
      open=${open}
      onClose=${onClose}
    />
  `
}

export function KeeperWorkspaceChat({
  keeper,
  mobile = false,
  onBack,
  onOpenRail,
  onOpenConfig,
  onOpenDetail,
}: {
  keeper: Keeper
  mobile?: boolean
  onBack?: () => void
  onOpenRail?: () => void
  onOpenConfig?: () => void
  onOpenDetail?: () => void
}): VNode {
  const [turnInspectorOpen, setTurnInspectorOpen] = useState(false)
  const [turnInspectorEntry, setTurnInspectorEntry] = useState<KeeperConversationEntry | null>(null)
  const openTurnInspector = (entry?: KeeperConversationEntry) => {
    setTurnInspectorEntry(entry ?? null)
    setTurnInspectorOpen(true)
  }

  return html`
    <section class="kw-chat v2-monitoring-surface" role="region" aria-label=${`${keeper.name} 대화`}>
      <${ChatHeader}
        keeper=${keeper}
        mobile=${mobile}
        onBack=${onBack}
        onOpenRail=${onOpenRail}
        onOpenConfig=${onOpenConfig}
        onOpenDetail=${onOpenDetail}
      />
      <div class="kw-chat-body">
        <${KeeperConversationPanel}
          keeperName=${keeper.name}
          placeholder=${`${keeper.name} 에게 메시지…  (⌘+Enter 전송)`}
          layout="workspace"
          onInspectTurn=${openTurnInspector}
        />
      </div>
      <${TurnInspectorDrawer}
        keeperName=${keeper.name}
        triggerEntry=${turnInspectorEntry}
        open=${turnInspectorOpen}
        onClose=${() => {
          setTurnInspectorOpen(false)
          setTurnInspectorEntry(null)
        }}
      />
    </section>
  `
}
