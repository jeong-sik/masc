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

export type DesignCanvasCategory =
  | 'primitives'
  | 'molecules'
  | 'organisms'
  | 'surfaces'
  | 'motion'

const CATEGORIES: { id: DesignCanvasCategory; label: string }[] = [
  { id: 'primitives', label: 'Primitives' },
  { id: 'molecules', label: 'Molecules' },
  { id: 'organisms', label: 'Organisms' },
  { id: 'surfaces', label: 'Surfaces' },
  { id: 'motion', label: 'Motion' },
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

function Artboard({ title, children }: { title: string; children: unknown }) {
  return html`
    <div class="dc-artboard" data-design-canvas-artboard>
      <div class="dc-artboard-label">${title}</div>
      <div class="dc-artboard-well">${children}</div>
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
      </div>
    </div>
  `
}
