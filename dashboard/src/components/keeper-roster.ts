// MASC Dashboard — Keeper Roster
// Full-page scrollable keeper list with context pressure and generation info.

import { html } from 'htm/preact'
import { keepers } from '../store'
import { missionSnapshot } from '../mission-store'
import { formatDuration } from './mission-utils'

function pressureClass(ratio: number | null | undefined): string {
  if (ratio == null) return ''
  const pct = ratio * 100
  if (pct < 50) return 'pressure--ok'
  if (pct < 70) return 'pressure--amber'
  if (pct < 85) return 'pressure--orange'
  return 'pressure--red'
}

function keeperStatusLabel(status?: string): string {
  const s = (status ?? '').toLowerCase()
  if (s === 'active' || s === 'running' || s === 'ok') return '활성'
  if (s === 'idle' || s === 'listening') return '유휴'
  if (s === 'offline' || s === 'inactive') return '오프라인'
  return status ?? '알 수 없음'
}

function keeperStatusClass(status?: string): string {
  const s = (status ?? '').toLowerCase()
  if (s === 'active' || s === 'running' || s === 'ok') return 'roster-badge--active'
  if (s === 'idle' || s === 'listening') return 'roster-badge--idle'
  return 'roster-badge--offline'
}

export function KeeperRoster() {
  const keeperList = keepers.value
  const snap = missionSnapshot.value
  const briefs = snap?.keeper_briefs ?? []

  // Use briefs if available (richer data), fall back to keeper signal
  const items = briefs.length > 0 ? briefs : keeperList

  // Sort: active first, then by context pressure (high first)
  const sorted = [...items].sort((a, b) => {
    const aActive = (a.status ?? '').match(/active|running|ok/i) ? 0 : 1
    const bActive = (b.status ?? '').match(/active|running|ok/i) ? 0 : 1
    if (aActive !== bActive) return aActive - bActive
    const aRatio = a.context_ratio ?? 0
    const bRatio = b.context_ratio ?? 0
    return bRatio - aRatio
  })

  return html`
    <div class="roster-page">
      <div class="roster-header">
        <h2 class="roster-title">키퍼 (${items.length})</h2>
      </div>

      <div class="roster-list">
        ${sorted.map(k => html`
          <div class="roster-card keeper-roster-card" key=${k.name}>
            <div class="keeper-roster__main">
              <div class="keeper-roster__header">
                <strong class="roster-card__name">${k.name}</strong>
                ${k.generation != null ? html`
                  <span class="keeper-roster__gen">G${k.generation}</span>
                ` : null}
                <span class="roster-badge ${keeperStatusClass(k.status)}">
                  ${keeperStatusLabel(k.status)}
                </span>
              </div>

              ${k.context_ratio != null ? html`
                <div class="keeper-roster__pressure">
                  <div class="keeper-roster__pressure-track">
                    <div
                      class="keeper-roster__pressure-bar ${pressureClass(k.context_ratio)}"
                      style=${{ width: `${Math.round(k.context_ratio * 100)}%` }}
                    />
                  </div>
                  <span class="keeper-roster__pressure-label">
                    ctx ${Math.round(k.context_ratio * 100)}%
                  </span>
                </div>
              ` : null}

              ${k.current_work ? html`
                <div class="roster-card__work">${k.current_work}</div>
              ` : null}

              <div class="roster-card__meta">
                ${k.last_turn_ago_s != null ? html`
                  <span>${formatDuration(k.last_turn_ago_s)} 전</span>
                ` : null}
                ${k.model ? html`
                  <span class="roster-card__model">${k.model}</span>
                ` : null}
              </div>
            </div>
          </div>
        `)}
        ${sorted.length === 0 ? html`
          <div class="roster-empty">활성 키퍼가 없습니다.</div>
        ` : null}
      </div>
    </div>
  `
}
