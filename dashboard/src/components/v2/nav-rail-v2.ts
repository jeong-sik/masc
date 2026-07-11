// MASC v2 — left surface nav rail (ported from prototype shell.jsx NavRail).
// Emits the prototype `.v2-nav` DOM (brand · nav-item · nav-div · spacer ·
// settings) so the vendored v2.css styles it 1:1. Surface ids are mapped to
// the live dashboard TabIds; clicking drives the real router (navigate()).

import { html } from 'htm/preact'
import { useState, useEffect } from 'preact/hooks'
import { navigate, route } from '../../router'
import type { TabId } from '../../types'
import { ICONS, ICON_MORE } from './icons-v2'

interface SurfaceEntry {
  readonly tab: TabId
  readonly label: string
  readonly icon: keyof typeof ICONS
}
type NavEntry = SurfaceEntry | 'sep'

// Prototype SURFACES order/labels/icons, mapped to live TabIds.
//   prototype work→workspace, monitor→monitoring, ide→code; rest 1:1.
// Groups mirror the 2026-07 standalone export's rail DOM: 개요 |
// Keepers · Monitor | 작업 · 승인 · 예약 | 보드 · Fusion · 로그 |
// IDE · 커넥터 (설정 stays in the footer slot below the spacer).
//
// `as const satisfies` (rather than a `: readonly NavEntry[]` annotation)
// keeps each entry's `tab` field a literal instead of widening it to `TabId`,
// so RailBadgeTab below is exactly the tabs this rail renders — add a surface
// here and the nav-badges.ts `satisfies NavBadges` check immediately demands
// an explicit badge decision for it (0 allowed, but stated).
const SURFACES = [
  { tab: 'overview', label: '개요', icon: 'grid' },
  'sep',
  { tab: 'keepers', label: 'Keepers', icon: 'users' },
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

// Each literal member of the const tuple, minus the 'sep' separators — the
// precise per-position type (e.g. `{ tab: "connectors"; ... }`), not the
// widened nominal SurfaceEntry interface. A predicate asserting `is
// SurfaceEntry` here would fail: SurfaceEntry's `tab: TabId` is broader than
// any single tuple position's literal tab, so it isn't assignable to the
// exact union TypeScript infers for `(typeof SURFACES)[number]`.
type SurfaceTupleEntry = Exclude<(typeof SURFACES)[number], 'sep'>

/** Every tab the rail can show a badge on: the SURFACES entries plus the
 *  footer-slotted 설정 button. Kept as a closed record (not `Partial`) so
 *  adding a rail tab is a compile error until nav-badges.ts states its count. */
export type RailBadgeTab = SurfaceTupleEntry['tab'] | 'settings'

export type NavBadges = Readonly<Record<RailBadgeTab, number>>

const SURFACE_LABEL: Readonly<Record<string, string>> = Object.fromEntries(
  SURFACES.filter((e): e is SurfaceTupleEntry => e !== 'sep').map((e) => [e.tab, e.label]),
)

/** Crumb label for a tab (prototype SURFACE_LABEL); settings + unknowns fall back. */
export function surfaceLabel(tab: TabId): string {
  return SURFACE_LABEL[tab] ?? (tab === 'settings' ? '설정' : tab)
}

// On phones the rail collapses to a bottom tab bar: the operator's daily loop
// (home / agents / work / approvals) gets first-class tabs; the rest live behind
// a 더보기 sheet so no tab drops below the 44px hit target (prototype shell.jsx).
const MOBILE_PRIMARY: readonly TabId[] = ['overview', 'workspace', 'keepers', 'approvals']
const SURFACE_ENTRIES: readonly SurfaceTupleEntry[] = SURFACES.filter((e): e is SurfaceTupleEntry => e !== 'sep')

export function NavRailV2({ badges, mobile = false }: { badges?: NavBadges; mobile?: boolean }) {
  const active = route.value.tab
  // 0/absent both render nothing — `|| undefined` treats the typed record's
  // explicit zeros (overview/monitoring/fusion/logs/code/settings — see
  // nav-badges.ts) the same as an omitted `badges` prop (tests, storybook).
  const badgeFor = (tab: RailBadgeTab): number | undefined => badges?.[tab] || undefined

  const [moreOpen, setMoreOpen] = useState(false)
  useEffect(() => { setMoreOpen(false) }, [active])

  if (mobile) {
    const byTab = new Map<TabId, SurfaceTupleEntry>(SURFACE_ENTRIES.map((e) => [e.tab, e]))
    const primary = MOBILE_PRIMARY.map((t) => byTab.get(t)).filter((e): e is SurfaceTupleEntry => !!e)
    const hidden = SURFACE_ENTRIES.filter((e) => !MOBILE_PRIMARY.includes(e.tab))
    const moreActive = !MOBILE_PRIMARY.includes(active)
    const hiddenBadge = hidden.reduce((n, e) => n + (badgeFor(e.tab) ?? 0), 0)
    const Tab = (e: SurfaceTupleEntry) => {
      const badge = badgeFor(e.tab)
      return html`
        <button key=${e.tab} class=${`nav-item ${active === e.tab ? 'on' : ''}`} onClick=${() => navigate(e.tab)} title=${e.label}>
          ${ICONS[e.icon]}<span class="nlbl">${e.label}</span>
          ${badge ? html`<span class="nav-badge">${badge}</span><span class="sr-only">${` (${badge}건)`}</span>` : null}
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
                        ${badge ? html`<span class="nav-badge">${badge}</span><span class="sr-only">${` (${badge}건)`}</span>` : null}
                      </button>
                    `
                  })}
                  <button class=${`mnav-tile ${active === 'settings' ? 'on' : ''}`} onClick=${() => { navigate('settings'); setMoreOpen(false) }}>
                    <span class="mnav-ic">${ICONS.gear}</span>
                    <span class="mnav-lbl">설정</span>
                    ${badgeFor('settings') ? html`<span class="nav-badge">${badgeFor('settings')}</span>` : null}
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
                  ${badge ? html`<span class="nav-badge">${badge}</span><span class="sr-only">${` (${badge}건)`}</span>` : null}
                </button>
              `
            })(),
      )}
      <div class="nav-spacer"></div>
      ${(() => {
        const settingsBadge = badgeFor('settings')
        return html`
          <button
            class=${`nav-item ${active === 'settings' ? 'on' : ''}`}
            title="설정"
            onClick=${() => navigate('settings')}
          >
            ${ICONS.gear}<span class="nlbl">설정</span>
            ${settingsBadge ? html`<span class="nav-badge">${settingsBadge}</span><span class="sr-only">${` (${settingsBadge}건)`}</span>` : null}
          </button>
        `
      })()}
    </nav>
  `
}
