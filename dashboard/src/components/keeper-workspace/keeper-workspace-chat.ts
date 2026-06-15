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
  bucketDotTone,
  keeperPhaseLabel,
  statePillTone,
  keeperModelLabel,
  keeperRuntimeLabel,
} from './keeper-workspace-shared'

/** Latest per-turn throughput from the metrics series (no scalar field). */
function latestTps(keeper: Keeper): number | null {
  const series = keeper.metrics_series ?? []
  for (let i = series.length - 1; i >= 0; i -= 1) {
    const v = series[i]?.wall_tokens_per_second
    if (typeof v === 'number' && v > 0) return Math.round(v)
  }
  return null
}

function keeperScope(keeper: Keeper): string | null {
  return keeper.skill_primary ?? null
}

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
  const tone = bucketDotTone(bucket)
  const pill = statePillTone(bucket)
  const model = keeperModelLabel(keeper)
  const runtime = keeperRuntimeLabel(keeper)
  const scope = keeperScope(keeper)
  const tps = latestTps(keeper)
  const live = bucket === 'running'

  return html`
    <div class="kw-chat-head">
      <${WorkspaceSigil} id=${keeper.name} size=${46} beat=${live} />
      <div class="kw-chat-id">
        <div class="kw-chat-name-row">
          <h2 class="kw-chat-name">${keeper.koreanName ?? keeper.name}</h2>
          <span class=${`kw-state-pill ${pill}`} title=${keeperDisplayStatus(keeper)}>
            <${StatusDot} tone=${tone} pulse=${live} />${keeperPhaseLabel(keeper)}
          </span>
        </div>
        <div class="kw-chat-sub">
          ${scope ? html`<span><span class="k">scope</span><span class="mono">${scope}</span></span>` : null}
          ${model ? html`<span><span class="k">모델</span><span class="mono">${model}</span></span>` : null}
          ${runtime ? html`<span><span class="k">런타임</span><span class="mono">${runtime}</span></span>` : null}
          ${live && tps !== null
            ? html`<span class="kw-tps-live"><span class="kw-tps-dot"></span><span class="k">tok/s</span><span class="mono">${tps}</span></span>`
            : null}
        </div>
      </div>
      <div class="kw-chat-actions">
        <${KeeperLifecycleButtons} keeper=${keeper} effectiveStatus=${keeperDisplayStatus(keeper)} />
        <button type="button" class="kw-act danger" title="컨텍스트 비우기" onClick=${onClear}>비우기</button>
        <button
          type="button"
          class="kw-act"
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
    <section class="kw-chat" role="region" aria-label=${`${keeper.name} 대화`}>
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
