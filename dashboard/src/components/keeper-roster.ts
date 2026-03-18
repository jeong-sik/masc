// MASC Dashboard — Keeper Roster
// Full-page scrollable keeper list — dashboard panel style.
// Distinct from Agent Roster: context gauge is the hero, blue/MP accent.

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
  if (s === 'active' || s === 'running' || s === 'ok') return 'keeper-badge--active'
  if (s === 'idle' || s === 'listening') return 'keeper-badge--idle'
  return 'keeper-badge--offline'
}

export function KeeperRoster() {
  const keeperList = keepers.value
  const snap = missionSnapshot.value
  const briefs = snap?.keeper_briefs ?? []

  const items = briefs.length > 0 ? briefs : keeperList

  const sorted = [...items].sort((a, b) => {
    const aActive = (a.status ?? '').match(/active|running|ok/i) ? 0 : 1
    const bActive = (b.status ?? '').match(/active|running|ok/i) ? 0 : 1
    if (aActive !== bActive) return aActive - bActive
    const aRatio = a.context_ratio ?? 0
    const bRatio = b.context_ratio ?? 0
    return bRatio - aRatio
  })

  return html`
    <div class="roster-page keeper-page">
      <div class="roster-header">
        <h2 class="keeper-page__title">키퍼 (${items.length})</h2>
        <p class="keeper-page__subtitle">자율 에이전트 런타임 — 컨텍스트 압력과 세대 관리</p>
      </div>

      <div class="keeper-grid">
        ${sorted.map(k => {
          const ctxPct = k.context_ratio != null ? Math.round(k.context_ratio * 100) : null

          return html`
            <div class="keeper-panel" key=${k.name}>
              <div class="keeper-panel__top">
                <div class="keeper-panel__identity">
                  <strong class="keeper-panel__name">${k.name}</strong>
                  ${k.generation != null ? html`
                    <span class="keeper-panel__gen">G${k.generation}</span>
                  ` : null}
                  <span class="keeper-badge ${keeperStatusClass(k.status)}">
                    ${keeperStatusLabel(k.status)}
                  </span>
                </div>
                ${k.model ? html`
                  <span class="keeper-panel__model">${k.model}</span>
                ` : null}
              </div>

              ${ctxPct != null ? html`
                <div class="keeper-panel__gauge">
                  <div class="keeper-panel__gauge-label">
                    <span>CTX</span>
                    <span class="keeper-panel__gauge-pct">${ctxPct}%</span>
                  </div>
                  <div class="keeper-panel__gauge-track">
                    <div
                      class="keeper-panel__gauge-bar ${pressureClass(k.context_ratio)}"
                      style=${{ width: `${ctxPct}%` }}
                    />
                  </div>
                </div>
              ` : html`
                <div class="keeper-panel__gauge">
                  <div class="keeper-panel__gauge-label">
                    <span>CTX</span>
                    <span class="keeper-panel__gauge-pct keeper-panel__gauge-pct--na">--</span>
                  </div>
                  <div class="keeper-panel__gauge-track">
                    <div class="keeper-panel__gauge-bar" style=${{ width: '0%' }} />
                  </div>
                </div>
              `}

              ${k.current_work ? html`
                <div class="keeper-panel__work">${k.current_work}</div>
              ` : null}

              ${k.last_turn_ago_s != null ? html`
                <div class="keeper-panel__activity">${formatDuration(k.last_turn_ago_s)} 전</div>
              ` : null}
            </div>
          `
        })}
      </div>
      ${sorted.length === 0 ? html`
        <div class="roster-empty">활성 키퍼가 없습니다.</div>
      ` : null}
    </div>
  `
}
