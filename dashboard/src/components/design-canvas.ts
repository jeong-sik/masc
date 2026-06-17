// DesignCanvas — keeper-v2 design-system preview surface for the Lab tab.
//
// A category-tab gallery that renders existing dashboard primitives at
// representative states. No backend wiring; all data is mock/sample.

import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { Meter } from './common/meter'
import { Vital, Vitals } from './common/vital'
import { StatCell } from './common/stat-cell'
import { InlineSpinner } from './common/inline-spinner'
import { LoadingBar } from './common/loading-bar'
import { ActionButton } from './common/button'
import { StatusChip } from './common/status-chip'
import { StatusBadge } from './common/status-badge'
import { CountBadge } from './common/badge'
import { PanelCard } from './common/panel-card'
import { SurfaceCard } from './common/card'
import { Sparkline } from './common/sparkline'
import { Table } from './common/table'
import { TimeAgo } from './common/time-ago'
import { KeeperBadge } from './keeper-badge'
import { SessionTraceEntry } from './session-trace/session-trace-entry'
import { keeperStateTone } from './common/status-chip'
import {
  FIXTURE_KEEPERS,
  FIXTURE_GOALS,
  FIXTURE_POSTS,
  FIXTURE_TURNS,
  FIXTURE_EPISODES,
  type FixtureKeeper,
  type FixtureGoal,
  type FixtureJob,
  type FixturePost,
} from './design-canvas-fixtures'
import type { MemoryOsEpisodeSummary } from '../api/dashboard'
import { Sigil, SigilChip } from './common/sigil-chip'
import { LogFilter } from './common/log-filter'
import { SuggestionChip } from './common/suggestion-chip'
import { KeeperConfigPanel } from './keeper-config-panel-v2'
import { EmptyState, ErrorState, LoadingState } from './state-surfaces'

export type DesignCanvasCategory =
  | 'primitives'
  | 'molecules'
  | 'organisms'
  | 'surfaces'
  | 'motion'
  | 'craft'
  | 'states'
  | 'fixtures'

const CATEGORIES: { id: DesignCanvasCategory; label: string }[] = [
  { id: 'primitives', label: 'Primitives' },
  { id: 'molecules', label: 'Molecules' },
  { id: 'organisms', label: 'Organisms' },
  { id: 'surfaces', label: 'Surfaces' },
  { id: 'motion', label: 'Motion' },
  { id: 'craft', label: 'Craft' },
  { id: 'states', label: 'States' },
  { id: 'fixtures', label: 'Fixtures' },
]

function useDesignCanvasTheme() {
  const [theme, setTheme] = useState<'dark' | 'paper'>(() => {
    if (typeof document === 'undefined') return 'dark'
    return document.documentElement.dataset.theme === 'paper' ? 'paper' : 'dark'
  })

  useEffect(() => {
    if (typeof document === 'undefined') return
    if (theme === 'paper') {
      document.documentElement.dataset.theme = 'paper'
    } else {
      delete document.documentElement.dataset.theme
    }
  }, [theme])

  const toggle = () => setTheme(prev => (prev === 'paper' ? 'dark' : 'paper'))

  return { theme, toggle }
}

function Section({ title, children }: { title: string; children: unknown }) {
  return html`
    <div class="dc-section" data-design-canvas-section>
      <h3 class="dc-section-title">${title}</h3>
      <div class="dc-section-body">${children}</div>
    </div>
  `
}

function Artboard({ title, h, children }: { title: string; h?: number; children: unknown }) {
  return html`
    <div class="dc-artboard" data-design-canvas-artboard>
      <div class="dc-artboard-label">${title}</div>
      <div class="dc-artboard-well" style=${h !== undefined ? { height: `${h}px` } : undefined}>${children}</div>
    </div>
  `
}

function PrimitivesGallery() {
  return html`
    <${Section} title="Primitives">
      <${Artboard} title="Meter">
        <div class="dc-stack-v">
          <${Meter} pct=${72} />
          <${Meter} pct=${94} hot=${true} />
          <${Meter} pct=${12} />
        </div>
      <//>

      <${Artboard} title="Vitals">
        <${Vitals}
          items=${[
            { k: 'CPU', v: '42%', tone: 'default' },
            { k: 'MEM', v: '1.2 GB', tone: 'volt' },
            { k: 'ERR', v: '0', tone: 'ok' },
            { k: 'LAT', v: '34 ms', tone: 'warn' },
          ]}
          class="dc-vitals-narrow"
        />
      <//>

      <${Artboard} title="StatCell">
        <div class="dc-stack-v">
          <${StatCell} label="Throughput" value="1.2k" sub="ops/s" tone="ok" />
          <${StatCell} label="Queue" value="8" sub="pending" tone="warn" />
          <${StatCell} label="Voltage" value="⚡" tone="volt" />
        </div>
      <//>

      <${Artboard} title="Spinners">
        <div class="dc-row">
          <${InlineSpinner} size="xs" />
          <${InlineSpinner} size="sm" />
          <${InlineSpinner} size="md" />
        </div>
      <//>

      <${Artboard} title="LoadingBar">
        <div class="dc-stack-v">
          <${LoadingBar} />
          <${LoadingBar} ariaLabel="Loading sample" testId="dc-loading-bar" />
        </div>
      <//>

      <${Artboard} title="Buttons">
        <div class="dc-stack-v">
          <${ActionButton} variant="primary">Primary<//>
          <${ActionButton} variant="ghost">Ghost<//>
          <${ActionButton} variant="danger">Danger<//>
          <${ActionButton} variant="subtle" pressed=${true}>Pressed<//>
        </div>
      <//>

      <${Artboard} title="Chips & Badges">
        <div class="dc-row-wrap">
          <${StatusChip} tone="ok">running<//>
          <${StatusChip} tone="warn">failing<//>
          <${StatusChip} tone="bad">crashed<//>
          <${StatusChip} tone="info">working<//>
          <${CountBadge} tone="accent">12<//>
          <${CountBadge} tone="warn">3<//>
        </div>
      <//>

      <${Artboard} title="StatusBadge">
        <div class="dc-row-wrap">
          <${StatusBadge} status="active" />
          <${StatusBadge} status="error" />
          <${StatusBadge} status="paused" />
        </div>
      <//>

      <${Artboard} title="Sigil">
        <div class="dc-row-wrap">
          <${Sigil} slot=${3} size=${32} title="iron-claw">IC<//>
          <${Sigil} slot=${5} size=${24} heartbeat=${true} fontScale=${0.46}>LU<//>
          <${SigilChip} slot=${7} mono="SV">svalbard<//>
        </div>
      <//>

      <${Artboard} title="LogFilter">
        <div class="dc-row-wrap">
          <${LogFilter} active=${true}>All<//>
          <${LogFilter}>Info<//>
          <${LogFilter}>Warn<//>
          <${LogFilter}>Error<//>
        </div>
      <//>

      <${Artboard} title="SuggestionChip">
        <div class="dc-row-wrap">
          <${SuggestionChip}>Re-run preflight<//>
          <${SuggestionChip}>Open the diff<//>
          <${SuggestionChip} pre="\u21bb">Regenerate reply<//>
        </div>
      <//>
    <//>
  `
}

function MoleculesGallery() {
  return html`
    <${Section} title="Molecules">
      <${Artboard} title="Vitals strip">
        <div class="dc-molecule-row">
          <${Vital} k="QPS" v="1.4k" tone="volt" />
          <${Vital} k="P99" v="56 ms" tone="ok" />
          <${Vital} k="Errs" v="0.2%" tone="warn" />
        </div>
      <//>

      <${Artboard} title="Stat row">
        <div class="dc-stat-row">
          <${StatCell} label="Healthy" value="42" tone="ok" />
          <${StatCell} label="Degraded" value="3" tone="warn" />
          <${StatCell} label="Critical" value="1" tone="bad" />
          <${StatCell} label="Unknown" value="7" tone="volt" />
        </div>
      <//>

      <${Artboard} title="Status + meter row">
        <div class="dc-stack-v">
          <div class="dc-row">
            <${StatusChip} tone="ok">active<//>
            <${Meter} pct=${68} />
          </div>
          <div class="dc-row">
            <${StatusChip} tone="warn">degraded<//>
            <${Meter} pct=${88} hot=${true} />
          </div>
        </div>
      <//>

      <${Artboard} title="Button group">
        <div class="dc-button-group">
          <${ActionButton} variant="primary" size="sm">Run<//>
          <${ActionButton} variant="ghost" size="sm">Pause<//>
          <${ActionButton} variant="danger" size="sm">Stop<//>
        </div>
      <//>
    <//>
  `
}

const MOCK_KEEPERS = [
  { name: 'alpha', state: 'active', qps: '1.2k', latency: '34 ms' },
  { name: 'beta', state: 'warn', qps: '840', latency: '78 ms' },
  { name: 'gamma', state: 'paused', qps: '0', latency: '-' },
]

function KeeperCard({ name, state, qps, latency }: {
  name: string
  state: string
  qps: string
  latency: string
}) {
  return html`
    <div class="dc-organism-card" data-design-canvas-organism="keeper-card">
      <div class="dc-organism-header">
        <span class="dc-mono">${name}</span>
        <${StatusChip} tone=${state === 'active' ? 'ok' : state === 'warn' ? 'warn' : 'paused'}>${state}<//>
      </div>
      <${Vitals}
        items=${[
          { k: 'QPS', v: qps, tone: 'default' },
          { k: 'LAT', v: latency, tone: state === 'warn' ? 'warn' : 'default' },
        ]}
      />
      <${Meter} pct=${state === 'active' ? 62 : state === 'warn' ? 84 : 0} hot=${state === 'warn'} />
    </div>
  `
}

const MOCK_SPARKLINE = Array.from({ length: 18 }, () => Math.round(Math.random() * 80 + 10))

function OrganismsGallery() {
  return html`
    <${Section} title="Organisms">
      <${Artboard} title="Keeper cards">
        <div class="dc-organism-row">
          ${MOCK_KEEPERS.map((k, i) => html`
            <${KeeperCard} key=${i} name=${k.name} state=${k.state} qps=${k.qps} latency=${k.latency} />
          `)}
        </div>
      <//>

      <${Artboard} title="Telemetry card">
        <${PanelCard} title="api/v1/dashboard" data-design-canvas-organism="telemetry-card">
          <div class="dc-telemetry-layout">
            <${StatCell} label="RPS" value="2.1k" tone="ok" />
            <${StatCell} label="P99" value="45 ms" tone="volt" />
            <div class="dc-spark-box">
              <${Sparkline} values=${MOCK_SPARKLINE} width=${160} height=${40} color="var(--brass-2)" />
            </div>
          </div>
          <div class="dc-row" style=${{ marginTop: '12px' }}>
            <${StatusBadge} status="active" />
            <${CountBadge} tone="accent">v2.4<//>
          </div>
        <//>
      <//>

      <${Artboard} title="Composite panel">
        <${SurfaceCard}>
          <div class="dc-composite-head">
            <span class="dc-section-title">Fleet overview</span>
            <${ActionButton} variant="ghost" size="sm">View all<//>
          </div>
          <div class="dc-stat-row">
            <${StatCell} label="Running" value="42" tone="ok" />
            <${StatCell} label="Paused" value="3" tone="warn" />
            <${StatCell} label="Offline" value="1" tone="bad" />
          </div>
          <div style=${{ marginTop: '12px' }}>
            <${LoadingBar} ariaLabel="Fleet telemetry loading" />
          </div>
        <//>
      <//>

      <${Artboard} title="Keeper config" h=${420}>
        <div style=${{ height: '100%', overflow: 'auto' }}>
          <${KeeperConfigPanel}
            keeper=${{ id: 'iron-claw', ns: 'ns:masc-core', model: 'claude-sonnet-4', runtime: 'oas·seoul-1' }}
            base=${{
              persona: '간결하고 분석적인 keeper. 산문보다 diff를 선호.',
              instructions: '항상 preflight를 먼저 실행한다.\n스키마 변경은 마이그레이션과 함께 제출한다.',
              traits: ['analytical', 'terse', 'cautious'],
            }}
            inherit=${[
              { tag: '① System', txt: 'You are {{keeper}}, a persistent coding keeper in {{namespace}}.' },
              { tag: '② World', txt: 'Runtime {{runtime}} · model {{model}} · shared worktree under basepath.' },
            ]}
            permissions=${{ '읽기': true, '쓰기': true, 'git': true, '외부 호출': false }}
          />
        </div>
      <//>

      <${Artboard} title="State surfaces" h=${240}>
        <div style=${{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: '1px', background: 'var(--color-border-default)', height: '100%' }}>
          <div style=${{ background: 'var(--color-bg-page)', display: 'grid', placeItems: 'center' }}>
            <${EmptyState} title="실행 중인 keeper 없음" hint="이 네임스페이스에는 아직 활성 keeper가 없습니다." action="Keeper 생성" />
          </div>
          <div style=${{ background: 'var(--color-bg-page)', display: 'grid', placeItems: 'center' }}>
            <${ErrorState} title="게이트에 연결할 수 없음" detail="ECONNREFUSED gate.masc.local:7070" />
          </div>
          <div style=${{ background: 'var(--color-bg-page)', padding: '16px' }}>
            <${LoadingState} title="로스터 불러오는 중…" rows=${3} />
          </div>
        </div>
      <//>
    <//>
  `
}

function SurfacesGallery() {
  return html`
    <${Section} title="Surfaces">
      <${Artboard} title="Lab surface sample">
        <div class="dc-surface-sample v2-lab-surface">
          <div class="v2-lab-panel dc-surface-panel">
            <div class="section-head">Panel</div>
            <div class="p-3">
              <${Vitals}
                items=${[
                  { k: 'TASKS', v: '12', tone: 'volt' },
                  { k: 'DONE', v: '9', tone: 'ok' },
                ]}
              />
            </div>
          </div>
          <div class="v2-lab-card dc-surface-card">
            <p class="m-0 text-xs text-[var(--color-fg-muted)]">Card content area</p>
            <${ActionButton} variant="primary" size="sm" class="mt-2">Action<//>
          </div>
        </div>
      <//>

      <${Artboard} title="Status rail">
        <div class="dc-surface-rail">
          <div class="dc-rail-dot ok"></div>
          <div class="dc-rail-dot warn"></div>
          <div class="dc-rail-dot bad"></div>
          <div class="dc-rail-dot info"></div>
        </div>
      <//>
    <//>
  `
}

function MotionGallery() {
  return html`
    <${Section} title="Motion">
      <${Artboard} title="Loading states">
        <div class="dc-row-wrap">
          <${InlineSpinner} ariaLabel="Loading" />
          <span class="loading-row"><span class="spinner"></span><span>Working…</span></span>
          <${LoadingBar} ariaLabel="Streaming" />
        </div>
      <//>

      <${Artboard} title="Pulse glows">
        <div class="dc-row-wrap">
          <span class="dc-pulse-dot anim-pulse-ok"></span>
          <span class="dc-pulse-dot anim-pulse-warn"></span>
          <span class="dc-pulse-dot anim-pulse-err"></span>
          <span class="dc-pulse-dot anim-pulse-info"></span>
        </div>
      <//>

      <${Artboard} title="Enter animation">
        <div class="dc-motion-stack">
          <div class="dc-motion-card anim-slide-up">slide-up</div>
          <div class="dc-motion-card anim-fade-in">fade-in</div>
          <div class="dc-motion-card anim-pop">pop</div>
        </div>
      <//>
    <//>
  `
}

function CraftsGallery() {
  return html`
    <${Section} title="Craft">
      <${Artboard} title="Workbench card">
        <div data-design-canvas-organism="craft-card">
          <${PanelCard} title="craft-surface">
            <div class="dc-stat-row">
              <${StatCell} label="Drafted" value="12" tone="ok" />
              <${StatCell} label="Review" value="3" tone="warn" />
              <${StatCell} label="Blocked" value="1" tone="bad" />
            </div>
            <div class="mt-3 flex flex-wrap gap-2">
              <${StatusChip} tone="info">prompt<//>
              <${StatusChip} tone="neutral">fixture<//>
              <${CountBadge} tone="accent">v2<//>
            </div>
          <//>
        </div>
      <//>

      <${Artboard} title="Tool-call card">
        <${SurfaceCard} variant="compact" data-design-canvas-organism="tool-call-card">
          <div class="flex items-center gap-2 mb-2">
            <span class="size-5 inline-flex items-center justify-center rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] text-2xs font-mono font-bold text-[var(--color-fg-secondary)]">T</span>
            <span class="font-mono text-sm font-semibold text-[var(--color-accent-fg)]">edit_file</span>
          </div>
          <div class="text-2xs font-mono text-[var(--color-fg-secondary)] truncate">{"path":"src/components/lab.ts"}</div>
          <div class="mt-2 flex items-center gap-2">
            <${StatusChip} tone="ok" uppercase=${false}>success<//>
            <span class="text-3xs text-[var(--color-fg-disabled)]">240 ms</span>
          </div>
        <//>
      <//>

      <${Artboard} title="Inspector row">
        <div class="dc-surface-rail">
          <div class="dc-rail-dot ok"></div>
          <div class="dc-rail-dot warn"></div>
          <div class="dc-rail-dot bad"></div>
          <div class="dc-rail-dot info"></div>
        </div>
      <//>
    <//>
  `
}

function StatesGallery() {
  return html`
    <${Section} title="States">
      <${Artboard} title="Keeper lifecycle pills">
        <div class="dc-row-wrap">
          <${StatusChip} tone="ok">active<//>
          <${StatusChip} tone="warn">degraded<//>
          <${StatusChip} tone="bad">crashed<//>
          <${StatusChip} tone="info">paused<//>
          <${StatusChip} tone="neutral">offline<//>
        </div>
      <//>

      <${Artboard} title="Delivery badges">
        <div class="dc-row-wrap">
          <span class="inline-flex items-center rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-0.5 text-2xs font-semibold uppercase tracking-2 text-[var(--color-fg-secondary)]">delivered</span>
          <span class="inline-flex items-center rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-0.5 text-2xs font-semibold uppercase tracking-2 text-[var(--color-status-warn)]">sending</span>
          <span class="inline-flex items-center rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-0.5 text-2xs font-semibold uppercase tracking-2 text-[var(--color-status-err)]">error</span>
        </div>
      <//>

      <${Artboard} title="Meter thresholds">
        <div class="dc-stack-v">
          <${Meter} pct=${24} />
          <${Meter} pct=${68} />
          <${Meter} pct=${94} hot=${true} />
        </div>
      <//>
    <//>
  `
}

function SectionStack({ title, children }: { title: string; children: unknown }) {
  return html`
    <div class="dc-section" data-design-canvas-section>
      <h3 class="dc-section-title">${title}</h3>
      <div class="dc-fixtures-stack">${children}</div>
    </div>
  `
}

function jobStateTone(state: string): string {
  switch (state) {
    case 'done':
      return 'ok'
    case 'in-progress':
      return 'info'
    case 'review':
      return 'warn'
    case 'blocked':
      return 'bad'
    case 'todo':
    default:
      return 'neutral'
  }
}

function priorityTone(priority: string): string {
  switch (priority) {
    case 'high':
      return 'bad'
    case 'normal':
      return 'info'
    case 'low':
    default:
      return 'neutral'
  }
}

function FixtureKeeperCard({ keeper }: { keeper: FixtureKeeper }) {
  return html`
    <${SurfaceCard}
      class="w-[260px]"
      variant="compact"
      data-design-canvas-fixture="keeper-card"
    >
      <div class="flex items-center justify-between gap-2 mb-2">
        <${KeeperBadge} id=${keeper.id} name=${keeper.kr} variant="full" />
        <${StatusChip} tone=${keeperStateTone(keeper.phase)}>${keeper.phase}<//>
      </div>
      <${Vitals}
        items=${[
          { k: 'NS', v: keeper.ns, tone: 'default' },
          { k: 'CTX', v: `${Math.round(keeper.ctx * 100)}%`, tone: keeper.ctx >= 0.85 ? 'warn' : 'default' },
          { k: 'TRACES', v: keeper.traces, tone: 'default' },
          { k: 'TASKS', v: keeper.tasks, tone: 'default' },
          { k: 'TPS', v: keeper.tps, tone: keeper.tps > 0 ? 'volt' : 'default' },
        ]}
      />
      <${Meter} pct=${Math.round(keeper.ctx * 100)} hot=${keeper.ctx >= 0.85} />
      <div class="text-3xs text-[var(--color-fg-muted)] mt-2">${keeper.model} · ${keeper.runtime}</div>
    <//>
  `
}

function FixtureGoalsTable() {
  const columns = [
    { key: 'id', header: 'ID' },
    { key: 'title', header: 'Title' },
    {
      key: 'lead',
      header: 'Lead',
      render: (row: FixtureGoal) => html`<${KeeperBadge} id=${row.lead} variant="sigil" />`,
    },
    {
      key: 'priority',
      header: 'Priority',
      render: (row: FixtureGoal) => html`<${StatusChip} tone=${priorityTone(row.priority)} uppercase=${false}>${row.priority}<//>`,
    },
    { key: 'due', header: 'Due' },
    {
      key: 'metric',
      header: 'Metric',
      render: (row: FixtureGoal) => row.metric ?? html`<span class="text-[var(--color-fg-muted)]">—</span>`,
    },
  ]

  return html`
    <div class="overflow-x-auto rounded-[var(--r-1)] border border-[var(--color-border-default)]">
      <${Table}
        columns=${columns}
        rows=${FIXTURE_GOALS}
        getRowId=${(row: FixtureGoal) => row.id}
        aria-label="Fixture goals"
      />
    </div>
  `
}

function FixtureJobsTable() {
  const rows = FIXTURE_GOALS.flatMap((goal) =>
    goal.jobs.map((job) => ({ ...job, goalId: goal.id, goalTitle: goal.title })),
  )

  const columns = [
    { key: 'id', header: 'ID' },
    { key: 'title', header: 'Title' },
    {
      key: 'keeper',
      header: 'Keeper',
      render: (row: FixtureJob & { goalId: string; goalTitle: string }) =>
        row.keeper ? html`<${KeeperBadge} id=${row.keeper} variant="sigil" />` : html`<span class="text-[var(--color-fg-muted)]">unassigned</span>`,
    },
    {
      key: 'state',
      header: 'State',
      render: (row: FixtureJob & { goalId: string; goalTitle: string }) => html`<${StatusChip} tone=${jobStateTone(row.state)} uppercase=${false}>${row.state}<//>`,
    },
    {
      key: 'blocker',
      header: 'Blocker',
      render: (row: FixtureJob & { goalId: string; goalTitle: string }) => row.blocker ?? html`<span class="text-[var(--color-fg-muted)]">—</span>`,
    },
  ]

  return html`
    <div class="overflow-x-auto rounded-[var(--r-1)] border border-[var(--color-border-default)]">
      <${Table}
        columns=${columns}
        rows=${rows}
        getRowId=${(row: FixtureJob & { goalId: string; goalTitle: string }) => row.id}
        aria-label="Fixture jobs"
      />
    </div>
  `
}

function FixturePostCard({ post }: { post: FixturePost }) {
  return html`
    <${SurfaceCard}
      class="w-[320px]"
      variant="compact"
      data-design-canvas-fixture="post-card"
    >
      <div class="flex items-center justify-between gap-2 mb-2">
        <${KeeperBadge} id=${post.author} variant="full" />
        <${StatusChip} tone="neutral" uppercase=${false}>${post.board}<//>
      </div>
      ${post.title ? html`<h4 class="text-sm font-semibold text-[var(--color-fg-secondary)] mb-1">${post.title}</h4>` : null}
      <div
        class="text-sm leading-relaxed text-[var(--color-fg-primary)] line-clamp-4"
        dangerouslySetInnerHTML=${{ __html: post.body }}
      />
      <div class="flex flex-wrap items-center gap-2 mt-3">
        ${post.reactions.map(([emoji, count, reacted]) => html`
          <${StatusChip} key=${emoji} tone=${reacted ? 'info' : 'neutral'} uppercase=${false}>${emoji} ${count}<//>
        `)}
        <span class="text-3xs text-[var(--color-fg-muted)]">karma ${post.karma}</span>
        <span class="text-3xs text-[var(--color-fg-muted)]">replies ${post.replies}</span>
      </div>
    <//>
  `
}

function FixtureEpisodeCard({ episode }: { episode: MemoryOsEpisodeSummary }) {
  return html`
    <${SurfaceCard}
      class="w-[260px]"
      variant="compact"
      data-design-canvas-fixture="episode-card"
    >
      <div class="flex items-center justify-between gap-2 mb-2">
        <span class="font-mono text-2xs text-[var(--color-fg-secondary)]">${episode.trace_id}</span>
        <${StatusChip} tone=${episode.current ? 'ok' : 'warn'} uppercase=${false}>${episode.current ? 'current' : 'expired'}<//>
      </div>
      <div class="text-xs text-[var(--color-fg-secondary)] line-clamp-3 mb-2">${episode.summary}</div>
      <div class="flex items-center justify-between text-3xs text-[var(--color-fg-muted)]">
        <span>g${episode.generation.toString().padStart(4, '0')} · ${episode.claim_count} claims</span>
        ${episode.terminal_marker ? html`<span class="font-mono">${episode.terminal_marker}</span>` : null}
      </div>
      ${episode.valid_until_iso
        ? html`<div class="mt-2 text-3xs text-[var(--color-fg-muted)]"><${TimeAgo} timestamp=${episode.valid_until_iso} mode="both" /></div>`
        : null}
    <//>
  `
}

function FixturesGallery() {
  return html`
    <${SectionStack} title="Fixtures">
      <${Artboard} title="Keepers">
        <div class="dc-fixtures-row">
          ${FIXTURE_KEEPERS.map((keeper) => html`<${FixtureKeeperCard} key=${keeper.id} keeper=${keeper} />`)}
        </div>
      <//>

      <${Artboard} title="Goals">
        <div class="dc-fixtures-table-wrap">
          <${FixtureGoalsTable} />
        </div>
      <//>

      <${Artboard} title="Jobs">
        <div class="dc-fixtures-table-wrap">
          <${FixtureJobsTable} />
        </div>
      <//>

      <${Artboard} title="Posts">
        <div class="dc-fixtures-row">
          ${FIXTURE_POSTS.map((post) => html`<${FixturePostCard} key=${post.id} post=${post} />`)}
        </div>
      <//>

      <${Artboard} title="Turns">
        <div class="dc-fixtures-stack">
          ${FIXTURE_TURNS.map((event) => html`<${SessionTraceEntry} key=${event.id} event=${event} />`)}
        </div>
      <//>

      <${Artboard} title="Episodes">
        <div class="dc-fixtures-row">
          ${FIXTURE_EPISODES.map((episode) => html`<${FixtureEpisodeCard} key=${`${episode.trace_id}-${episode.generation}`} episode=${episode} />`)}
        </div>
      <//>
    <//>
  `
}

export function DesignCanvas() {
  const [category, setCategory] = useState<DesignCanvasCategory>('primitives')
  const { theme, toggle } = useDesignCanvasTheme()

  return html`
    <div class="dc-root" data-design-canvas>
      <div class="dc-header">
        <div>
          <h2 class="dc-title">Design Canvas</h2>
          <p class="dc-subtitle">keeper-v2 design-system preview</p>
        </div>
        <${ActionButton}
          variant="ghost"
          size="sm"
          onClick=${toggle}
          testId="design-canvas-theme-toggle"
          ariaLabel=${`Toggle theme, current: ${theme}`}
        >
          ${theme === 'paper' ? '☀ Paper' : '◐ Dark'}
        <//>
      </div>

      <div class="dc-tabs" role="tablist" aria-label="Design canvas categories">
        ${CATEGORIES.map(cat => html`
          <button
            key=${cat.id}
            type="button"
            role="tab"
            aria-selected=${cat.id === category}
            class=${`dc-tab ${cat.id === category ? 'active' : ''}`}
            onClick=${() => setCategory(cat.id)}
            data-testid=${`design-canvas-tab-${cat.id}`}
          >
            ${cat.label}
          </button>
        `)}
      </div>

      <div class="dc-stage" role="tabpanel" data-testid="design-canvas-stage">
        ${category === 'primitives' ? html`<${PrimitivesGallery} />` : null}
        ${category === 'molecules' ? html`<${MoleculesGallery} />` : null}
        ${category === 'organisms' ? html`<${OrganismsGallery} />` : null}
        ${category === 'surfaces' ? html`<${SurfacesGallery} />` : null}
        ${category === 'motion' ? html`<${MotionGallery} />` : null}
        ${category === 'craft' ? html`<${CraftsGallery} />` : null}
        ${category === 'states' ? html`<${StatesGallery} />` : null}
        ${category === 'fixtures' ? html`<${FixturesGallery} />` : null}
      </div>
    </div>
  `
}
