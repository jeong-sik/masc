import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import type { Keeper, KeeperDiagnostic } from '../types'
import {
  abortKeeperThreadMessage,
  hydrateKeeperStatus,
  loadFullKeeperHistory,
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
import { isVisibleDirectConversationEntry } from '../keeper-state'
import { ChatComposer, ChatTranscript } from './chat/primitives'
import { showToast } from './common/toast'

const KEEPER_CHAT_METADATA_VISIBLE_KEY = 'masc_keeper_chat_metadata_visible'

function readKeeperChatMetadataVisible(): boolean {
  try {
    const stored = localStorage.getItem(KEEPER_CHAT_METADATA_VISIBLE_KEY)
    // Default to visible (true) when no preference is stored
    return stored === null ? true : stored === 'true'
  } catch {
    return true
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

function conversationStateLabel(sending: boolean, hydrating: boolean): string {
  if (sending) return 'live reply'
  if (hydrating) return 'syncing history'
  return 'ready'
}

function conversationStateClass(sending: boolean, hydrating: boolean): string {
  if (sending) {
    return 'border-[rgba(76,181,137,0.26)] bg-[rgba(76,181,137,0.12)] text-[#b9f1d1]'
  }
  if (hydrating) {
    return 'border-[rgba(71,184,255,0.26)] bg-[rgba(71,184,255,0.12)] text-[#bfe8ff]'
  }
  return 'border-[rgba(148,163,184,0.18)] bg-[rgba(148,163,184,0.08)] text-[var(--text-body)]'
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

  const [historyExpanded, setHistoryExpanded] = useState(false)
  const rawThread = keeperThreads.value[keeperName] ?? []
  const thread = rawThread.filter(isVisibleDirectConversationEntry)
  const hiddenHistoryCount = rawThread.filter(
    entry => entry.delivery === 'history' && !isVisibleDirectConversationEntry(entry),
  ).length
  const sending = keeperSending.value[keeperName] ?? false
  const hydrating = keeperHydrating.value[keeperName] ?? false
  const error = keeperActionErrors.value[keeperName]

  const expandHistory = async () => {
    setHistoryExpanded(true)
    await loadFullKeeperHistory(keeperName)
  }

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
      <div class="rounded-[22px] border border-[var(--card-border)] bg-[linear-gradient(180deg,rgba(12,20,38,0.96),rgba(8,13,24,0.9))] px-4 py-4 shadow-[0_18px_48px_rgba(0,0,0,0.22)]">
        <div class="flex flex-wrap items-start justify-between gap-3">
          <div class="min-w-[220px] flex-1">
            <div class="text-[11px] font-semibold uppercase tracking-[0.16em] text-[var(--text-muted)]">Conversation Lane</div>
            <div class="mt-2 text-[16px] font-semibold text-[var(--text-strong)]">Direct messages only</div>
            <div class="mt-1 text-[13px] leading-[1.65] text-[var(--text-secondary)]">
              This panel is for explicit operator-to-keeper conversation. Internal world-state prompts, tool chatter, and keeper self-deliberation are hidden on purpose.
            </div>
          </div>
          <div class="flex flex-wrap items-center gap-2 text-[11px]">
            <button
              type="button"
              class="rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] px-3 py-1.5 text-[11px] text-[var(--text-muted)] transition-colors hover:bg-[var(--white-6)] hover:text-[var(--text-body)]"
              onClick=${() => { setShowMetadata(!showMetadata) }}
            >
              ${showMetadata ? 'Hide metadata' : 'Show metadata'}
            </button>
          </div>
        </div>

        <div class="mt-4 grid grid-cols-1 gap-2 sm:grid-cols-3">
          <div class="rounded-[18px] border border-[rgba(71,184,255,0.18)] bg-[rgba(71,184,255,0.08)] px-3 py-3">
            <div class="text-[10px] font-semibold uppercase tracking-[0.14em] text-[#9ad9ff]">Visible thread</div>
            <div class="mt-1 text-[22px] font-semibold text-[var(--text-strong)]">${thread.length}</div>
            <div class="mt-1 text-[12px] leading-[1.55] text-[var(--text-secondary)]">Direct user prompts and keeper replies currently shown.</div>
          </div>
          <div class="rounded-[18px] border border-[rgba(245,158,11,0.2)] bg-[rgba(245,158,11,0.08)] px-3 py-3">
            <div class="text-[10px] font-semibold uppercase tracking-[0.14em] text-[#f5d089]">Hidden internal</div>
            <div class="mt-1 text-[22px] font-semibold text-[var(--text-strong)]">${hiddenHistoryCount}</div>
            <div class="mt-1 text-[12px] leading-[1.55] text-[var(--text-secondary)]">System prompts and internal reasoning omitted from the conversation lane.</div>
          </div>
          <div class="rounded-[18px] border border-[rgba(148,163,184,0.14)] bg-[rgba(255,255,255,0.04)] px-3 py-3">
            <div class="text-[10px] font-semibold uppercase tracking-[0.14em] text-[var(--text-muted)]">Lane state</div>
            <div class="mt-2">
              <span class=${`inline-flex items-center rounded-full border px-2.5 py-1 text-[11px] font-medium uppercase tracking-[0.1em] ${conversationStateClass(sending, hydrating)}`}>
                ${conversationStateLabel(sending, hydrating)}
              </span>
            </div>
            <div class="mt-2 text-[12px] leading-[1.55] text-[var(--text-secondary)]">
              ${sending
                ? 'A keeper reply is currently streaming.'
                : hydrating
                  ? 'History is being refreshed from keeper status.'
                  : 'Direct message lane is ready for a new prompt.'}
            </div>
          </div>
        </div>
      </div>

      <div class="overflow-hidden rounded-[24px] border border-[var(--card-border)] bg-[linear-gradient(180deg,rgba(9,15,28,0.94),rgba(5,10,20,0.9))] shadow-[0_24px_56px_rgba(0,0,0,0.28)]">
        <div class="flex flex-wrap items-start justify-between gap-3 border-b border-[rgba(148,163,184,0.12)] px-4 py-4">
          <div class="min-w-[220px] flex-1">
            <div class="text-[11px] font-semibold uppercase tracking-[0.16em] text-[var(--text-muted)]">Transcript</div>
            <div class="mt-2 text-[15px] font-semibold text-[var(--text-strong)]">@${keeperName}</div>
            <div class="mt-1 text-[13px] leading-[1.65] text-[var(--text-secondary)]">
              Recent direct exchange with the keeper, separated from internal control prompts.
            </div>
          </div>
          <div class="flex flex-wrap items-center gap-2">
            ${!historyExpanded && rawThread.length >= 10
              ? html`
                  <button
                    type="button"
                    class="rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] px-3 py-1.5 text-[11px] text-[var(--text-muted)] transition-colors hover:bg-[var(--white-6)] hover:text-[var(--text-body)]"
                    disabled=${hydrating}
                    onClick=${() => { void expandHistory() }}
                  >
                    ${hydrating ? 'Loading...' : `Load full history (${thread.length} direct shown)`}
                  </button>
                `
              : null}
          </div>
        </div>

        <div class="px-4 py-4">
          <${ChatTranscript}
            entries=${thread}
            emptyText="No direct conversation yet. Internal keeper prompts and tool chatter are hidden."
            showMetadata=${showMetadata}
          />
        </div>

        ${hiddenHistoryCount > 0
          ? html`
              <div class="mx-4 mb-4 rounded-[18px] border border-[rgba(245,158,11,0.18)] bg-[rgba(245,158,11,0.08)] px-3 py-2.5 text-[12px] leading-[1.6] text-[#f4d79e]">
                ${hiddenHistoryCount} internal history entries are hidden from this transcript to keep the conversation readable. Raw status and metadata still retain those traces for debugging.
              </div>
            `
          : null}

        <div class="border-t border-[rgba(148,163,184,0.12)] bg-[rgba(255,255,255,0.03)] px-4 py-4">
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
        </div>
      </div>

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
      <button type="button"
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
      <button type="button"
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
      <button type="button"
        class=${recommended === 'manual_social_sweep' ? activeGhostBtn : ghostBtn}
        onClick=${onSocialSweep}
      >
        Social sweep
      </button>
    </div>
  `
}
