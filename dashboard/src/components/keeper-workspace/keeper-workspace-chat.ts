// Keeper Workspace — conversation pane (center). A spacious ChatHeader
// (identity + lifecycle actions) above the reused KeeperConversationPanel
// (layout="workspace"). The header replaces the old narrow detail-page
// header; the panel reuses the full chat engine unchanged.

import { html } from 'htm/preact'
import { lazy, Suspense } from 'preact/compat'
import {
  Archive,
  ChevronLeft,
  Info,
  MoreHorizontal,
  Play,
  Search,
  Settings,
} from 'lucide-preact'
import { useEffect, useState } from 'preact/hooks'
import type { VNode } from 'preact'
import type { Keeper, KeeperConversationEntry } from '../../types'
import { KeeperConversationPanel } from '../keeper-shared'
import { navigate } from '../../router'
import type { ChatComposerCommand } from '../chat/primitives'
import { keeperMobilePane } from '../keeper-detail-state'
import { keeperThreads } from '../../keeper-state'
import { keeperDisplayStatus } from '../../lib/keeper-runtime-display'
import { keeperActionVisibility } from '../../lib/keeper-predicates'
import { KEEPER_ACTION_LABELS, runKeeperAction, type KeeperActionKey } from '../keeper-action-panel'
import { Pill } from '../v2/primitives-v2'
import {
  WorkspaceSigil,
  StatusDot,
  keeperStatusTone,
  keeperPhaseLabel,
  statePillTone,
} from './keeper-workspace-shared'
import { phasePulse } from '../v2/keeper-fsm'

const LazySharedTurnInspectorDrawer = lazy(async () => ({
  default: (await import('../keeper-turn-inspector-drawer')).TurnInspectorDrawer,
}))

const LazyChatArtifactPanel = lazy(async () => ({
  default: (await import('../chat/artifact-panel')).ChatArtifactPanel,
}))

type WorkspaceUtilityAction = 'turn' | 'artifacts' | 'detail' | 'config'
type WorkspaceCommandId = KeeperActionKey | WorkspaceUtilityAction
type IconComponent = typeof Play

interface WorkspaceCommand {
  id: WorkspaceCommandId
  label: string
  title: string
  icon: IconComponent
  danger?: boolean
  active?: boolean
  onClick: () => void | Promise<void>
}

const COMMAND_GLYPHS: Partial<Record<WorkspaceCommandId, string>> = {
  pause: 'Ⅱ',
  resume: '▶',
  wakeup: '↻',
  boot: '⏻',
  shutdown: '■',
  turn: '⌕',
  artifacts: '▣',
  detail: 'ⓘ',
  config: '⚙',
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
    const copy = KEEPER_ACTION_LABELS[key]
    return {
      id: key,
      label: copy.label,
      title: copy.title,
      icon: copy.icon,
      danger: copy.danger,
      onClick: () => runKeeperAction(keeper.name, key),
    }
  })
}

function workspaceUtilityCommands({
  detailOpen,
  artifactsOpen,
  onOpenTurnInspector,
  onToggleArtifacts,
  onToggleDetail,
  onOpenConfig,
}: {
  detailOpen: boolean
  artifactsOpen: boolean
  onOpenTurnInspector: () => void
  onToggleArtifacts: () => void
  onToggleDetail: () => void
  onOpenConfig?: () => void
}): WorkspaceCommand[] {
  return [
    {
      id: 'turn',
      label: '턴 검사',
      title: '턴 검사',
      icon: Search,
      onClick: onOpenTurnInspector,
    },
    {
      id: 'artifacts',
      label: artifactsOpen ? '아티팩트 숨김' : '아티팩트',
      title: '대화 아티팩트',
      icon: Archive,
      active: artifactsOpen,
      onClick: onToggleArtifacts,
    },
    {
      id: 'detail',
      label: detailOpen ? '대화로' : '상세',
      title: '상세 (상태 · 진단 · 정체성 · 설정 · 디버그)',
      icon: Info,
      active: detailOpen,
      onClick: onToggleDetail,
    },
    {
      id: 'config',
      label: 'keeper 설정',
      title: 'keeper 설정',
      icon: Settings,
      onClick: onOpenConfig ?? onToggleDetail,
    },
  ]
}

function workspaceCommandGroup(command: WorkspaceCommand): string {
  return command.id in KEEPER_ACTION_LABELS ? '명령' : '이동'
}

function isLifecycleWorkspaceCommand(command: WorkspaceCommand): boolean {
  return command.id in KEEPER_ACTION_LABELS
}

function WorkspaceCommandButtons({
  keeper,
  mobile,
  detailOpen,
  artifactsOpen,
  onOpenTurnInspector,
  onToggleArtifacts,
  onToggleDetail,
  onOpenConfig,
}: {
  keeper: Keeper
  mobile: boolean
  detailOpen: boolean
  artifactsOpen: boolean
  onOpenTurnInspector: () => void
  onToggleArtifacts: () => void
  onToggleDetail: () => void
  onOpenConfig?: () => void
}): VNode {
  const [menuOpen, setMenuOpen] = useState(false)
  const [busyAction, setBusyAction] = useState<WorkspaceCommandId | null>(null)
  useEffect(() => {
    if (!menuOpen) return
    const close = () => setMenuOpen(false)
    window.addEventListener('click', close)
    return () => window.removeEventListener('click', close)
  }, [menuOpen])

  const utilities = workspaceUtilityCommands({
    detailOpen,
    artifactsOpen,
    onOpenTurnInspector,
    onToggleArtifacts,
    onToggleDetail,
    onOpenConfig,
  })
  const commands = [...lifecycleCommands(keeper), ...utilities]

  async function run(command: WorkspaceCommand) {
    if (!isLifecycleWorkspaceCommand(command)) {
      await command.onClick()
      setMenuOpen(false)
      return
    }
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
            <${MoreHorizontal} size=${17} aria-hidden="true" />
          </button>
          ${menuOpen
            ? html`
                <div class="kw-chat-command-popover v2-monitoring-surface" role="menu" onClick=${(event: Event) => event.stopPropagation()}>
                  ${commands.map(command => {
                    const Icon = command.icon
                    return html`
                      <button
                        key=${command.id}
                        type="button"
                        role="menuitem"
                        class=${`kw-chat-command-item${command.danger ? ' danger' : ''}`}
                        disabled=${isLifecycleWorkspaceCommand(command) && busyAction !== null}
                        onClick=${() => { void run(command) }}
                        data-testid=${`kw-chat-command-${command.id}`}
                      >
                        <${Icon} size=${14} aria-hidden="true" />
                        <span>${command.label}</span>
                      </button>
                    `
                  })}
                </div>
              `
            : null}
        </div>
      </div>
    `
  }

  const renderIcon = (command: WorkspaceCommand): VNode => {
    const Icon = command.icon
    return html`
      <button
        key=${command.id}
        type="button"
        class=${`kw-chat-command-icon${command.danger ? ' danger' : ''}${command.active ? ' active' : ''} v2-monitoring-action`}
        aria-label=${command.label}
        aria-pressed=${command.active ? 'true' : undefined}
        title=${command.title}
        disabled=${isLifecycleWorkspaceCommand(command) && busyAction !== null}
        onClick=${() => { void run(command) }}
        data-testid=${`kw-chat-command-${command.id}`}
      >
        <${Icon} size=${14} aria-hidden="true" />
      </button>
    `
  }

  // Lifecycle (명령) and navigation (이동) commands render as two visually
  // separated clusters — one flat row of 7 look-alike icons was unreadable.
  const lifecycle = commands.filter(isLifecycleWorkspaceCommand)
  const utility = commands.filter(command => !isLifecycleWorkspaceCommand(command))
  return html`
    <div class="kw-chat-command-icons" data-testid="kw-chat-command-icons">
      ${lifecycle.map(renderIcon)}
      ${lifecycle.length > 0 && utility.length > 0
        ? html`<span class="kw-chat-command-sep" role="separator" aria-orientation="vertical"></span>`
        : null}
      ${utility.map(renderIcon)}
    </div>
  `
}

function ChatHeader({
  keeper,
  detailOpen,
  onToggleDetail,
  onOpenTurnInspector,
  artifactsOpen,
  onToggleArtifacts,
  mobile = false,
  onBack,
  onOpenRail,
  onOpenConfig,
}: {
  keeper: Keeper
  detailOpen: boolean
  onToggleDetail: () => void
  onOpenTurnInspector: () => void
  artifactsOpen: boolean
  onToggleArtifacts: () => void
  mobile?: boolean
  onBack?: () => void
  onOpenRail?: () => void
  onOpenConfig?: () => void
}): VNode {
  const tone = keeperStatusTone(keeper)
  const pill = statePillTone(tone)
  const live = phasePulse(keeper.lifecycle_phase)

  // Single-row header: identity + status + actions only. Runtime / model /
  // throughput / scope live in the context rail (ThroughputSection) — the
  // canonical home — so the header stays slim and the conversation gets the
  // vertical space instead of a redundant metadata sub-row.
  return html`
    <div class="kw-chat-head chat-head v2-monitoring-toolbar">
      <button
        type="button"
        class="kw-chat-back kw-act v2-monitoring-action"
        title="키퍼 로스터"
        aria-label="키퍼 로스터로 돌아가기"
        onClick=${() => {
          keeperMobilePane.value = 'roster'
          onBack?.()
        }}
        data-testid="kw-chat-back-to-roster"
      >
        <${ChevronLeft} size=${16} aria-hidden="true" />
      </button>
      <${WorkspaceSigil} id=${keeper.name} size=${40} beat=${live} />
      <div class="kw-chat-id">
        <div class="kw-chat-name-row">
          <h2 class="kw-chat-name">${keeper.koreanName ?? keeper.name}</h2>
          <span class=${`kw-state-pill ${pill}`} title=${keeperDisplayStatus(keeper)}>
            <${StatusDot} tone=${tone} pulse=${live} />${keeperPhaseLabel(keeper)}
          </span>
        </div>
      </div>
      <div class="kw-chat-actions">
        <${WorkspaceCommandButtons}
          key=${keeper.name}
          keeper=${keeper}
          mobile=${mobile}
          detailOpen=${detailOpen}
          artifactsOpen=${artifactsOpen}
          onOpenTurnInspector=${onOpenTurnInspector}
          onToggleArtifacts=${onToggleArtifacts}
          onToggleDetail=${onToggleDetail}
          onOpenConfig=${onOpenConfig}
        />
        ${mobile
          ? html`
              <button
                type="button"
                class="kw-chat-ctx-mobile v2-monitoring-action"
                title="컨텍스트"
                onClick=${onOpenRail}
                data-testid="kw-chat-mobile-context"
              >
                <${Info} size=${14} aria-hidden="true" />
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
  if (!open) return null

  return html`
    <${Suspense} fallback=${html`<div class="fixed inset-0 z-50 flex justify-end bg-black/40" role="dialog" aria-modal="true" aria-label="턴 검사">턴 검사 로딩…</div>`}>
      <${LazySharedTurnInspectorDrawer}
        testId="kw-chat-turn-inspector"
        keeperName=${keeperName}
        subtitle=${triggerEntry
          ? `메시지 ${triggerEntry.label} · ${triggerEntry.timestamp ?? triggerEntry.id}`
          : null}
        initialTurnRef=${triggerEntry?.turnRef ?? null}
        initialTurnTimestamp=${triggerEntry?.timestamp ?? null}
        open=${true}
        onClose=${onClose}
      />
    <//>
  `
}


// RFC keeper-conversation-hitl-flow §4.1-A: a slim, non-interactive cue at the
// top of the conversation so an operator who arrives via "대화에서 검토" sees the
// keeper is awaiting a decision. Read-only display + a link back to the approvals
// queue (the single act-point); no approve/reject action here by design.
function PendingApprovalCue({ keeper }: { keeper: Keeper }): VNode | null {
  const pending = keeper.trust?.approval_state?.pending_first
  const id = pending?.id?.trim()
  if (!id) return null
  const tool = pending?.tool_name?.trim()
  return html`
    <div
      class="kw-chat-pending-cue flex items-center gap-2 px-4 py-2 text-xs text-[var(--color-fg-secondary)]"
      role="status"
      data-testid="keeper-pending-approval-cue"
    >
      <${Pill} tone="warn" dot="warn">승인 대기</${Pill}>
      <span>이 keeper는 결재 대기 중입니다${tool ? ` · ${tool}` : ''}</span>
      <span class="flex-1"></span>
      <button
        type="button"
        class="kw-act v2-monitoring-action"
        onClick=${() => navigate('approvals')}
        title="결재 큐에서 이 요청을 승인·거부합니다"
      >결재 큐에서 처리 →</button>
    </div>
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
  const [artifactsOpen, setArtifactsOpen] = useState(false)
  const [composerBusyAction, setComposerBusyAction] = useState<WorkspaceCommandId | null>(null)
  const entries = keeperThreads.value[keeper.name] ?? []
  const detailOpen = false
  const onToggleDetail = onOpenDetail ?? (() => {})
  const openTurnInspector = (entry?: KeeperConversationEntry) => {
    setTurnInspectorEntry(entry ?? null)
    setTurnInspectorOpen(true)
  }
  const workspaceCommands = [
    ...lifecycleCommands(keeper),
    ...workspaceUtilityCommands({
      detailOpen,
      artifactsOpen,
      onOpenTurnInspector: () => openTurnInspector(),
          onToggleArtifacts: () => setArtifactsOpen((o) => !o),
      onToggleDetail,
      onOpenConfig,
    }),
  ]
  const composerCommands: ChatComposerCommand[] = workspaceCommands.map(command => ({
    id: String(command.id),
    group: workspaceCommandGroup(command),
    label: command.label,
    hint: command.title,
    glyph: COMMAND_GLYPHS[command.id],
    danger: command.danger,
    disabled: isLifecycleWorkspaceCommand(command) && composerBusyAction !== null,
    disabledReason: isLifecycleWorkspaceCommand(command) && composerBusyAction !== null
      ? '다른 keeper lifecycle 명령 실행 중'
      : undefined,
    run: async () => {
      if (!isLifecycleWorkspaceCommand(command)) {
        await command.onClick()
        return
      }
      if (composerBusyAction !== null) return
      setComposerBusyAction(command.id)
      try {
        await command.onClick()
      } finally {
        setComposerBusyAction(null)
      }
    },
  }))

  return html`
    <section class="kw-chat v2-monitoring-surface" role="region" aria-label=${`${keeper.name} 대화`}>
      <${ChatHeader}
        keeper=${keeper}
        detailOpen=${detailOpen}
        onToggleDetail=${onToggleDetail}
        onOpenTurnInspector=${() => openTurnInspector()}
        artifactsOpen=${artifactsOpen}
        onToggleArtifacts=${() => setArtifactsOpen((o) => !o)}
        mobile=${mobile}
        onBack=${onBack}
        onOpenRail=${onOpenRail}
        onOpenConfig=${onOpenConfig}
      />
      <${PendingApprovalCue} keeper=${keeper} />
      <div class="kw-chat-body">
        <${KeeperConversationPanel}
          keeperName=${keeper.name}
          placeholder=${`${keeper.name} 에게 메시지…  (⌘+Enter 전송)`}
          layout="workspace"
          composerCommands=${composerCommands}
          onInspectTurn=${openTurnInspector}
        />
        ${artifactsOpen
          ? html`
              <${Suspense} fallback=${html`<aside class="kw-artifacts v2-monitoring-surface">아티팩트 로딩…</aside>`}>
                <${LazyChatArtifactPanel} entries=${entries} />
              <//>
            `
          : null}
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
