import { html } from 'htm/preact'
import { capitalize } from '../../lib/format-string'
import { Activity, Brain, Code2, GitBranch, MessageSquare } from 'lucide-preact'
import type { ComponentChildren } from 'preact'
import {
  COCKPIT_ENTRYPOINTS,
  type CockpitEntrypoint,
  type CockpitMode,
} from '../../cockpit-entrypoints'
import { RouteLink } from '../common/route-link'
import { WorldVisualizer } from '../world-visualizer'

type CockpitPlane = Extract<CockpitMode, 'work' | 'comms' | 'observe' | 'cognition' | 'ide'>

interface PlaneMeta {
  label: string
  summary: string
}

interface DisclosureItem {
  level: 'perceive' | 'comprehend' | 'project'
  title: string
  summary: string
  metric: string
}

const PLANE_ORDER = ['work', 'comms', 'observe', 'cognition', 'ide'] as const satisfies readonly CockpitPlane[]

const PLANE_META: Record<CockpitPlane, PlaneMeta> = {
  work: {
    label: 'Work',
    summary: 'Goals, tasks, and accountability routes',
  },
  comms: {
    label: 'Comms',
    summary: 'Board, message, and composer routes',
  },
  observe: {
    label: 'Observe',
    summary: 'Runtime, safety, audit, and cost routes',
  },
  cognition: {
    label: 'Cognition',
    summary: 'Keeper, decision, memory, and research routes',
  },
  ide: {
    label: 'IDE',
    summary: 'Source, review, diff, graph, and search routes',
  },
}

const ENTRIES_PER_PLANE: ReadonlyMap<CockpitPlane, CockpitEntrypoint[]> = (() => {
  const map = new Map<CockpitPlane, CockpitEntrypoint[]>()
  for (const plane of PLANE_ORDER) map.set(plane, [])
  for (const entrypoint of COCKPIT_ENTRYPOINTS) {
    if (PLANE_ORDER.includes(entrypoint.mode as CockpitPlane)) {
      map.get(entrypoint.mode as CockpitPlane)?.push(entrypoint)
    }
  }
  return map
})()

const COCKPIT_BLOCKED_ROUTES = COCKPIT_ENTRYPOINTS.filter(entry => entry.coverage === 'backend-blocked').length

// tie-break: strict `>` keeps the initial accumulator, so PLANE_ORDER[0] (first listed plane) wins on equal counts.
const PLANE_WITH_MOST_ENTRIES = PLANE_ORDER.reduce((top, plane) => {
  const count = ENTRIES_PER_PLANE.get(plane)?.length ?? 0
  const topCount = ENTRIES_PER_PLANE.get(top)?.length ?? 0
  return count > topCount ? plane : top
}, PLANE_ORDER[0])

const PLANE_WITH_MOST_GAPS = PLANE_ORDER.reduce((top, plane) => {
  const gaps = (ENTRIES_PER_PLANE.get(plane) ?? []).filter(entry => entry.coverage === 'backend-blocked').length
  const topGaps = (ENTRIES_PER_PLANE.get(top) ?? []).filter(entry => entry.coverage === 'backend-blocked').length
  return gaps > topGaps ? plane : top
}, PLANE_ORDER[0])

const COCKPIT_DISCLOSURE_ITEMS: DisclosureItem[] = [
  {
    level: 'perceive',
    title: 'Route coverage',
    summary: `${COCKPIT_ENTRYPOINTS.length} routes across ${PLANE_ORDER.length} planes`,
    metric: `${COCKPIT_ENTRYPOINTS.length} routes`,
  },
  {
    level: 'comprehend',
    title: 'Plane grouping',
    summary: `${PLANE_META[PLANE_WITH_MOST_ENTRIES].label} carries the most routes (${ENTRIES_PER_PLANE.get(PLANE_WITH_MOST_ENTRIES)?.length ?? 0})`,
    metric: `${PLANE_ORDER.length} planes`,
  },
  {
    level: 'project',
    title: 'Route gaps',
    summary: COCKPIT_BLOCKED_ROUTES > 0
      ? `${COCKPIT_BLOCKED_ROUTES} backend-blocked in ${PLANE_META[PLANE_WITH_MOST_GAPS].label}`
      : 'No backend-blocked routes',
    metric: `${COCKPIT_BLOCKED_ROUTES} gaps`,
  },
]

function planeIcon(plane: CockpitPlane): ComponentChildren {
  switch (plane) {
    case 'work':
      return html`<${GitBranch} size=${16} aria-hidden="true" />`
    case 'comms':
      return html`<${MessageSquare} size=${16} aria-hidden="true" />`
    case 'observe':
      return html`<${Activity} size=${16} aria-hidden="true" />`
    case 'cognition':
      return html`<${Brain} size=${16} aria-hidden="true" />`
    case 'ide':
      return html`<${Code2} size=${16} aria-hidden="true" />`
  }
}

function displayLabel(entrypoint: CockpitEntrypoint): string {
  const source = entrypoint.aliases[1] ?? entrypoint.aliases[0] ?? ''
  return source
    .split('-')
    .filter(Boolean)
    .map(part => capitalize(part))
    .join(' ')
}

function routeCaption(entrypoint: CockpitEntrypoint): string {
  const params = entrypoint.target.params ?? {}
  return [
    `#${entrypoint.target.tab}`,
    params.section,
    params.view,
    params.focus,
  ].filter(Boolean).join(' / ')
}

function coverageClass(coverage: CockpitEntrypoint['coverage']): string {
  switch (coverage) {
    case 'covered':
      return 'ok'
    case 'backend-blocked':
      return 'blk'
  }
}

function PlaneSection({ plane, entries }: { plane: CockpitPlane; entries: CockpitEntrypoint[] }) {
  const meta = PLANE_META[plane]
  const covered = entries.filter(entry => entry.coverage === 'covered').length
  const blocked = entries.filter(entry => entry.coverage === 'backend-blocked').length

  return html`
    <section
      class="cp-plane"
      data-cockpit-plane=${plane}
      aria-label=${`${meta.label} cockpit routes`}
    >
      <div class="cp-plane-h">
        <div class="lft">
          <div class="cp-plane-ico">${planeIcon(plane)}</div>
          <div>
            <h2>${meta.label}</h2>
            <div class="sum">${meta.summary}</div>
          </div>
        </div>
        <div class="chips">
          <span class="cp-cov ok">${covered} covered</span>
          ${blocked > 0
            ? html`<span class="cp-cov blk">${blocked} blocked</span>`
            : null}
        </div>
      </div>

      <div class="cp-routes">
        ${entries.map(entrypoint => html`
          <${RouteLink}
            key=${`${entrypoint.mode}:${entrypoint.aliases[0]}`}
            tab=${entrypoint.target.tab}
            params=${entrypoint.target.params}
            class="cp-route"
            title=${routeCaption(entrypoint)}
            aria-label=${`Open ${displayLabel(entrypoint)} in ${routeCaption(entrypoint)}`}
          >
            <div class="cp-route-top">
              <span class="cp-route-label">
                <span class="rl">${displayLabel(entrypoint)}</span>
                <span class="rc">${routeCaption(entrypoint)}</span>
              </span>
              <span class="arr" aria-hidden="true">↗</span>
            </div>
            <span class=${`cp-cov ${coverageClass(entrypoint.coverage)}`}>
              ${entrypoint.coverage}
            </span>
          <//>
        `)}
      </div>
    </section>
  `
}

export function Cockpit() {
  return html`
    <div class="cp-body" data-testid="cockpit-command-map">
      <aside class="cp-world">
        <${WorldVisualizer} />
      </aside>

      <main class="cp-main">
        <div class="cp-inner">
          <header class="cp-head">
            <div>
              <p class="cp-eyebrow">Command Map</p>
              <h1 class="cp-title">Cockpit</h1>
            </div>
            <p class="cp-sub">
              ${COCKPIT_ENTRYPOINTS.length} routes across ${PLANE_ORDER.length} planes
            </p>
          </header>

          <section
            class="cp-disc"
            aria-label="Progressive disclosure"
            data-testid="cockpit-disclosure"
          >
            <div class="cp-disc-h"><h3>Progressive Disclosure</h3></div>
            <div class="cp-disc-rows">
              ${COCKPIT_DISCLOSURE_ITEMS.map(item => html`
                <div
                  key=${item.level}
                  class="cp-disc-row"
                  data-cockpit-disclosure-level=${item.level}
                >
                  <div class="lvl">${item.level}</div>
                  <div class="ttl">${item.title}</div>
                  <div class="sum">${item.summary}</div>
                  <span class="mtr">${item.metric}</span>
                </div>
              `)}
            </div>
          </section>

          ${PLANE_ORDER.map(plane => html`
            <${PlaneSection}
              key=${plane}
              plane=${plane}
              entries=${ENTRIES_PER_PLANE.get(plane) ?? []}
            />
          `)}
        </div>
      </main>
    </div>
  `
}
