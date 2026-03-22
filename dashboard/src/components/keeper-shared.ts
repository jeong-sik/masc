import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import type { Keeper, KeeperDiagnostic } from '../types'
import {
  abortKeeperThreadMessage,
  hydrateKeeperStatus,
  keeperActionErrors,
  keeperHydrating,
  keeperProbing,
  keeperRecovering,
  keeperSending,
  keeperStatusDetails,
  keeperStreamStartedAt,
  keeperThreads,
  probeKeeperRuntime,
  recoverKeeperRuntime,
  sendKeeperThreadMessage,
} from '../keeper-runtime'
import { ChatComposer, ChatTranscript } from './chat/primitives'
import { showToast } from './common/toast'

const KEEPER_CHAT_METADATA_VISIBLE_KEY = 'masc_keeper_chat_metadata_visible'

function readKeeperChatMetadataVisible(): boolean {
  try {
    return localStorage.getItem(KEEPER_CHAT_METADATA_VISIBLE_KEY) === 'true'
  } catch {
    return false
  }
}

function writeKeeperChatMetadataVisible(value: boolean): void {
  try {
    localStorage.setItem(KEEPER_CHAT_METADATA_VISIBLE_KEY, value ? 'true' : 'false')
  } catch {
    // Ignore persistence failures.
  }
}

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
    case 'model_error':
      return 'model error'
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
    case 'manual_social_sweep':
      return 'social sweep'
    case 'probe':
      return 'probe'
    case 'recover':
      return 'recover'
    default:
      return 'message'
  }
}

function continuityStateLabel(state?: KeeperDiagnostic['continuity_state']): string | null {
  switch (state) {
    case 'healthy':
      return 'healthy'
    case 'recovering':
      return 'recovering'
    case 'desired_offline':
      return 'desired offline'
    case 'offline':
      return 'offline'
    default:
      return null
  }
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

// ── Diagnostic chip ──────────────────────────────────────

function DiagChip({ label }: { label: string }) {
  return html`
    <span class="inline-flex items-center py-0.5 px-2 rounded-full text-[10px] font-medium bg-[var(--accent-12)] text-[#9ad9ff] border border-[rgba(71,184,255,0.25)]">${label}</span>
  `
}

// ── Diagnostic Summary ───────────────────────────────────

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
    return html`<div class="text-xs text-[var(--text-muted)] leading-relaxed py-2">Select a keeper to inspect direct reply state.</div>`
  }

  const detail = keeperStatusDetails.value[keeper.name]
  const diagnostic = effectiveDiagnostic(keeper)
  const busy = keeperHydrating.value[keeper.name]

  return html`
    <div class="py-3 px-4 rounded-xl border border-[var(--card-border)] bg-[rgba(5,14,31,0.55)]">
      <div class="flex flex-wrap gap-1.5 mb-2">
        ${continuityStateLabel(diagnostic?.continuity_state)
          ? html`<${DiagChip} label=${continuityStateLabel(diagnostic?.continuity_state)} />`
          : null}
        <${DiagChip} label=${diagnostic?.health_state ?? 'unknown'} />
        <${DiagChip} label=${quietReasonLabel(diagnostic?.quiet_reason)} />
        <${DiagChip} label=${'next: ' + nextActionLabel(diagnostic?.next_action_path ?? 'direct_message')} />
        ${busy ? html`<${DiagChip} label="refreshing" />` : null}
      </div>
      <div class="text-xs text-[var(--text-body)] leading-relaxed">
        ${diagnostic?.continuity_summary
          ?? diagnostic?.summary
          ?? 'Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state.'}
      </div>
      <div class="text-xs text-[var(--text-body)] leading-relaxed mt-1">
        Reply: ${diagnostic?.last_reply_status ?? 'unknown'}
        ${diagnostic?.last_reply_at ? html` -- ${formatTime(diagnostic.last_reply_at)}` : null}
        ${diagnostic?.next_eligible_at_s ? html` -- next eligible ${formatEligible(diagnostic.next_eligible_at_s)}` : null}
      </div>
      ${diagnostic?.last_error
        ? html`<div class="text-xs text-[#ffb4b4] leading-relaxed mt-1">${diagnostic.last_error}</div>`
        : null}
      ${showRawStatus
        ? html`<pre class="mt-3 py-3 px-4 rounded-lg border border-[var(--card-border)] bg-[rgba(2,10,24,0.82)] text-[#9ad8b6] text-[11px] leading-relaxed whitespace-pre-wrap break-words font-mono max-h-[240px] overflow-auto">${detail?.rawText ?? 'No keeper status loaded yet.'}</pre>`
        : null}
    </div>
  `
}

// ── Conversation Panel ───────────────────────────────────

export function KeeperConversationPanel({
  keeperName,
  placeholder,
}: {
  keeperName: string
  placeholder: string
}) {
  const [draft, setDraft] = useState('')
  const [showMetadata, setShowMetadata] = useState(readKeeperChatMetadataVisible())

  useEffect(() => {
    if (keeperName) {
      void hydrateKeeperStatus(keeperName)
    }
  }, [keeperName])

  useEffect(() => {
    writeKeeperChatMetadataVisible(showMetadata)
  }, [showMetadata])

  const rawThread = keeperThreads.value[keeperName] ?? []
  // Filter out system/tool messages -- only show user and assistant conversation
  const thread = rawThread.filter(
    entry => entry.role === 'user' || entry.role === 'assistant',
  )
  const sending = keeperSending.value[keeperName] ?? false
  const error = keeperActionErrors.value[keeperName]

  const submit = async () => {
    const prompt = draft.trim()
    if (!keeperName || !prompt) return
    setDraft('')
    try {
      await sendKeeperThreadMessage(keeperName, prompt)
    } catch (err) {
      if (err instanceof Error && err.name === 'AbortError') return
      const message = err instanceof Error ? err.message : `Failed to message ${keeperName}`
      showToast(message, 'error')
    }
  }

  return html`
    <div class="flex flex-col gap-3">
      <div class="flex justify-end">
        <button
          type="button"
          class="py-1 px-3 rounded-lg border border-[var(--card-border)] bg-[var(--white-3)] text-[11px] text-[var(--text-muted)] hover:bg-[var(--white-6)] hover:text-[var(--text-body)] transition-colors cursor-pointer"
          onClick=${() => { setShowMetadata(!showMetadata) }}
        >
          ${showMetadata ? 'Hide metadata' : 'Show metadata'}
        </button>
      </div>
      <${ChatTranscript}
        entries=${thread}
        emptyText="No direct conversation history yet."
        showMetadata=${showMetadata}
      />
      <${ChatComposer}
        draft=${draft}
        placeholder=${placeholder}
        disabled=${!keeperName}
        streaming=${sending}
        streamStartedAt=${keeperStreamStartedAt.value[keeperName] ?? null}
        onDraftChange=${setDraft}
        onSend=${() => { void submit() }}
        onAbort=${() => { abortKeeperThreadMessage(keeperName) }}
      />
      ${error ? html`<div class="text-xs text-[#ffb4b4] leading-relaxed">${error}</div>` : null}
    </div>
  `
}

// ── Runtime Actions ──────────────────────────────────────

export function KeeperRuntimeActions({
  actor,
  keeper,
  onSocialSweep,
}: {
  actor: string
  keeper: Keeper | null | undefined
  onSocialSweep: () => void
}) {
  if (!keeper) return null
  const diagnostic = effectiveDiagnostic(keeper)
  const probing = keeperProbing.value[keeper.name] ?? false
  const recovering = keeperRecovering.value[keeper.name] ?? false
  const recommended = diagnostic?.next_action_path ?? 'direct_message'
  const canRecover = diagnostic?.recoverable ?? recommended === 'recover'

  const btnBase = 'py-1.5 px-4 rounded-lg text-xs font-medium cursor-pointer transition-colors border'
  const ghostBtn = `${btnBase} border-[var(--card-border)] bg-[var(--white-3)] text-[var(--text-muted)] hover:bg-[var(--white-6)] hover:text-[var(--text-body)]`
  const activeGhostBtn = `${btnBase} border-[rgba(71,184,255,0.4)] bg-[var(--accent-12)] text-[#9ad9ff] hover:bg-[rgba(71,184,255,0.2)]`
  const secondaryBtn = `${btnBase} border-[rgba(251,191,36,0.3)] bg-[rgba(251,191,36,0.08)] text-[#fbbf24] hover:bg-[rgba(251,191,36,0.15)]`
  const activeSecondaryBtn = `${btnBase} border-[rgba(251,191,36,0.5)] bg-[rgba(251,191,36,0.15)] text-[#fbbf24] hover:bg-[rgba(251,191,36,0.2)]`

  return html`
    <div class="flex flex-wrap gap-2">
      <button
        class=${recommended === 'probe' ? activeGhostBtn : ghostBtn}
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
        class=${recommended === 'recover' ? activeSecondaryBtn : secondaryBtn}
        onClick=${() => {
          void recoverKeeperRuntime(keeper.name, actor).catch(err => {
            const message = err instanceof Error ? err.message : `Failed to recover ${keeper.name}`
            showToast(message, 'error')
          })
        }}
        disabled=${recovering || !canRecover || !actor.trim()}
      >
        ${recovering ? 'Recovering...' : 'Recover'}
      </button>
      <button
        class=${recommended === 'manual_social_sweep' ? activeGhostBtn : ghostBtn}
        onClick=${onSocialSweep}
      >
        Social sweep
      </button>
    </div>
  `
}
