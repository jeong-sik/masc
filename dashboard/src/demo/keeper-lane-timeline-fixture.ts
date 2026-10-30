import '../styles/ds-theme-tokens.css'
import '../styles/global.css'
import '../styles/keeper-workspace.css'

import { html } from 'htm/preact'
import { render } from 'preact'

import type { DashboardKeeperWaitingInventory } from '../api'
import { KeeperLaneStrip } from '../components/keeper-workspace/keeper-lane-strip'
import type { Keeper } from '../types'

const keeper = { name: 'sangsu' } as Keeper

const inventory: DashboardKeeperWaitingInventory = {
  schema: 'masc.dashboard.keeper_waiting_inventory.v3',
  source: 'server_keeper_waiting_inventory',
  generated_at: '2026-08-09T00:00:00Z',
  supported_states: ['idle', 'busy', 'waiting', 'deferred'],
  keeper_count_known: true,
  keeper_count: 1,
  waiting_keeper_count: 1,
  row_count: 3,
  keepers: [
    {
      keeper_name: 'sangsu',
      state: 'waiting',
      waiting_count: 3,
      sources: { event_queue_pending: 2, schedule_waiting: 1 },
      waiting_on: [
        {
          keeper_name: 'sangsu',
          source: 'event_queue_pending',
          waiting_on: 'discord:product-review',
          what: 'discord:product-review 멘션',
          wake_producer: 'connector_attention_hook',
          since_iso: '2026-08-08T10:12:03Z',
          next_action: 'keeper_drain_event_queue',
          detail: { event_id: 'evt-new', connector: 'discord' },
        },
        {
          keeper_name: 'sangsu',
          source: 'schedule_waiting',
          waiting_on: 'masc.keeper_wake',
          what: '예약 실행 · masc.keeper_wake',
          wake_producer: 'schedule_runner',
          since_iso: '2026-08-08T06:39:09Z',
          due_at_iso: '2026-08-09T07:29:34Z',
          next_action: 'wait_until_due',
          detail: { schedule_id: 'daily-news' },
        },
        {
          keeper_name: 'sangsu',
          source: 'event_queue_pending',
          waiting_on: 'discord:incident-room',
          what: 'discord:incident-room 멘션',
          wake_producer: 'connector_attention_hook',
          since_iso: '2026-08-06T03:59:42Z',
          next_action: 'keeper_drain_event_queue',
          detail: { event_id: 'evt-old', connector: 'discord' },
        },
      ],
    },
  ],
}

const root = document.getElementById('app')
if (root) {
  render(
    html`
      <main
        class="min-h-screen px-4 py-8"
        style="background: var(--color-bg-page); color: var(--color-fg-primary);"
        data-testid="keeper-lane-timeline-fixture"
      >
        <section
          class="ctx-panel mx-auto max-w-[980px] rounded-[var(--r-2)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-4"
        >
          <${KeeperLaneStrip}
            keeper=${keeper}
            inventory=${inventory}
            ready=${true}
            loading=${false}
            error=${null}
            pushReady=${true}
          />
        </section>
      </main>
    `,
    root,
  )
}
