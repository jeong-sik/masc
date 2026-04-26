// QuickBindForm — single-row keeper↔channel binding without having to
// scroll down to the keeper directory, expand a keeper, and then paste
// the channel ID. Mounted at the top of a connector card when the
// connector is live and has keepers available but zero bindings yet
// (the gap state the rail marks "warn").
//
// The underlying POST body matches the existing bindConnector helper in
// connector-status.ts — we don't duplicate the call path.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import type { GateKeeperInfo } from '../api/gate'
import { ActionButton } from './common/button'
import { TextInput } from './common/input'
import { bindConnector } from './connector-status'

interface FormEntry {
  channelId: string
  keeperName: string
  submitting: boolean
}

const formState = signal<Record<string, FormEntry>>({})

function getEntry(connectorId: string, keepers: GateKeeperInfo[]): FormEntry {
  const existing = formState.value[connectorId]
  if (existing) return existing
  const firstKeeper = keepers[0]?.name ?? ''
  return { channelId: '', keeperName: firstKeeper, submitting: false }
}

function setEntry(connectorId: string, patch: Partial<FormEntry>) {
  const current = formState.value[connectorId] ?? { channelId: '', keeperName: '', submitting: false }
  formState.value = { ...formState.value, [connectorId]: { ...current, ...patch } }
}

export function resetQuickBindState() {
  formState.value = {}
}

/** Pure: map a connector_id to the channel-id placeholder example that
    matches that platform's native format. Keeps the hint close to what
    the operator will copy-paste from the target app.

    - discord  → 18-19 digit snowflake (right-click channel → Copy ID)
    - imessage → +1XXXXXXXXXX or group id
    - slack    → C-prefix or #name (right-click channel in Slack →
                 Copy link → last path segment)
    - telegram → -100… or @channel_name

    Reference — Linear / Stripe onboarding: show an example that LOOKS
    like what the operator will paste, not a generic "ID". Unknown
    connectors fall through to a neutral example. */
export function channelIdPlaceholder(connectorId: string): string {
  switch (connectorId) {
    case 'discord':
      return '1234567890123456789 (18-19 digit snowflake)'
    case 'slack':
      return 'C0123ABCD 또는 #general'
    case 'telegram':
      return '-1001234567890 또는 @channel_name'
    case 'imessage':
      return '+1XXXXXXXXXX 또는 group id'
    default:
      return '1234567890 또는 #general'
  }
}

async function submit(connectorId: string, entry: FormEntry) {
  const channel = entry.channelId.trim()
  if (!channel || !entry.keeperName) return
  setEntry(connectorId, { submitting: true })
  try {
    await bindConnector(connectorId, entry.keeperName, channel)
    // bindConnector already refreshes + toasts; we just clear the local
    // channel draft so the operator can immediately bind another.
    setEntry(connectorId, { channelId: '', submitting: false })
  } catch {
    // bindConnector already surfaced the toast; still need to unwedge the
    // submitting state so the operator can retry.
    setEntry(connectorId, { submitting: false })
  }
}

export function QuickBindForm({ connectorId, keepers }: {
  connectorId: string
  keepers: GateKeeperInfo[]
}) {
  if (keepers.length === 0) return null
  const entry = getEntry(connectorId, keepers)
  // Keep keeperName in sync if the previously-selected keeper was removed
  // from the directory between renders.
  const keeperNames = keepers.map(k => k.name)
  if (!keeperNames.includes(entry.keeperName)) {
    setEntry(connectorId, { keeperName: keeperNames[0] ?? '' })
  }

  const disabled = entry.submitting || entry.channelId.trim() === ''

  return html`
    <div
      class="mt-3 flex flex-wrap items-end gap-2 rounded border border-dashed border-[var(--color-border-default)] bg-[var(--white-2)] px-3 py-2.5"
      data-quick-bind=${connectorId}
    >
      <div class="min-w-0 flex-1 basis-[160px]">
        <label class="mb-1 block text-3xs uppercase tracking-4 text-[var(--color-fg-disabled)]" for=${`qb-channel-${connectorId}`}>
          채널 ID
        </label>
        <${TextInput}
          id=${`qb-channel-${connectorId}`}
          value=${entry.channelId}
          placeholder=${channelIdPlaceholder(connectorId)}
          onInput=${(ev: InputEvent) => {
            const target = ev.currentTarget as HTMLInputElement
            setEntry(connectorId, { channelId: target.value })
          }}
          onKeyDown=${(ev: KeyboardEvent) => {
            // Enter submits from either input; Shift+Enter falls through
            // in case we ever swap this field for a multi-line input.
            if (ev.key === 'Enter' && !ev.shiftKey) {
              ev.preventDefault()
              void submit(connectorId, getEntry(connectorId, keepers))
            }
          }}
        />
      </div>
      <div class="min-w-0 basis-[140px]">
        <label class="mb-1 block text-3xs uppercase tracking-4 text-[var(--color-fg-disabled)]" for=${`qb-keeper-${connectorId}`}>
          Keeper
        </label>
        <select
          id=${`qb-keeper-${connectorId}`}
          class="w-full rounded border border-[var(--color-border-default)] bg-[var(--color-bg-page)] px-2 py-1 font-mono text-2xs text-[var(--color-fg-primary)] focus:border-[var(--accent-1)] focus:outline-none"
          onChange=${(ev: Event) => {
            const target = ev.currentTarget as HTMLSelectElement
            setEntry(connectorId, { keeperName: target.value })
          }}
        >
          ${keepers.map(k => html`
            <option value=${k.name} selected=${k.name === entry.keeperName}>${k.name}</option>
          `)}
        </select>
      </div>
      <${ActionButton}
        variant="primary"
        size="sm"
        disabled=${disabled}
        onClick=${() => { void submit(connectorId, entry) }}
      >
        ${entry.submitting ? '연결 중...' : '🔗 Bind'}
      <//>
    </div>
  `
}
