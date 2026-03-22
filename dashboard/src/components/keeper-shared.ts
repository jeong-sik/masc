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
      return '소셜 스윕 실행'
    case 'probe':
      return '프로브'
    case 'recover':
      return '복구'
    default:
      return '메시지'
  }
}

function continuityStateLabel(state?: KeeperDiagnostic['continuity_state']): string | null {
  switch (state) {
    case 'healthy':
      return '정상'
    case 'recovering':
      return '복구 중'
    case 'desired_offline':
      return '의도적 오프라인'
    case 'offline':
      return '오프라인'
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
    return html`<div class="control-status-copy text-[#d5e5fb] text-[length:var(--fs-sm)] leading-[1.5]">Select a keeper to inspect direct reply state.</div>`
  }

  const detail = keeperStatusDetails.value[keeper.name]
  const diagnostic = effectiveDiagnostic(keeper)
  const busy = keeperHydrating.value[keeper.name]

  return html`
    <div class="py-[10px] px-3 rounded-[10px] border border-solid border-[rgba(138,163,211,0.24)] bg-[rgba(5,14,31,0.55)]">
      <div class="control-inline-meta flex flex-wrap gap-1.5">
        ${continuityStateLabel(diagnostic?.continuity_state)
          ? html`<span class="pill rounded-full">${continuityStateLabel(diagnostic?.continuity_state)}</span>`
          : null}
        <span class="pill rounded-full">${diagnostic?.health_state ?? 'unknown'}</span>
        <span class="pill rounded-full">${quietReasonLabel(diagnostic?.quiet_reason)}</span>
        <span class="pill rounded-full">next ${nextActionLabel(diagnostic?.next_action_path ?? 'direct_message')}</span>
        ${busy ? html`<span class="pill rounded-full">refreshing</span>` : null}
      </div>
      <div class="control-status-copy text-[#d5e5fb] text-[length:var(--fs-sm)] leading-[1.5]">
        ${diagnostic?.continuity_summary
          ?? diagnostic?.summary
          ?? 'Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state.'}
      </div>
      <div class="control-status-copy text-[#d5e5fb] text-[length:var(--fs-sm)] leading-[1.5]">
        Reply: ${diagnostic?.last_reply_status ?? 'unknown'}
        ${diagnostic?.last_reply_at ? html` · ${formatTime(diagnostic.last_reply_at)}` : null}
        ${diagnostic?.next_eligible_at_s ? html` · next eligible ${formatEligible(diagnostic.next_eligible_at_s)}` : null}
      </div>
      ${diagnostic?.last_error
        ? html`<div class="control-status-copy text-[#ffb4b4] text-[length:var(--fs-sm)] leading-[1.5]">${diagnostic.last_error}</div>`
        : null}
      ${showRawStatus
        ? html`<pre class="mt-2 py-[10px] px-3 rounded-[10px] border border-solid border-[var(--card-border)] bg-[rgba(2,10,24,0.82)] text-[#9ad8b6] text-[length:var(--fs-sm)] leading-[1.55] whitespace-pre-wrap break-words font-[family:'Fira_Code',monospace] max-h-[240px] overflow-auto">${detail?.rawText ?? 'No keeper status loaded yet.'}</pre>`
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
  // Filter out system/tool messages — only show user and assistant conversation
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
    <div class="keeper-conversation-shell flex flex-col gap-2.5">
      <div class="flex justify-end">
        <button
          type="button"
          class="control-btn rounded-lg ghost"
          onClick=${() => { setShowMetadata(!showMetadata) }}
        >
          ${showMetadata ? '메타 숨기기' : '메타 표시'}
        </button>
      </div>
      <${ChatTranscript}
        entries=${thread}
        emptyText="아직 직접 대화 기록이 없습니다."
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
      ${error ? html`<div class="control-status-copy text-[#ffb4b4] text-[length:var(--fs-sm)] leading-[1.5]">${error}</div>` : null}
    </div>
  `
}

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

  return html`
    <div class="control-actions flex flex-wrap gap-1.5">
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
        ${probing ? '프로브 중...' : '프로브'}
      </button>
      <button
        class=${`control-btn secondary ${recommended === 'recover' ? 'is-active' : ''}`}
        onClick=${() => {
          void recoverKeeperRuntime(keeper.name, actor).catch(err => {
            const message = err instanceof Error ? err.message : `Failed to recover ${keeper.name}`
            showToast(message, 'error')
          })
        }}
        disabled=${recovering || !canRecover || !actor.trim()}
      >
        ${recovering ? '복구 중...' : '복구'}
      </button>
      <button
        class=${`control-btn ghost ${recommended === 'manual_social_sweep' ? 'is-active' : ''}`}
        onClick=${onSocialSweep}
      >
        소셜 스윕 실행
      </button>
    </div>
  `
}
