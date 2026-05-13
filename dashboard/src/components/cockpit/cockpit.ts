import { html } from 'htm/preact'
import { Activity, ArrowUpRight, Brain, Code2, GitBranch, MessageSquare } from 'lucide-preact'
import type { ComponentChildren } from 'preact'
import {
  COCKPIT_ENTRYPOINTS,
  type CockpitEntrypoint,
  type CockpitMode,
} from '../../cockpit-entrypoints'
import {
  CognitiveDisclosure,
  type CognitiveDisclosureItem,
} from '../common/cognitive-disclosure'
import { RouteLink } from '../common/route-link'
import { WorldVisualizer } from '../world-visualizer'

type CockpitPlane = Extract<CockpitMode, 'work' | 'comms' | 'observe' | 'cognition' | 'ide'>

interface PlaneMeta {
  label: string
  summary: string
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

const COCKPIT_COVERED_ROUTES = COCKPIT_ENTRYPOINTS.filter(entry => entry.coverage === 'covered').length
const COCKPIT_BLOCKED_ROUTES = COCKPIT_ENTRYPOINTS.filter(entry => entry.coverage === 'backend-blocked').length

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

const COCKPIT_DISCLOSURE_ITEMS: CognitiveDisclosureItem[] = [
  {
    level: 'perceive',
    title: 'Route coverage',
    summary: `${COCKPIT_ENTRYPOINTS.length} routes across ${PLANE_ORDER.length} planes`,
    metric: `${COCKPIT_ENTRYPOINTS.length} routes`,
    defaultOpen: true,
    detail: html`
      <span class="font-mono text-3xs text-ok">${COCKPIT_COVERED_ROUTES} covered</span>
      <span class="mx-2 text-[var(--color-fg-disabled)]">/</span>
      <span class="font-mono text-3xs text-[var(--color-fg-muted)]">${COCKPIT_BLOCKED_ROUTES} backend-blocked</span>
    `,
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
    .map(part => part.charAt(0).toUpperCase() + part.slice(1))
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
      return 'border-ok/30 bg-ok/10 text-ok'
    case 'backend-blocked':
      return 'border-[var(--color-border-strong)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-muted)]'
  }
}

function PlaneSection({ plane, entries }: { plane: CockpitPlane; entries: CockpitEntrypoint[] }) {
  const meta = PLANE_META[plane]
  const covered = entries.filter(entry => entry.coverage === 'covered').length
  const blocked = entries.filter(entry => entry.coverage === 'backend-blocked').length

  return html`
    <section
      class="min-w-0 border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]"
      data-cockpit-plane=${plane}
      aria-label=${`${meta.label} cockpit routes`}
    >
      <div class="flex flex-wrap items-start justify-between gap-3 border-b border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-3">
        <div class="flex min-w-0 items-start gap-2">
          <span class="mt-0.5 inline-flex size-7 shrink-0 items-center justify-center rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] text-[var(--color-fg-secondary)]">
            ${planeIcon(plane)}
          </span>
          <div class="min-w-0">
            <h2 class="text-sm font-semibold text-[var(--color-fg-primary)]">${meta.label}</h2>
            <p class="mt-1 text-xs leading-relaxed text-[var(--color-fg-muted)]">${meta.summary}</p>
          </div>
        </div>
        <div class="flex shrink-0 flex-wrap justify-end gap-1.5 font-mono text-3xs">
          <span class="rounded-[var(--r-0)] border border-ok/30 bg-ok/10 px-1.5 py-0.5 text-ok">${covered} covered</span>
          ${blocked > 0
            ? html`<span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] px-1.5 py-0.5 text-[var(--color-fg-muted)]">${blocked} blocked</span>`
            : null}
        </div>
      </div>

      <div class="grid gap-2 p-3 sm:grid-cols-2 xl:grid-cols-3">
        ${entries.map(entrypoint => html`
          <${RouteLink}
            key=${`${entrypoint.mode}:${entrypoint.aliases[0]}`}
            tab=${entrypoint.target.tab}
            params=${entrypoint.target.params}
            class="group flex min-h-24 min-w-0 flex-col justify-between gap-3 rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] px-3 py-2.5 text-left no-underline transition-colors hover:border-[var(--color-border-strong)] hover:bg-[var(--color-bg-elevated)]"
            title=${routeCaption(entrypoint)}
            aria-label=${`Open ${displayLabel(entrypoint)} in ${routeCaption(entrypoint)}`}
          >
            <span class="flex min-w-0 items-start justify-between gap-2">
              <span class="min-w-0">
                <span class="block truncate text-xs font-semibold text-[var(--color-fg-primary)]">
                  ${displayLabel(entrypoint)}
                </span>
                <span class="mt-1 block truncate font-mono text-3xs text-[var(--color-fg-disabled)]">
                  ${routeCaption(entrypoint)}
                </span>
              </span>
              <${ArrowUpRight} class="mt-0.5 shrink-0 text-[var(--color-fg-muted)] transition-colors group-hover:text-[var(--color-fg-primary)]" size=${14} aria-hidden="true" />
            </span>
            <span class="flex items-center">
              <span class=${`rounded-[var(--r-0)] border px-1.5 py-0.5 font-mono text-3xs ${coverageClass(entrypoint.coverage)}`}>
                ${entrypoint.coverage}
              </span>
            </span>
          <//>
        `)}
      </div>
    </section>
  `
}

export function Cockpit() {
  return html`
    <div class="flex h-full w-full flex-col overflow-hidden bg-[var(--color-bg-page)]">
      <div class="grid min-h-0 flex-1 grid-cols-1 xl:grid-cols-[minmax(18rem,26rem)_minmax(0,1fr)]">
        <aside class="min-h-70 border-b border-[var(--color-border-default)] bg-black xl:border-r xl:border-b-0">
          <${WorldVisualizer} />
        </aside>

        <main class="min-h-0 overflow-y-auto" data-testid="cockpit-command-map">
          <div class="mx-auto flex max-w-7xl flex-col gap-4 px-4 py-4 sm:px-5">
            <section class="border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-3">
              <div class="flex flex-wrap items-end justify-between gap-3">
                <div>
                  <p class="font-mono text-3xs text-[var(--color-fg-muted)]">MASC Cockpit</p>
                  <h1 class="mt-1 text-lg font-semibold text-[var(--color-fg-primary)]">Command Map</h1>
                </div>
                <p class="font-mono text-3xs text-[var(--color-fg-muted)]">
                  ${COCKPIT_ENTRYPOINTS.length} routes across ${PLANE_ORDER.length} planes
                </p>
              </div>
            </section>

            <${CognitiveDisclosure}
              title="Progressive Disclosure"
              items=${COCKPIT_DISCLOSURE_ITEMS}
              testId="cockpit-disclosure"
            />

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
    </div>
  `
}
