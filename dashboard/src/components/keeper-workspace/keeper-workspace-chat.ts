// Keeper Workspace — conversation pane (center). A spacious ChatHeader
// (identity + lifecycle actions) above the reused KeeperConversationPanel
// (layout="workspace"). The header replaces the old narrow detail-page
// header; the panel reuses the full chat engine unchanged.

import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import type { VNode } from 'preact'
import type { Keeper } from '../../types'
import { KeeperConversationPanel } from '../keeper-shared'
import { KeeperLifecycleButtons } from '../keeper-detail-lifecycle'
import { keeperMobilePane } from '../keeper-detail-state'
import { KeeperTurnInspector } from '../keeper-turn-inspector'
import { ChatArtifactPanel } from '../chat/artifact-panel'
import { keeperThreads } from '../../keeper-state'
import { keeperDisplayStatus } from '../../lib/keeper-runtime-display'
import {
  WorkspaceSigil,
  StatusDot,
  keeperBucket,
  keeperStatusTone,
  keeperPhaseLabel,
  statePillTone,
} from './keeper-workspace-shared'

function ChatHeader({
  keeper,
  detailOpen,
  onToggleDetail,
  onClear,
  onOpenTurnInspector,
  artifactsOpen,
  onToggleArtifacts,
}: {
  keeper: Keeper
  detailOpen: boolean
  onToggleDetail: () => void
  onClear: () => void
  onOpenTurnInspector: () => void
  artifactsOpen: boolean
  onToggleArtifacts: () => void
}): VNode {
  const bucket = keeperBucket(keeper)
  const tone = keeperStatusTone(keeper)
  const pill = statePillTone(tone)
  const live = bucket === 'running'

  // Single-row header: identity + status + actions only. Runtime / model /
  // throughput / scope live in the context rail (ThroughputSection) — the
  // canonical home — so the header stays slim and the conversation gets the
  // vertical space instead of a redundant metadata sub-row.
  return html`
    <div class="kw-chat-head v2-monitoring-toolbar">
      <button
        type="button"
        class="kw-chat-back kw-act v2-monitoring-action"
        title="키퍼 목록으로"
        aria-label="키퍼 목록으로"
        onClick=${() => { keeperMobilePane.value = 'roster' }}
        data-testid="kw-chat-back-to-roster"
      >← 키퍼</button>
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
        <${KeeperLifecycleButtons} keeper=${keeper} effectiveStatus=${keeperDisplayStatus(keeper)} />
        <button
          type="button"
          class="kw-act v2-monitoring-action"
          title="턴 검사"
          onClick=${onOpenTurnInspector}
          data-testid="kw-chat-turn-inspector-btn"
        >턴 검사</button>
        <button type="button" class="kw-act danger v2-monitoring-action" title="컨텍스트 비우기" onClick=${onClear}>비우기</button>
        <button
          type="button"
          class="kw-act v2-monitoring-action"
          aria-pressed=${artifactsOpen ? 'true' : 'false'}
          title="대화 아티팩트"
          onClick=${onToggleArtifacts}
          data-testid="kw-chat-artifacts-toggle"
        >${artifactsOpen ? '아티팩트 숨김' : '아티팩트'}</button>
        <button
          type="button"
          class="kw-act v2-monitoring-action"
          aria-pressed=${detailOpen ? 'true' : 'false'}
          title="상세 (상태 · 진단 · 정체성 · 설정 · 디버그)"
          onClick=${onToggleDetail}
        >${detailOpen ? '대화로' : '상세'}</button>
      </div>
    </div>
  `
}

function TurnInspectorDrawer({
  keeperName,
  open,
  onClose,
}: {
  keeperName: string
  open: boolean
  onClose: () => void
}) {
  if (!open) return null

  return html`
    <div
      class="fixed inset-0 z-50 flex justify-end bg-black/40"
      role="dialog"
      aria-modal="true"
      aria-label="턴 검사"
      data-testid="kw-chat-turn-inspector-drawer"
      onClick=${onClose}
    >
      <div
        class="h-full w-full max-w-2xl overflow-y-auto bg-[var(--color-bg-page)] shadow-2xl"
        onClick=${(e: Event) => e.stopPropagation()}
      >
        <div class="sticky top-0 z-10 flex items-center justify-between border-b border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-4 py-3 v2-monitoring-toolbar">
          <div>
            <h3 class="text-sm font-semibold text-[var(--color-fg-primary)]">턴 검사</h3>
            <p class="text-2xs text-[var(--color-fg-muted)]">${keeperName}</p>
          </div>
          <button
            type="button"
            class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-1.5 text-2xs text-[var(--color-fg-secondary)] transition-colors hover:bg-[var(--color-bg-hover)]"
            onClick=${onClose}
            data-testid="kw-chat-turn-inspector-close"
          >닫기</button>
        </div>
        <${KeeperTurnInspector} keeperName=${keeperName} />
      </div>
    </div>
  `
}

export function KeeperWorkspaceChat({
  keeper,
  detailOpen,
  onToggleDetail,
  onClear,
}: {
  keeper: Keeper
  detailOpen: boolean
  onToggleDetail: () => void
  onClear: () => void
}): VNode {
  const [turnInspectorOpen, setTurnInspectorOpen] = useState(false)
  const [artifactsOpen, setArtifactsOpen] = useState(false)
  const entries = keeperThreads.value[keeper.name] ?? []

  return html`
    <section class="kw-chat v2-monitoring-surface" role="region" aria-label=${`${keeper.name} 대화`}>
      <${ChatHeader}
        keeper=${keeper}
        detailOpen=${detailOpen}
        onToggleDetail=${onToggleDetail}
        onClear=${onClear}
        onOpenTurnInspector=${() => setTurnInspectorOpen(true)}
        artifactsOpen=${artifactsOpen}
        onToggleArtifacts=${() => setArtifactsOpen((o) => !o)}
      />
      <div class="kw-chat-body">
        <${KeeperConversationPanel}
          keeperName=${keeper.name}
          placeholder=${`${keeper.name} 에게 메시지…  (⌘+Enter 전송)`}
          layout="workspace"
        />
        ${artifactsOpen
          ? html`<${ChatArtifactPanel} entries=${entries} />`
          : null}
      </div>
      <${TurnInspectorDrawer}
        keeperName=${keeper.name}
        open=${turnInspectorOpen}
        onClose=${() => setTurnInspectorOpen(false)}
      />
    </section>
  `
}
