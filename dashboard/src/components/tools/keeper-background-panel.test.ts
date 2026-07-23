import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'

import type { DashboardKeeperBackground } from '../../api'
import { KeeperBackgroundPanel } from './keeper-background-panel'

function backgroundFixture(): DashboardKeeperBackground {
  return {
    schema: 'masc.dashboard.keeper_background.v1',
    source: 'server_keeper_background',
    generated_at: '2026-07-08T00:00:00Z',
    keeper_count: 2,
    recurring_keeper_count: 2,
    recurring_count: 3,
    keepers: [
      {
        keeper_name: 'sangsu',
        loop: {
          phase: 'running',
          started_at_iso: '2026-07-08T00:00:00Z',
          restart_count: 1,
          last_restart_at_iso: '2026-07-08T00:05:00Z',
          dead_since_iso: null,
        },
        recurring_count: 2,
        recurring: [
          {
            id: 'loop-1-1',
            label: 'heartbeat-check',
            action_kind: 'broadcast',
            interval_sec: 30,
            enabled: true,
            run_count: 12,
            failure_count: 0,
            last_run_at_iso: '2026-07-08T00:10:00Z',
            next_run_at_iso: '2026-07-08T00:10:30Z',
          },
          {
            id: 'loop-1-2',
            label: 'stale-sweep',
            action_kind: 'broadcast',
            interval_sec: 600,
            enabled: false,
            run_count: 4,
            failure_count: 2,
            last_run_at_iso: '2026-07-08T00:02:00Z',
            next_run_at_iso: null,
          },
        ],
      },
      {
        keeper_name: 'recovery-bot',
        loop: {
          phase: 'dead',
          started_at_iso: '2026-07-07T23:00:00Z',
          restart_count: 3,
          dead_since_iso: '2026-07-08T00:08:00Z',
        },
        recurring_count: 1,
        recurring: [
          {
            id: 'loop-2-1',
            label: 'audit-scan',
            action_kind: 'broadcast',
            interval_sec: 300,
            enabled: true,
            run_count: 0,
            failure_count: 0,
            last_run_at_iso: null,
            next_run_at_iso: null,
          },
        ],
      },
    ],
  }
}

describe('KeeperBackgroundPanel', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders one card per keeper with recurring tasks and loop context', () => {
    render(html`<${KeeperBackgroundPanel} background=${backgroundFixture()} />`, container)

    const cards = container.querySelectorAll('[data-testid="keeper-background-card"]')
    expect(cards).toHaveLength(2)

    // Header count pills
    expect(container.textContent).toContain('keepers')
    expect(container.textContent).toContain('recurring keepers')
    expect(container.textContent).toContain('recurring tasks')

    // Keeper names + loop phase chips
    expect(container.textContent).toContain('sangsu')
    expect(container.textContent).toContain('running')
    expect(container.textContent).toContain('recovery-bot')
    expect(container.textContent).toContain('dead')

    // Recurring task rows (labels, interval, run/fail counts, enabled state)
    expect(container.textContent).toContain('heartbeat-check')
    expect(container.textContent).toContain('stale-sweep')
    // Fire cadence is shown once, in the fixed-width `when` gutter (30s / 10m),
    // not duplicated as an "every Ns" meta chip.
    expect(container.querySelector('.sch-bg-when')?.textContent).toContain('30s')
    expect(container.textContent).toContain('runs 12')
    expect(container.textContent).toContain('fail 2')
    expect(container.textContent).toContain('enabled')
    expect(container.textContent).toContain('disabled')
    // action_kind and loop restart context are rendered verbatim from the projection.
    expect(container.textContent).toContain('broadcast')
    expect(container.querySelector('[data-keeper-background="sangsu"]')?.textContent).toContain('restarts 1')
  })

  it('surfaces a dead loop and never fabricates a next-run time', () => {
    render(html`<${KeeperBackgroundPanel} background=${backgroundFixture()} />`, container)

    const dead = container.querySelector('[data-keeper-background="recovery-bot"]')
    expect(dead?.textContent).toContain('dead since')
    expect(dead?.textContent).toContain('restarts 3')
    // A never-run task reports next/last as '-' (projection null), not a guess.
    expect(dead?.textContent).toContain('next -')
    expect(dead?.textContent).toContain('last -')
  })

  it('renders unavailable state without inventing cards', () => {
    render(html`<${KeeperBackgroundPanel} background=${null} />`, container)

    expect(container.textContent).toContain('keeper background unavailable')
    expect(container.querySelector('[data-testid="keeper-background-card"]')).toBeNull()
  })

  it('renders empty projection without inventing keepers', () => {
    const empty: DashboardKeeperBackground = {
      keeper_count: 0,
      recurring_keeper_count: 0,
      recurring_count: 0,
      keepers: [],
    }
    render(html`<${KeeperBackgroundPanel} background=${empty} />`, container)

    expect(container.textContent).toContain('no keeper background loops in projection')
    expect(container.querySelector('[data-testid="keeper-background-card"]')).toBeNull()
  })

  it('renders a keeper with zero recurring tasks as an explicit empty sub-state', () => {
    const fixture = backgroundFixture()
    fixture.keepers = [
      {
        keeper_name: 'quiet-one',
        loop: { phase: 'running', restart_count: 0 },
        recurring_count: 0,
        recurring: [],
      },
    ]
    render(html`<${KeeperBackgroundPanel} background=${fixture} />`, container)

    expect(container.querySelector('[data-keeper-background="quiet-one"]')?.textContent).toContain(
      'no recurring tasks',
    )
  })
})
