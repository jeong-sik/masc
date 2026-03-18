// MASC Dashboard — Keeper Summary Card (rich overview per keeper)

import { html } from 'htm/preact'
import type { Keeper } from '../../types'
import { navigate } from '../../router'
import { relativeTime } from '../../lib/format-time'

interface KeeperSummaryCardProps {
  keeper: Keeper
}

function timeAgo(iso: string | undefined): string {
  return relativeTime(iso, '-')
}

function contextTier(ratio: number | undefined): string {
  if (ratio == null) return ''
  if (ratio < 0.7) return 'green'
  if (ratio < 0.85) return 'yellow'
  return 'red'
}

export function KeeperSummaryCard({ keeper }: KeeperSummaryCardProps) {
  const model = keeper.primary_model ?? keeper.model ?? '-'
  const gen = keeper.generation ?? 0
  const turns = keeper.turn_count ?? 0
  const ratio = keeper.context_ratio
  const pct = ratio != null ? Math.round(ratio * 100) : null
  const tools = (keeper.recent_tool_names ?? []).slice(0, 3)

  return html`
    <div class="keeper-summary-card" onClick=${() => navigate('agents')}>
      <div class="keeper-summary-card__header">
        <span class="keeper-summary-card__name">${keeper.name}</span>
        <span class="keeper-summary-card__meta">
          ${model}
          ${' / '}
          <span title="세대: 컨텍스트 리셋 횟수. 0=초기, N=N번 승계">gen ${gen}</span>
          ${' / '}turn ${turns}
        </span>
      </div>
      ${pct != null ? html`
        <div class="keeper-summary-card__context-bar">
          <div class="keeper-summary-card__context-fill keeper-summary-card__context-fill--${contextTier(ratio)}" style=${{ width: `${pct}%` }} />
          <span class="keeper-summary-card__context-label">${pct}%</span>
        </div>
      ` : null}
      <div class="keeper-summary-card__footer">
        <span class="keeper-summary-card__activity">${timeAgo(keeper.last_heartbeat)}</span>
        ${tools.length > 0 ? html`
          <div class="keeper-summary-card__tools">
            ${tools.map(t => html`<span class="keeper-summary-card__tool-pill" key=${t}>${t}</span>`)}
          </div>
        ` : null}
      </div>
    </div>
  `
}
