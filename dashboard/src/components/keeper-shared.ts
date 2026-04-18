import { html } from 'htm/preact'
import { Markdown } from "./common/markdown"
import { useState } from 'preact/hooks'
import { keeperDirectChatAccess } from '../lib/keeper-chat-access'
import { relativeTime } from '../lib/format-time'
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
import { shellAuthSummary } from '../store'


const KEEPER_CHAT_METADATA_VISIBLE_KEY = 'masc_keeper_chat_metadata_visible'
const KEEPER_CHAT_INTERNAL_VISIBLE_KEY = 'masc_keeper_chat_internal_visible'

function readKeeperChatMetadataVisible(): boolean {
  try {
    const stored = localStorage.getItem(KEEPER_CHAT_METADATA_VISIBLE_KEY)
    return stored === null ? false : stored === 'true'
  } catch {
    return false
  }
}

function writeKeeperChatMetadataVisible(value: boolean): void {
  try {
    localStorage.setItem(KEEPER_CHAT_METADATA_VISIBLE_KEY, value ? 'true' : 'false')
  } catch {}
}

function readKeeperChatInternalVisible(): boolean {
  try {
    const stored = localStorage.getItem(KEEPER_CHAT_INTERNAL_VISIBLE_KEY)
    return stored === null ? true : stored === 'true'
  } catch {
    return true
  }
}

function writeKeeperChatInternalVisible(value: boolean): void {
  try {
    localStorage.setItem(KEEPER_CHAT_INTERNAL_VISIBLE_KEY, value ? 'true' : 'false')
  } catch {}
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
    case 'disabled':
      return 'disabled'
    case 'not_running':
      return 'not running'
    case 'offline':
      return 'offline'
    default:
      return null
  }
}

// Delegated to lib/format-time (SSOT) — returns Korean relative time
function formatTime(timestamp?: string | null): string | null {
  if (!timestamp) return null
  const result = relativeTime(timestamp)
  return result === '정보 없음' ? null : result
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
    return 'border-[var(--ok-20)] bg-[var(--ok-10)] text-[var(--ok-20)]'
  }
  if (hydrating) {
    return 'border-[var(--accent-20)] bg-[var(--accent-10)] text-[var(--text-strong)]'
  }
  return 'border-[rgba(148,163,184,0.18)] bg-[var(--slate-gray-8)] text-[var(--text-body)]'
}

function effectiveDiagnostic(keeper: Keeper | null | undefined): KeeperDiagnostic | null {
  if (!keeper) return null
  const detail = keeperStatusDetails.value[keeper.name]
  return detail?.diagnostic ?? keeper.diagnostic ?? null
}

// ── Diagnostic chip ──────────────────────────────────────

function DiagChip({ label }: { label: string }) {
  return html`
    <span class="inline-flex items-center py-0.5 px-2 rounded-sm text-3xs font-medium bg-[var(--accent-12)] text-[var(--accent)] border border-[var(--accent-30)]">${label}</span>
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
  if (!keeper) {
    return html`<div class="text-xs text-[var(--text-muted)] leading-relaxed py-2">키퍼를 선택하여 직접 응답 상태를 확인하세요.</div>`
  }

  const detail = keeperStatusDetails.value[keeper.name]
  const diagnostic = effectiveDiagnostic(keeper)
  const busy = keeperHydrating.value[keeper.name]
  const refreshStatus = async () => {
    try {
      await hydrateKeeperStatus(keeper.name, true)
    } catch (err) {
      const message = err instanceof Error ? err.message : `Failed to inspect ${keeper.name}`
      showToast(message, 'error')
    }
  }

  return html`
    <div class="py-3 px-4 rounded border border-[var(--card-border)] bg-[rgba(5,14,31,0.55)]">
      <div class="mb-3 flex items-center justify-between gap-3">
        <div class="text-2xs font-semibold uppercase tracking-[0.14em] text-[var(--text-muted)]">명시적 상태 조회</div>
        <button
          type="button"
          class="rounded border border-[var(--card-border)] bg-[var(--white-3)] px-3 py-1.5 text-2xs text-[var(--text-muted)] transition-colors hover:bg-[var(--white-6)] hover:text-[var(--text-body)]"
          disabled=${busy}
          onClick=${() => { void refreshStatus() }}
        >
          ${busy ? '불러오는 중...' : (detail ? '상태 새로고침' : '상태 불러오기')}
        </button>
      </div>
      <div class="flex flex-wrap gap-1.5 mb-2">
        ${continuityStateLabel(diagnostic?.continuity_state)
          ? html`<${DiagChip} label=${continuityStateLabel(diagnostic?.continuity_state)} />`
          : null}
        ${diagnostic?.health_state
          ? html`<${DiagChip} label=${diagnostic.health_state} />`
          : null}
        ${diagnostic?.quiet_reason
          ? html`<${DiagChip} label=${quietReasonLabel(diagnostic.quiet_reason)} />`
          : null}
        ${diagnostic?.next_action_path
          ? html`<${DiagChip} label=${'next: ' + nextActionLabel(diagnostic.next_action_path)} />`
          : null}
        ${busy ? html`<${DiagChip} label="refreshing" />` : null}
      </div>
      <div class="text-xs text-[var(--text-body)] leading-relaxed">
        ${diagnostic?.continuity_summary
          ?? diagnostic?.summary
          ?? '자동 판단 필드는 기본으로 채우지 않습니다. 필요할 때만 상태를 불러오세요.'}
      </div>
      <div class="text-xs text-[var(--text-body)] leading-relaxed mt-1">
        응답: ${diagnostic?.last_reply_status ?? '미조회'}
        ${diagnostic?.last_reply_at ? html` -- ${formatTime(diagnostic.last_reply_at)}` : null}
        ${diagnostic?.next_eligible_at_s ? html` -- 다음 응답 가능 ${formatEligible(diagnostic.next_eligible_at_s)}` : null}
      </div>
      ${diagnostic?.last_error
        ? html`<div class="text-xs text-[var(--bad-light)] leading-relaxed mt-1">${diagnostic.last_error}</div>`
        : null}
      ${showRawStatus
        ? html`<div class="mt-3 max-h-60 overflow-auto rounded border border-[var(--card-border)] bg-[var(--bg-0)] custom-scrollbar"><${Markdown} text=${'```text\n' + (detail?.rawText ?? '키퍼 상태를 아직 불러오지 않았습니다.') + '\n```'} /></div>`
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
  const [showInternal, setShowInternal] = useState(readKeeperChatInternalVisible())

  const toggleMetadata = () => {
    setShowMetadata(prev => {
      const next = !prev
      writeKeeperChatMetadataVisible(next)
      return next
    })
  }
  const toggleInternal = () => {
    setShowInternal(prev => {
      const next = !prev
      writeKeeperChatInternalVisible(next)
      return next
    })
  }

  const [historyExpanded, setHistoryExpanded] = useState(false)
  const rawThread = keeperThreads.value[keeperName] ?? []
  const thread = showInternal ? rawThread : rawThread.filter(isVisibleDirectConversationEntry)
  const hiddenCount = rawThread.length - thread.length
  const sending = keeperSending.value[keeperName] ?? false
  const hydrating = keeperHydrating.value[keeperName] ?? false
  const error = keeperActionErrors.value[keeperName]
  const chatAccess = keeperDirectChatAccess(shellAuthSummary.value)
  const composerDisabled = !keeperName || chatAccess.blocked

  const expandHistory = async () => {
    setHistoryExpanded(true)
    await loadFullKeeperHistory(keeperName)
  }

  const submit = async () => {
    const prompt = draft.trim()
    if (chatAccess.blocked) {
      showToast(chatAccess.message ?? '직접 통신 권한이 없습니다.', 'error')
      return
    }
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
      <div class="overflow-hidden rounded-[var(--radius-xl)] border border-[var(--card-border)] bg-[linear-gradient(180deg,rgba(9,15,28,0.96),rgba(5,10,20,0.94))] shadow-[0_24px_56px_rgba(0,0,0,0.28)]">
        <div class="flex flex-wrap items-start justify-between gap-3 border-b border-[var(--slate-gray-12)] px-4 py-4">
          <div class="min-w-55 flex-1">
            <div class="text-2xs font-semibold uppercase tracking-[0.16em] text-[var(--text-muted)]">직접 대화</div>
            <div class="mt-2 flex flex-wrap items-center gap-2">
              <div class="text-md font-semibold text-[var(--text-strong)]">@${keeperName}</div>
              <span class=${`inline-flex items-center rounded-sm border px-2.5 py-1 text-3xs font-medium uppercase tracking-[0.1em] ${conversationStateClass(sending, hydrating)}`}>
                ${conversationStateLabel(sending, hydrating)}
              </span>
            </div>
            <div class="mt-1 text-sm leading-[1.65] text-[var(--text-secondary)]">
              Keeper 상세 안에서 직접 대화와 내부 메시지를 함께 봅니다. 필요하면 토글로 내부 프롬프트와 tool chatter를 숨길 수 있습니다.
            </div>
          </div>
          <div class="flex flex-wrap items-center gap-2">
            <button
              type="button"
              class="rounded border border-[var(--card-border)] bg-[var(--white-3)] px-3 py-1.5 text-2xs text-[var(--text-muted)] transition-colors hover:bg-[var(--white-6)] hover:text-[var(--text-body)]"
              onClick=${toggleMetadata}
            >
              ${showMetadata ? '메타데이터 숨김' : '메타데이터 표시'}
            </button>
            <button
              type="button"
              class="rounded border border-[var(--card-border)] bg-[var(--white-3)] px-3 py-1.5 text-2xs text-[var(--text-muted)] transition-colors hover:bg-[var(--white-6)] hover:text-[var(--text-body)] ${showInternal ? 'border-[rgba(167,139,250,0.3)] text-[var(--purple)]' : ''}"
              onClick=${toggleInternal}
            >
              ${showInternal ? '내부 메시지 숨김' : '내부 메시지 표시'}
            </button>
            ${!historyExpanded
              ? html`
                  <button
                    type="button"
                    class="rounded border border-[var(--card-border)] bg-[var(--white-3)] px-3 py-1.5 text-2xs text-[var(--text-muted)] transition-colors hover:bg-[var(--white-6)] hover:text-[var(--text-body)]"
                    disabled=${hydrating}
                    onClick=${() => { void expandHistory() }}
                  >
                    ${hydrating
                      ? '불러오는 중...'
                      : rawThread.length === 0
                        ? '대화 이력 불러오기'
                        : `전체 이력 불러오기 (직접 대화 ${thread.length}건 표시 중)`}
                  </button>
                `
              : null}
          </div>
        </div>

        <div class="px-4 py-4">
          ${chatAccess.message
            ? html`
                <div class="mb-4 rounded-[16px] border border-[var(--warn-20)] bg-[var(--warn-10)] px-3 py-2.5 text-xs leading-[1.6] text-[var(--warn-bright)]">
                  ${chatAccess.message}
                </div>
              `
            : null}
          <${ChatTranscript}
            entries=${thread}
            emptyText="아직 표시할 대화가 없습니다. 내부 메시지와 도구 호출은 토글로 전환할 수 있습니다."
            showMetadata=${showMetadata}
            variant="messenger"
          />
        </div>

        ${!showInternal && hiddenCount > 0
          ? html`
              <div class="mx-4 mb-4 rounded-[16px] border border-[var(--warn-20)] bg-[var(--warn-10)] px-3 py-2 text-2xs leading-[1.55] text-[var(--warn-bright)]">
                ${hiddenCount}개의 내부 메시지가 숨겨져 있습니다. "내부 메시지 표시"로 볼 수 있습니다.
              </div>
            `
          : null}

        <div class="border-t border-[var(--slate-gray-12)] bg-[var(--white-3)] px-4 py-4">
          <${ChatComposer}
            draft=${draft}
            placeholder=${chatAccess.blocked ? '현재 actor는 direct keeper chat 권한이 없습니다' : placeholder}
            disabled=${composerDisabled}
            streaming=${sending}
            streamStartedAt=${keeperStreamStartedAt.value[keeperName] ?? null}
            onDraftChange=${setDraft}
            onSend=${() => { void submit() }}
            onAbort=${() => { abortKeeperThreadMessage(keeperName) }}
          />
        </div>
      </div>

      ${error ? html`<div class="text-xs text-[var(--bad-light)] leading-relaxed">${error}</div>` : null}
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
  const recommended = diagnostic?.next_action_path ?? null
  const canRecover = diagnostic?.recoverable === true

  const btnBase = 'py-1.5 px-4 rounded text-xs font-medium cursor-pointer transition-colors border'
  const ghostBtn = `${btnBase} border-[var(--card-border)] bg-[var(--white-3)] text-[var(--text-muted)] hover:bg-[var(--white-6)] hover:text-[var(--text-body)]`
  const activeGhostBtn = `${btnBase} border-[rgba(71,184,255,0.4)] bg-[var(--accent-12)] text-[var(--accent)] hover:bg-[var(--accent-20)]`
  const secondaryBtn = `${btnBase} border-[rgba(251,191,36,0.3)] bg-[var(--warn-10)] text-[var(--warn)] hover:bg-[var(--warn-soft)]`
  const activeSecondaryBtn = `${btnBase} border-[rgba(251,191,36,0.5)] bg-[var(--warn-soft)] text-[var(--warn)] hover:bg-[var(--warn-20)]`

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
