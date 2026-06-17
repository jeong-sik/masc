// Keeper Workspace — conversation pane (center). A spacious ChatHeader
// (identity + lifecycle actions) above the reused KeeperConversationPanel
// (layout="workspace"). The header replaces the old narrow detail-page
// header; the panel reuses the full chat engine unchanged.

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import type { Keeper } from '../../types'
import { KeeperConversationPanel } from '../keeper-shared'
import { KeeperLifecycleButtons } from '../keeper-detail-lifecycle'
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
}: {
  keeper: Keeper
  detailOpen: boolean
  onToggleDetail: () => void
  onClear: () => void
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
        <button type="button" class="kw-act danger v2-monitoring-action" title="컨텍스트 비우기" onClick=${onClear}>비우기</button>
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
  return html`
    <section class="kw-chat v2-monitoring-surface" role="region" aria-label=${`${keeper.name} 대화`}>
      <${ChatHeader}
        keeper=${keeper}
        detailOpen=${detailOpen}
        onToggleDetail=${onToggleDetail}
        onClear=${onClear}
      />
      <${KeeperConversationPanel}
        keeperName=${keeper.name}
        placeholder=${`${keeper.name} 에게 메시지…  (⌘+Enter 전송)`}
        layout="workspace"
      />
    </section>
  `
}
