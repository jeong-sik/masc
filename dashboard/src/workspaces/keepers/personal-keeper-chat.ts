/**
 * Multi-Account Personal Keeper Conversation & Synchronous Turn Panel.
 *
 * Uses strictly the 4 conversation/turn routes mounted in Multi-Account mode:
 * - `GET /api/v1/auth/keepers/conversation?keeper_id=...[&conversation_id=...]`
 * - `POST /api/v1/auth/keepers/conversation`
 * - `POST /api/v1/auth/keepers/turn`
 * - `DELETE /api/v1/auth/keepers/conversation/<id>`
 *
 * All mutations settle synchronously via HTTP and re-read the authoritative
 * conversation record; live observer events from `GET /api/v1/auth/events`
 * supplement status without blocking or replacing HTTP state.
 */

import { html } from 'htm/preact'
import { useCallback, useEffect, useRef, useState } from 'preact/hooks'
import { InlineSpinner } from '../../components/common/inline-spinner'
import { MarkdownContent } from '../../components/common/markdown-renderer'
import { authSession, currentSessionEpoch, isEpochCurrent } from '../../core/auth'
import { pushShellToast } from '../../shell/shell-state'
import {
  deletePersonalConversationApi,
  fetchPersonalConversationApi,
  formatPersonalKeeperError,
  formatPersonalTurnFailure,
  formatVendorCopyOutcome,
  PERSONAL_KEEPER_MESSAGE_MAX_BYTES,
  sendPersonalKeeperTurnApi,
  startPersonalConversationApi,
  utf8ByteLength,
  validatePersonalTurnMessage,
  type PersonalConversationData,
  type PersonalConversationSummary,
  type PersonalKeeper,
  type PersonalKeeperObserverSignal,
  type PersonalRuntimeOption,
} from './personal-keepers-wire'

export interface PersonalKeeperChatPanelProps {
  readonly keeper: PersonalKeeper
  readonly assignedRuntime: PersonalRuntimeOption | null
  readonly observerSignal: PersonalKeeperObserverSignal | null
  readonly externalRefreshTick: number
  readonly onNavigate: (path: string) => void
}

interface EphemeralTurnReply {
  readonly message: string
  readonly text: string
  readonly model: string
  readonly runtimeId: string
  readonly atMs: number
}

function formatMsTimestamp(ms: number): string {
  const date = new Date(ms)
  if (Number.isNaN(date.getTime())) return String(ms)
  return date.toLocaleString([], {
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  })
}

function shortConvId(id: string): string {
  return id.length > 12 ? `${id.slice(0, 10)}…` : id
}

export function PersonalKeeperChatPanel(props: PersonalKeeperChatPanelProps) {
  const { keeper, assignedRuntime, observerSignal, externalRefreshTick } = props
  const [selectedConversationId, setSelectedConversationId] = useState<string | null>(null)
  const [conversation, setConversation] = useState<PersonalConversationData | null>(null)
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState<string | null>(null)

  const [draft, setDraft] = useState('')
  const [sendingMessage, setSendingMessage] = useState<string | null>(null)
  const [startingConv, setStartingConv] = useState(false)
  const [confirmDeleteId, setConfirmDeleteId] = useState<string | null>(null)
  const [deletingId, setDeletingId] = useState<string | null>(null)
  const [actionError, setActionError] = useState<string | null>(null)
  const [ephemeralReply, setEphemeralReply] = useState<EphemeralTurnReply | null>(null)

  const mountedRef = useRef(true)
  const activeKeeperRef = useRef(keeper.keeper_id)
  const readAbortRef = useRef<AbortController | null>(null)
  const mutAbortRef = useRef<AbortController | null>(null)
  const mutInFlightRef = useRef(false)
  const sendingRef = useRef(false)
  const latestExternalTickRef = useRef(externalRefreshTick)
  const lastHandledTickRef = useRef(externalRefreshTick)
  const selectedConversationIdRef = useRef<string | null>(selectedConversationId)
  activeKeeperRef.current = keeper.keeper_id
  sendingRef.current = mutInFlightRef.current || sendingMessage !== null || startingConv || deletingId !== null
  latestExternalTickRef.current = externalRefreshTick
  selectedConversationIdRef.current = selectedConversationId

  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
      readAbortRef.current?.abort('unmount')
      mutAbortRef.current?.abort('unmount')
    }
  }, [])

  const loadConversation = useCallback(async (targetConversationId: string | null) => {
    if (authSession.peek().kind !== 'multi_account_signed_in') return
    readAbortRef.current?.abort('superseded')
    const ctrl = new AbortController()
    readAbortRef.current = ctrl
    const targetKeeper = keeper.keeper_id
    const startEpoch = currentSessionEpoch()
    setLoading(true)
    setLoadError(null)
    const res = await fetchPersonalConversationApi(targetKeeper, targetConversationId, ctrl.signal)
    if (
      !mountedRef.current
      || activeKeeperRef.current !== targetKeeper
      || !isEpochCurrent(startEpoch)
      || ctrl.signal.aborted
      || authSession.peek().kind !== 'multi_account_signed_in'
    ) {
      return
    }
    setLoading(false)
    if (!res.ok) {
      if (res.error.kind === 'aborted' || res.error.kind === 'epoch_stale') return
      setConversation(null)
      setLoadError(formatPersonalKeeperError(res.error, 'read'))
      return
    }
    setConversation(res.value)
    setLoadError(null)
  }, [keeper.keeper_id])

  useEffect(() => {
    lastHandledTickRef.current = latestExternalTickRef.current
    selectedConversationIdRef.current = null
    setSelectedConversationId(null)
    setConversation(null)
    setLoadError(null)
    setActionError(null)
    setConfirmDeleteId(null)
    setDeletingId(null)
    setStartingConv(false)
    setSendingMessage(null)
    setEphemeralReply(null)
    mutInFlightRef.current = false
    mutAbortRef.current?.abort('keeper_changed')
    void loadConversation(null)
    return () => {
      mutInFlightRef.current = false
      readAbortRef.current?.abort('effect_cleanup')
      mutAbortRef.current?.abort('effect_cleanup')
    }
  }, [keeper.keeper_id, loadConversation])

  useEffect(() => {
    if (externalRefreshTick === lastHandledTickRef.current) return
    lastHandledTickRef.current = externalRefreshTick
    if (sendingRef.current) return
    void loadConversation(selectedConversationIdRef.current)
  }, [externalRefreshTick, loadConversation])

  const busy = sendingMessage !== null || startingConv || deletingId !== null
  const isViewingHistorical =
    selectedConversationId !== null
    && (conversation === null || selectedConversationId !== conversation.current_conversation_id)

  const handleSelectConversation = (conv: PersonalConversationSummary) => {
    if (busy || conv.deletion === 'failed') return
    const nextId =
      conversation && conv.conversation_id === conversation.current_conversation_id
        ? null
        : conv.conversation_id
    selectedConversationIdRef.current = nextId
    setSelectedConversationId(nextId)
    setActionError(null)
    setEphemeralReply(null)
    void loadConversation(nextId)
  }

  const handleStartConversation = async () => {
    if (mutInFlightRef.current || busy || authSession.peek().kind !== 'multi_account_signed_in') return
    if (keeper.runtime_id === null) {
      setActionError('먼저 상단에서 개인 런타임을 연결한 뒤 새 대화를 시작하세요.')
      return
    }
    mutInFlightRef.current = true
    mutAbortRef.current?.abort('superseded')
    const ctrl = new AbortController()
    mutAbortRef.current = ctrl
    const targetKeeper = keeper.keeper_id
    const startEpoch = currentSessionEpoch()
    setStartingConv(true)
    setActionError(null)
    setConfirmDeleteId(null)
    try {
      const res = await startPersonalConversationApi(targetKeeper, ctrl.signal)
      if (
        !mountedRef.current
        || activeKeeperRef.current !== targetKeeper
        || !isEpochCurrent(startEpoch)
        || ctrl.signal.aborted
        || authSession.peek().kind !== 'multi_account_signed_in'
      ) {
        return
      }
      setStartingConv(false)
      if (!res.ok) {
        if (res.error.kind === 'aborted' || res.error.kind === 'epoch_stale') return
        setActionError(formatPersonalKeeperError(res.error, 'start'))
        if (res.error.kind !== 'unauthorized' && res.error.kind !== 'csrf_rejected') {
          await loadConversation(selectedConversationIdRef.current)
        }
        return
      }
      selectedConversationIdRef.current = null
      setSelectedConversationId(null)
      setEphemeralReply(null)
      pushShellToast('새 대화를 시작했습니다.', 'success')
      await loadConversation(null)
    } finally {
      if (mutAbortRef.current === ctrl) {
        mutInFlightRef.current = false
        if (mountedRef.current) setStartingConv(false)
      }
    }
  }

  const handleDeleteConversation = async (conversationId: string) => {
    if (mutInFlightRef.current || busy || authSession.peek().kind !== 'multi_account_signed_in') return
    mutInFlightRef.current = true
    mutAbortRef.current?.abort('superseded')
    const ctrl = new AbortController()
    mutAbortRef.current = ctrl
    const targetKeeper = keeper.keeper_id
    const startEpoch = currentSessionEpoch()
    setDeletingId(conversationId)
    setActionError(null)
    try {
      const res = await deletePersonalConversationApi(conversationId, ctrl.signal)
      if (
        !mountedRef.current
        || activeKeeperRef.current !== targetKeeper
        || !isEpochCurrent(startEpoch)
        || ctrl.signal.aborted
        || authSession.peek().kind !== 'multi_account_signed_in'
      ) {
        return
      }
      setDeletingId(null)
      setConfirmDeleteId(null)
      if (!res.ok) {
        if (res.error.kind === 'aborted' || res.error.kind === 'epoch_stale') return
        setActionError(formatPersonalKeeperError(res.error, 'delete'))
        if (res.error.kind === 'unauthorized' || res.error.kind === 'csrf_rejected') {
          return
        }
        // Once a conversation enters Deletion_failed or Deleted on the server,
        // GET ?conversation_id=<id> returns 404 (`server_preview_keeper_conversation.ml:120-124`).
        // Fall back to the keeper's current view so the failed-deletion retry UI stays visible.
        const viewingDeletedTarget = selectedConversationIdRef.current === conversationId
        const targetMayBeUnavailable =
          res.error.code === 'conversation_not_deleted'
          || res.error.code === 'unknown_conversation'
          || res.error.kind === 'server'
          || res.error.kind === 'network'
          || res.error.kind === 'decode'
        if (viewingDeletedTarget && targetMayBeUnavailable) {
          selectedConversationIdRef.current = null
          setSelectedConversationId(null)
          await loadConversation(null)
        } else {
          await loadConversation(selectedConversationIdRef.current)
        }
        return
      }
      const nextSelected = selectedConversationIdRef.current === conversationId
        ? null
        : selectedConversationIdRef.current
      if (nextSelected !== selectedConversationIdRef.current) {
        selectedConversationIdRef.current = nextSelected
        setSelectedConversationId(nextSelected)
      }
      pushShellToast(
        formatVendorCopyOutcome(res.value.vendor_copy),
        res.value.vendor_copy === 'may_remain' ? 'info' : 'success',
      )
      await loadConversation(nextSelected)
    } finally {
      if (mutAbortRef.current === ctrl) {
        mutInFlightRef.current = false
        if (mountedRef.current) setDeletingId(null)
      }
    }
  }

  const handleSendTurn = async () => {
    if (mutInFlightRef.current || busy || isViewingHistorical || authSession.peek().kind !== 'multi_account_signed_in') return
    if (keeper.runtime_id === null) {
      setActionError('먼저 상단에서 개인 런타임을 연결하세요.')
      return
    }
    const check = validatePersonalTurnMessage(draft)
    if (!check.ok) {
      setActionError(
        check.reason === 'blank'
          ? '보낼 메시지를 입력하세요 (공백만으로는 전송할 수 없습니다).'
          : `메시지가 ${PERSONAL_KEEPER_MESSAGE_MAX_BYTES}바이트를 초과했습니다 (현재 ${check.bytes}B).`,
      )
      return
    }
    mutInFlightRef.current = true
    mutAbortRef.current?.abort('superseded')
    const ctrl = new AbortController()
    mutAbortRef.current = ctrl
    const targetKeeper = keeper.keeper_id
    const startEpoch = currentSessionEpoch()
    const messageToSend = draft
    setSendingMessage(messageToSend)
    setActionError(null)
    setConfirmDeleteId(null)

    try {
      const res = await sendPersonalKeeperTurnApi(targetKeeper, messageToSend, ctrl.signal)
      if (
        !mountedRef.current
        || activeKeeperRef.current !== targetKeeper
        || !isEpochCurrent(startEpoch)
        || ctrl.signal.aborted
        || authSession.peek().kind !== 'multi_account_signed_in'
      ) {
        return
      }
      setSendingMessage(null)
      if (!res.ok) {
        if (res.error.kind === 'aborted' || res.error.kind === 'epoch_stale') return
        setActionError(formatPersonalKeeperError(res.error, 'turn'))
        if (res.error.kind !== 'unauthorized' && res.error.kind !== 'csrf_rejected') {
          await loadConversation(null)
        }
        return
      }
      setDraft('')
      selectedConversationIdRef.current = null
      setSelectedConversationId(null)
      if (res.value.recorded) {
        setEphemeralReply(null)
      } else {
        setEphemeralReply({
          message: messageToSend,
          text: res.value.text,
          model: res.value.model,
          runtimeId: res.value.runtime_id,
          atMs: Date.now(),
        })
      }
      await loadConversation(null)
    } finally {
      if (mutAbortRef.current === ctrl) {
        mutInFlightRef.current = false
        if (mountedRef.current) setSendingMessage(null)
      }
    }
  }

  const draftBytes = utf8ByteLength(draft)
  const overByteLimit = draftBytes > PERSONAL_KEEPER_MESSAGE_MAX_BYTES
  const conversations = conversation?.conversations ?? []
  const turns = conversation?.turns ?? []

  return html`
    <div class="kp-chat-shell" data-keeper-tab="chat" data-testid="ma-keeper-chat">
      <div class="kp-chat-main">
        <!-- Conversation Toolbar -->
        <div class="kp-chat-toolbar">
          <div class="kp-pill-row">
            <span class="kp-pill" data-tone=${conversation?.conversation_id ? 'info' : 'default'}>
              ${conversation?.conversation_id
                ? `대화 ${shortConvId(conversation.conversation_id)}${isViewingHistorical ? ' (이전 기록)' : ' (현재)'}`
                : '진행 중인 대화 없음'}
            </span>
            <span class="kp-pill">전체 대화 ${conversations.length}건</span>
            ${assignedRuntime?.model && html`
              <span class="kp-pill" data-tone="brass">${assignedRuntime.model}</span>
            `}
          </div>
          <div class="kp-pill-row">
            <button
              type="button"
              class="btn-ghost"
              disabled=${busy}
              onClick=${() => void loadConversation(selectedConversationId)}
            >
              새로고침
            </button>
            <button
              type="button"
              class="btn-primary"
              data-testid="ma-new-conversation-btn"
              disabled=${busy || keeper.runtime_id === null}
              onClick=${() => void handleStartConversation()}
            >
              ${startingConv ? html`<${InlineSpinner} size="xs" /> 시작 중…` : '+ 새 대화'}
            </button>
          </div>
        </div>

        ${observerSignal && html`
          <div
            class="kp-ma-observer-strip"
            data-testid="ma-keeper-observer-signal"
            role="status"
          >
            <span class="kp-pill" data-tone="brass">LIVE /auth/events</span>
            <span class="kp-roster-sub">
              ${observerSignal.eventType}${observerSignal.keeper ? ` · ${observerSignal.keeper}` : ''} · ${observerSignal.summary}
            </span>
            ${observerSignal.textTail && html`
              <span class="kp-live-turn-tail">${observerSignal.textTail}</span>
            `}
          </div>
        `}

        ${conversations.length > 0 && html`
          <div class="kp-ma-conv-bar" role="region" aria-label="개인 Keeper 대화 목록">
            ${conversations.map((conv) => {
              const isCurrent = conv.conversation_id === conversation?.current_conversation_id
              const isActive = conv.conversation_id === conversation?.conversation_id
              const deletionFailed = conv.deletion === 'failed'
              const isConfirming = confirmDeleteId === conv.conversation_id
              const isDeleting = deletingId === conv.conversation_id
              return html`
                <div
                  key=${conv.conversation_id}
                  class="kp-ma-conv-item"
                  data-active=${isActive ? 'true' : 'false'}
                  data-failed=${deletionFailed ? 'true' : 'false'}
                  data-conversation-id=${conv.conversation_id}
                >
                  <button
                    type="button"
                    class="kp-ma-conv-select"
                    disabled=${busy || deletionFailed}
                    aria-pressed=${isActive ? 'true' : 'false'}
                    title=${`${conv.conversation_id} (${conv.provider_account_id})`}
                    onClick=${() => handleSelectConversation(conv)}
                  >
                    <span class="kp-roster-name">
                      ${shortConvId(conv.conversation_id)}
                    </span>
                    <span class="kp-roster-sub">
                      ${formatMsTimestamp(conv.started_at_ms)}
                      ${isCurrent ? ' · 현재' : ''}
                      ${deletionFailed ? ' · 삭제 실패' : ''}
                    </span>
                  </button>
                  ${isConfirming
                    ? html`
                        <div class="kp-pill-row">
                          <button
                            type="button"
                            class="kp-btn-danger"
                            data-testid=${`ma-confirm-delete-${conv.conversation_id}`}
                            disabled=${busy}
                            onClick=${() => void handleDeleteConversation(conv.conversation_id)}
                          >
                            ${isDeleting ? '삭제 중…' : '삭제 확인'}
                          </button>
                          <button
                            type="button"
                            class="btn-ghost"
                            disabled=${busy}
                            onClick=${() => setConfirmDeleteId(null)}
                          >
                            취소
                          </button>
                        </div>
                      `
                    : html`
                        <button
                          type="button"
                          class="btn-ghost kp-toggle-btn"
                          data-testid=${`ma-delete-conv-${conv.conversation_id}`}
                          disabled=${busy}
                          onClick=${() => setConfirmDeleteId(conv.conversation_id)}
                        >
                          ${deletionFailed ? '삭제 재시도' : '삭제'}
                        </button>
                      `}
                </div>
              `
            })}
          </div>
        `}

        ${isViewingHistorical && html`
          <div class="kp-notice" data-tone="info" role="status" data-testid="ma-historical-banner">
            이전 대화 기록을 읽기 전용으로 보고 있습니다. 새 메시지를 보내려면 현재 대화로 이동하세요.
            <button
              type="button"
              class="btn-ghost kp-toggle-btn"
              onClick=${() => {
                selectedConversationIdRef.current = null
                setSelectedConversationId(null)
                void loadConversation(null)
              }}
            >
              현재 대화로 이동
            </button>
          </div>
        `}

        <!-- Transcript Stage -->
        <div class="kp-chat-stage">
          <div class="kp-chat-list" aria-label="대화 기록">
            <div class="kp-chat-feed">
              ${loading && !conversation && html`
                <div class="kp-empty" role="status">
                  <${InlineSpinner} size="xs" /> 대화 기록을 불러오는 중…
                </div>
              `}

              ${loadError && html`
                <div class="kp-card" role="alert" data-testid="ma-conversation-error">
                  <div class="ap-error">${loadError}</div>
                  <div class="kp-lifecycle-bar">
                    <button
                      type="button"
                      class="btn-ghost"
                      onClick=${() => void loadConversation(selectedConversationId)}
                    >
                      대화 다시 불러오기
                    </button>
                    ${selectedConversationId !== null && html`
                      <button
                        type="button"
                        class="btn-ghost"
                        onClick=${() => {
                          selectedConversationIdRef.current = null
                          setSelectedConversationId(null)
                          void loadConversation(null)
                        }}
                      >
                        현재 대화로 이동
                      </button>
                    `}
                    ${keeper.runtime_id !== null && html`
                      <button
                        type="button"
                        class="btn-primary"
                        disabled=${busy}
                        onClick=${() => void handleStartConversation()}
                      >
                        새 대화로 복구
                      </button>
                    `}
                  </div>
                </div>
              `}

              ${!loading && !loadError && turns.length === 0 && !ephemeralReply && !sendingMessage && html`
                <div class="kp-empty" data-testid="ma-conversation-empty">
                  ${keeper.runtime_id === null
                    ? '이 개인 Keeper에 아직 런타임이 연결되지 않았습니다. 상단에서 개인 런타임을 연결한 뒤 대화를 시작하세요.'
                    : conversation?.conversation_id
                      ? '이 대화에 아직 기록된 턴이 없습니다. 아래에서 첫 메시지를 보내세요.'
                      : '아직 시작된 대화가 없습니다. 아래에서 메시지를 보내면 자동으로 대화가 시작됩니다.'}
                </div>
              `}

              ${turns.map((turn, idx) => html`
                <div key=${`${turn.asked_at_ms}-${idx}`} class="kp-ma-turn-pair" data-testid="ma-turn-pair">
                  <article class="kp-msg" data-role="user">
                    <div class="kp-msg-head">
                      <strong>나</strong>
                      <span class="kp-msg-time">${formatMsTimestamp(turn.asked_at_ms)}</span>
                    </div>
                    <div class="kp-msg-body kp-delegate-prompt">${turn.message}</div>
                  </article>

                  ${turn.outcome.outcome === 'answered' && html`
                    <article class="kp-msg" data-role="assistant">
                      <div class="kp-msg-head">
                        <span>
                          <strong>${keeper.keeper_id}</strong>
                          <span class="kp-pill">${turn.outcome.model}</span>
                        </span>
                        <span class="kp-msg-time">${formatMsTimestamp(turn.outcome.answered_at_ms)}</span>
                      </div>
                      <div class="kp-msg-body">
                        <${MarkdownContent} text=${turn.outcome.text} />
                      </div>
                    </article>
                  `}

                  ${turn.outcome.outcome === 'failed' && html`
                    <article class="kp-msg" data-role="request_failure" data-testid="ma-turn-failed">
                      <div class="kp-msg-head">
                        <strong>응답 실패 (${turn.outcome.raw_failure})</strong>
                        <span class="kp-msg-time">${formatMsTimestamp(turn.outcome.failed_at_ms)}</span>
                      </div>
                      <div class="kp-msg-body">
                        ${formatPersonalTurnFailure(turn.outcome.failure, turn.outcome.raw_failure)}
                      </div>
                      ${turn.outcome.model_may_have_read && html`
                        <div class="kp-roster-sub kp-wrap-text">
                          클라이언트가 요청을 시작했으므로 모델이 이 메시지를 읽었을 수 있습니다.
                        </div>
                      `}
                    </article>
                  `}

                  ${turn.outcome.outcome === 'unrecorded' && html`
                    <article class="kp-msg" data-role="request_failure" data-testid="ma-turn-unrecorded">
                      <div class="kp-msg-head">
                        <strong>결과 미기록 (unrecorded)</strong>
                      </div>
                      <div class="kp-msg-body">
                        질문은 기록되었지만 응답 결과가 기록되지 않았습니다.
                        ${turn.outcome.model_may_have_read ? ' 모델이 이 메시지를 읽었을 수 있습니다.' : ''}
                      </div>
                    </article>
                  `}
                </div>
              `)}

              ${ephemeralReply && html`
                <div class="kp-ma-turn-pair" data-testid="ma-ephemeral-reply">
                  <article class="kp-msg" data-role="user">
                    <div class="kp-msg-head">
                      <strong>나</strong>
                      <span class="kp-msg-time">${formatMsTimestamp(ephemeralReply.atMs)}</span>
                    </div>
                    <div class="kp-msg-body kp-delegate-prompt">${ephemeralReply.message}</div>
                  </article>
                  <article class="kp-msg" data-role="assistant">
                    <div class="kp-msg-head">
                      <span>
                        <strong>${keeper.keeper_id}</strong>
                        <span class="kp-pill">${ephemeralReply.model}</span>
                        <span class="kp-pill" data-tone="warn">일회성 응답 (미저장)</span>
                      </span>
                      <span class="kp-msg-time">${formatMsTimestamp(ephemeralReply.atMs)}</span>
                    </div>
                    <div class="kp-msg-body">
                      <${MarkdownContent} text=${ephemeralReply.text} />
                    </div>
                    <div class="kp-roster-sub kp-wrap-text">
                      이 런타임(${ephemeralReply.runtimeId})의 응답은 서버 대화 기록에 저장되지 않습니다.
                    </div>
                  </article>
                </div>
              `}

              ${sendingMessage !== null && html`
                <div class="kp-ma-turn-pair" data-testid="ma-turn-pending">
                  <article class="kp-msg" data-role="user">
                    <div class="kp-msg-head">
                      <strong>나</strong>
                      <span class="kp-pill" data-tone="info">전송 중</span>
                    </div>
                    <div class="kp-msg-body kp-delegate-prompt">${sendingMessage}</div>
                  </article>
                  <div class="kp-live-turn-card" role="status">
                    <div class="kp-turn-progress">
                      <span class="kp-live-dot" aria-hidden="true" />
                      <strong>${keeper.keeper_id} 응답 대기 중…</strong>
                      <span class="kp-roster-sub">동기 HTTP 요청 (최대 120초)</span>
                    </div>
                  </div>
                </div>
              `}
            </div>
          </div>
        </div>

        <!-- Composer -->
        <div class="kp-ma-composer">
          ${actionError && html`
            <div class="ap-error" role="alert" data-testid="ma-turn-action-error">
              ${actionError}
            </div>
          `}
          <textarea
            class="kp-textarea"
            rows=${3}
            aria-label="개인 Keeper 메시지 입력"
            placeholder=${keeper.runtime_id === null
              ? '먼저 상단에서 개인 런타임을 연결하세요…'
              : isViewingHistorical
                ? '이전 대화는 읽기 전용입니다. 현재 대화로 이동해 메시지를 보내세요.'
                : '개인 Keeper에게 보낼 메시지를 입력하세요… (⌘↵ / Ctrl+Enter 전송)'}
            disabled=${busy || keeper.runtime_id === null || isViewingHistorical}
            value=${draft}
            onInput=${(e: Event) => {
              setDraft((e.currentTarget as HTMLTextAreaElement).value)
              if (actionError) setActionError(null)
            }}
            onKeyDown=${(e: KeyboardEvent) => {
              if (e.isComposing || e.keyCode === 229) return
              if ((e.metaKey || e.ctrlKey) && e.key === 'Enter' && !busy && !isViewingHistorical) {
                e.preventDefault()
                void handleSendTurn()
              }
            }}
          />
          <div class="kp-ma-composer-foot">
            <div class="kp-pill-row">
              <span
                class="kp-pill"
                data-tone=${overByteLimit ? 'bad' : draftBytes > 3600 ? 'warn' : 'default'}
                data-testid="ma-composer-bytes"
              >
                ${draftBytes} / ${PERSONAL_KEEPER_MESSAGE_MAX_BYTES} B
              </span>
              ${keeper.runtime_id === null && html`
                <button
                  type="button"
                  class="btn-ghost kp-toggle-btn"
                  onClick=${() => props.onNavigate('/runtime/quotas')}
                >
                  Runtime → Quotas 열기
                </button>
              `}
            </div>
            <button
              type="button"
              class="btn-primary"
              data-testid="ma-send-turn-btn"
              disabled=${busy || keeper.runtime_id === null || isViewingHistorical || overByteLimit}
              onClick=${() => void handleSendTurn()}
            >
              ${sendingMessage !== null ? html`<${InlineSpinner} size="xs" /> 대기 중…` : '메시지 보내기'}
            </button>
          </div>
        </div>
      </div>
    </div>
  `
}
