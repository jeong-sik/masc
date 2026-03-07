import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import type { Keeper, KeeperDiagnostic, KeeperConversationEntry } from '../types'
import {
  hydrateKeeperStatus,
  keeperActionErrors,
  keeperHydrating,
  keeperProbing,
  keeperRecovering,
  keeperSending,
  keeperStatusDetails,
  keeperThreads,
  probeKeeperRuntime,
  recoverKeeperRuntime,
  sendKeeperThreadMessage,
} from '../keeper-runtime'
import { showToast } from './common/toast'

function quietReasonLabel(reason?: string | null): string {
  switch (reason) {
    case 'quiet_hours':
      return 'quiet hours'
    case 'min_gap':
      return 'cooldown gate'
    case 'no_recent_activity':
      return 'waiting for activity'
    case 'disabled':
      return 'runtime disabled'
    case 'startup':
      return 'warming up'
    case 'llm_error':
      return 'llm error'
    case 'graphql_error':
      return 'graphql error'
    case 'never_started':
      return 'never started'
    default:
      return 'unknown'
  }
}

function nextActionLabel(path: string): string {
  switch (path) {
    case 'manual_lodge_poke':
      return 'Poke Lodge'
    case 'probe':
      return 'Probe'
    case 'recover':
      return 'Recover'
    default:
      return 'Message'
  }
}

function deliveryLabel(entry: KeeperConversationEntry): string {
  switch (entry.delivery) {
    case 'sending':
      return 'sending'
    case 'timeout':
      return 'timeout'
    case 'error':
      return 'error'
    case 'delivered':
      return 'delivered'
    default:
      return entry.role
  }
}

function chipClass(entry: KeeperConversationEntry): string {
  if (entry.delivery === 'error' || entry.delivery === 'timeout') return 'bad'
  if (entry.delivery === 'sending') return 'warn'
  if (entry.role === 'assistant') return 'assistant'
  if (entry.role === 'user') return 'user'
  return 'warn'
}

function formatTime(timestamp?: string | null): string | null {
  if (!timestamp) return null
  const value = new Date(timestamp)
  if (Number.isNaN(value.getTime())) return null
  return value.toLocaleTimeString()
}

function formatEligible(seconds?: number | null): string | null {
  if (typeof seconds !== 'number' || !Number.isFinite(seconds) || seconds <= 0) return null
  if (seconds < 60) return `${Math.round(seconds)}s`
  return `${Math.ceil(seconds / 60)}m`
}

function effectiveDiagnostic(keeper: Keeper | null | undefined): KeeperDiagnostic | null {
  if (!keeper) return null
  const detail = keeperStatusDetails.value[keeper.name]
  return detail?.diagnostic ?? keeper.diagnostic ?? null
}

export function KeeperDiagnosticSummary({
  keeper,
  showRawStatus = false,
}: {
  keeper: Keeper | null | undefined
  showRawStatus?: boolean
}) {
  useEffect(() => {
    if (keeper?.name) {
      void hydrateKeeperStatus(keeper.name)
    }
  }, [keeper?.name])

  if (!keeper) {
    return html`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`
  }

  const detail = keeperStatusDetails.value[keeper.name]
  const diagnostic = effectiveDiagnostic(keeper)
  const busy = keeperHydrating.value[keeper.name]

  return html`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${diagnostic?.health_state ?? 'unknown'}</span>
        <span class="pill">${quietReasonLabel(diagnostic?.quiet_reason)}</span>
        <span class="pill">next ${nextActionLabel(diagnostic?.next_action_path ?? 'direct_message')}</span>
        ${busy ? html`<span class="pill">refreshing</span>` : null}
      </div>
      <div class="control-status-copy">
        ${diagnostic?.summary ?? 'Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state.'}
      </div>
      <div class="control-status-copy">
        Reply: ${diagnostic?.last_reply_status ?? 'unknown'}
        ${diagnostic?.last_reply_at ? html` · ${formatTime(diagnostic.last_reply_at)}` : null}
        ${diagnostic?.next_eligible_at_s ? html` · next eligible ${formatEligible(diagnostic.next_eligible_at_s)}` : null}
      </div>
      ${diagnostic?.last_error
        ? html`<div class="control-status-copy control-error-copy">${diagnostic.last_error}</div>`
        : null}
      ${showRawStatus
        ? html`<pre class="keeper-status-console">${detail?.rawText ?? 'No keeper status loaded yet.'}</pre>`
        : null}
    </div>
  `
}

export function KeeperConversationPanel({
  keeperName,
  placeholder,
}: {
  keeperName: string
  placeholder: string
}) {
  const [draft, setDraft] = useState('')

  useEffect(() => {
    if (keeperName) {
      void hydrateKeeperStatus(keeperName)
    }
  }, [keeperName])

  const thread = keeperThreads.value[keeperName] ?? []
  const sending = keeperSending.value[keeperName] ?? false
  const error = keeperActionErrors.value[keeperName]

  const submit = async () => {
    const prompt = draft.trim()
    if (!keeperName || !prompt) return
    setDraft('')
    try {
      await sendKeeperThreadMessage(keeperName, prompt)
    } catch (err) {
      const message = err instanceof Error ? err.message : `Failed to message ${keeperName}`
      showToast(message, 'error')
    }
  }

  return html`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${thread.length === 0
          ? html`<div class="control-status-copy">No direct keeper conversation yet.</div>`
          : thread.map(entry => html`
              <div class="keeper-conversation-item" key=${entry.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${chipClass(entry)}`}>${entry.label}</span>
                  <span class=${`keeper-role-chip ${chipClass(entry)}`}>${deliveryLabel(entry)}</span>
                  ${entry.timestamp ? html`<span class="keeper-conversation-time">${formatTime(entry.timestamp)}</span>` : null}
                </div>
                <div class="keeper-conversation-text">${entry.text}</div>
                ${entry.error ? html`<div class="keeper-conversation-error">${entry.error}</div>` : null}
              </div>
            `)}
      </div>
      <div class="keeper-conversation-compose">
        <textarea
          class="control-textarea"
          placeholder=${placeholder}
          value=${draft}
          onInput=${(event: Event) => { setDraft((event.target as HTMLTextAreaElement).value) }}
          disabled=${sending || !keeperName}
        ></textarea>
        <div class="control-actions">
          <button
            class="control-btn"
            onClick=${() => { void submit() }}
            disabled=${sending || draft.trim() === '' || !keeperName}
          >
            ${sending ? 'Waiting...' : 'Send Direct Message'}
          </button>
        </div>
        ${error ? html`<div class="control-status-copy control-error-copy">${error}</div>` : null}
      </div>
    </div>
  `
}

export function KeeperRuntimeActions({
  actor,
  keeper,
  onPokeLodge,
}: {
  actor: string
  keeper: Keeper | null | undefined
  onPokeLodge: () => void
}) {
  if (!keeper) return null
  const diagnostic = effectiveDiagnostic(keeper)
  const probing = keeperProbing.value[keeper.name] ?? false
  const recovering = keeperRecovering.value[keeper.name] ?? false
  const recommended = diagnostic?.next_action_path ?? 'direct_message'

  return html`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${recommended === 'probe' ? 'is-active' : ''}`}
        onClick=${() => {
          void probeKeeperRuntime(keeper.name, actor).catch(err => {
            const message = err instanceof Error ? err.message : `Failed to probe ${keeper.name}`
            showToast(message, 'error')
          })
        }}
        disabled=${probing || !actor.trim()}
      >
        ${probing ? 'Probing...' : 'Probe'}
      </button>
      <button
        class=${`control-btn secondary ${recommended === 'recover' ? 'is-active' : ''}`}
        onClick=${() => {
          void recoverKeeperRuntime(keeper.name, actor).catch(err => {
            const message = err instanceof Error ? err.message : `Failed to recover ${keeper.name}`
            showToast(message, 'error')
          })
        }}
        disabled=${recovering || !diagnostic?.recoverable || !actor.trim()}
      >
        ${recovering ? 'Recovering...' : 'Recover'}
      </button>
      <button
        class=${`control-btn ghost ${recommended === 'manual_lodge_poke' ? 'is-active' : ''}`}
        onClick=${onPokeLodge}
      >
        Poke Lodge
      </button>
    </div>
  `
}
