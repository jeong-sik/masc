// MASC v2 — left surface nav rail (ported from prototype shell.jsx NavRail).
// Emits the prototype `.v2-nav` DOM (brand · nav-item · nav-div · spacer ·
// settings) so the vendored v2.css styles it 1:1. Surface ids are mapped to
// the live dashboard TabIds; clicking drives the real router (navigate()).

import { html } from 'htm/preact'
import { useState, useEffect } from 'preact/hooks'
import { navigate, route } from '../../router'
import type { TabId } from '../../types'
import { ICONS, ICON_MORE, type IconKey } from './icons-v2'

interface SurfaceEntry {
  readonly tab: TabId
  readonly label: string
  readonly icon: IconKey
}
type NavEntry = SurfaceEntry | 'sep'

// Prototype SURFACES order/labels/icons, mapped to live TabIds.
//   prototype work→workspace, monitor→monitoring, ide→code; rest 1:1.
// Groups mirror the 2026-07 standalone export's rail DOM: 개요 |
// Keepers · Registry · Monitor | 작업 · 승인 · 예약 | 보드 · Fusion · 로그 |
// IDE · 커넥터 (설정 stays in the footer slot below the spacer).
const SURFACES = [
  { tab: 'overview', label: '개요', icon: 'grid' },
  'sep',
  { tab: 'keepers', label: 'Keepers', icon: 'users' },
  { tab: 'registry', label: '레지스트리', icon: 'layers' },
  { tab: 'monitoring', label: 'Monitor', icon: 'monitor' },
  'sep',
  { tab: 'workspace', label: '작업', icon: 'target' },
  { tab: 'approvals', label: '승인', icon: 'shield' },
  { tab: 'schedule', label: '예약', icon: 'clock' },
  'sep',
  { tab: 'board', label: '보드', icon: 'board' },
  { tab: 'fusion', label: 'Fusion', icon: 'fusion' },
  { tab: 'logs', label: '로그', icon: 'logs' },
  'sep',
  { tab: 'code', label: 'IDE', icon: 'code' },
  { tab: 'connectors', label: '커넥터', icon: 'plug' },
] as const satisfies readonly NavEntry[]

export interface NavBadges {
  readonly approvals?: number
}

type RailEntry = Exclude<(typeof SURFACES)[number], 'sep'>
type RailTabId = RailEntry['tab']
type NonRailTabId = Exclude<TabId, RailTabId>

const SURFACE_LABEL = Object.fromEntries(
  SURFACES.filter((entry): entry is RailEntry => entry !== 'sep')
    .map(entry => [entry.tab, entry.label]),
) as Readonly<Record<RailTabId, string>>

const NON_RAIL_SURFACE_LABEL: Readonly<Record<NonRailTabId, string>> = {
  cockpit: 'MASC Cockpit',
  command: 'Command',
  lab: 'Lab',
  settings: '설정',
}

function isRailTab(tab: TabId): tab is RailTabId {
  return Object.hasOwn(SURFACE_LABEL, tab)
}

/** Crumb label for a tab. The table is exhaustive over every routable tab. */
export function surfaceLabel(tab: TabId): string {
  return isRailTab(tab) ? SURFACE_LABEL[tab] : NON_RAIL_SURFACE_LABEL[tab]
}

// On phones the rail collapses to a bottom tab bar: the operator's daily loop
// (home / agents / work / approvals) gets first-class tabs; the rest live behind
// a 더보기 sheet so no tab drops below the 44px hit target (prototype shell.jsx).
const MOBILE_PRIMARY: readonly TabId[] = ['overview', 'workspace', 'keepers', 'approvals']
const SURFACE_ENTRIES: readonly SurfaceEntry[] = SURFACES.filter((entry): entry is RailEntry => entry !== 'sep')

export function NavRailV2({ badges, mobile = false }: { badges?: NavBadges; mobile?: boolean }) {
  const active = route.value.tab
  const badgeFor = (tab: TabId): number | undefined => {
    if (tab === 'approvals') return badges?.approvals || undefined
    return undefined
  }

  const [moreOpen, setMoreOpen] = useState(false)
  useEffect(() => { setMoreOpen(false) }, [active])

  if (mobile) {
    const byTab = new Map(SURFACE_ENTRIES.map((e) => [e.tab, e]))
    const primary = MOBILE_PRIMARY.map((t) => byTab.get(t)).filter((e): e is SurfaceEntry => !!e)
    const hidden = SURFACE_ENTRIES.filter((e) => !MOBILE_PRIMARY.includes(e.tab))
    const moreActive = !MOBILE_PRIMARY.includes(active)
    const hiddenBadge = hidden.reduce((n, e) => n + (badgeFor(e.tab) ?? 0), 0)
    const Tab = (e: SurfaceEntry) => {
      const badge = badgeFor(e.tab)
      return html`
        <button key=${e.tab} class=${`nav-item ${active === e.tab ? 'on' : ''}`} onClick=${() => navigate(e.tab)} title=${e.label}>
          ${ICONS[e.icon]}<span class="nlbl">${e.label}</span>
          ${badge ? html`<span class="nav-badge">${badge}</span>` : null}
        </button>
      `
    }
    return html`
      <nav class="v2-nav is-mnav">
        ${primary.map(Tab)}
        <button class=${`nav-item ${moreActive ? 'on' : ''}`} title="더보기" onClick=${(e: Event) => { e.stopPropagation(); setMoreOpen((o) => !o) }}>
          ${ICON_MORE}<span class="nlbl">더보기</span>
          ${hiddenBadge ? html`<span class="nav-badge">${hiddenBadge}</span>` : null}
        </button>
      </nav>
      ${moreOpen
        ? html`
            <div class="mnav-back" onClick=${() => setMoreOpen(false)}>
              <div class="mnav-sheet" onClick=${(e: Event) => e.stopPropagation()}>
                <div class="mnav-grip"></div>
                <div class="mnav-sheet-h">더보기</div>
                <div class="mnav-grid">
                  ${hidden.map((e) => {
                    const badge = badgeFor(e.tab)
                    return html`
                      <button key=${e.tab} class=${`mnav-tile ${active === e.tab ? 'on' : ''}`} onClick=${() => { navigate(e.tab); setMoreOpen(false) }}>
                        <span class="mnav-ic">${ICONS[e.icon]}</span>
                        <span class="mnav-lbl">${e.label}</span>
                        ${badge ? html`<span class="nav-badge">${badge}</span>` : null}
                      </button>
                    `
                  })}
                  <button class=${`mnav-tile ${active === 'settings' ? 'on' : ''}`} onClick=${() => { navigate('settings'); setMoreOpen(false) }}>
                    <span class="mnav-ic">${ICONS.gear}</span>
                    <span class="mnav-lbl">설정</span>
                  </button>
                </div>
              </div>
            </div>
          `
        : null}
    `
  }

  return html`
    <nav class="v2-nav">
      <div class="nav-brand" role="button" tabindex=${0} title="MASC · 개요(홈)로" style=${{ cursor: 'pointer' }} onClick=${() => navigate('overview')}>
        <div class="nav-home">M</div>
        <span class="nlbl">MASC</span>
      </div>
      ${SURFACES.map((entry, i) =>
        entry === 'sep'
          ? html`<div key=${'sep' + i} class="nav-div"></div>`
          : (() => {
              const badge = badgeFor(entry.tab)
              return html`
                <button
                  key=${entry.tab}
                  class=${`nav-item ${active === entry.tab ? 'on' : ''}`}
                  onClick=${() => navigate(entry.tab)}
                  title=${entry.label}
                >
                  ${ICONS[entry.icon]}<span class="nlbl">${entry.label}</span>
                  ${badge ? html`<span class="nav-badge">${badge}</span>` : null}
                </button>
              `
            })(),
      )}
      <div class="nav-spacer"></div>
      <button
        class=${`nav-item ${active === 'settings' ? 'on' : ''}`}
        title="설정"
        onClick=${() => navigate('settings')}
      >
        ${ICONS.gear}<span class="nlbl">설정</span>
      </button>
    </nav>
  `
}
