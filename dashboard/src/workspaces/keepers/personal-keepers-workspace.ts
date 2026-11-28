/**
 * Multi-Account Personal Keepers Workspace (`Manage_own_keeper`, Admin & Worker).
 *
 * Connects strictly to the live Multi-Account routes:
 * - `GET /api/v1/auth/keepers`
 * - `POST /api/v1/auth/keepers`
 * - `POST /api/v1/auth/keepers/assign`
 * - `GET /api/v1/auth/provider-accounts`
 * - `GET/POST/DELETE /api/v1/auth/keepers/conversation*`
 * - `POST /api/v1/auth/keepers/turn`
 * - Shared Observer SSE (`GET /api/v1/auth/events`) via `core/observer`
 *
 * Fires zero single-user `/api/v1/keepers/*` or `/api/v1/gate/keepers` 404 requests
 * and keeps single-user-only tabs (Memory OS, Portrait/Candle shop, Operator Notes,
 * Raw Traces, TOML Secrets/OAuth) honestly marked as single-user local only.
 */

import { html } from 'htm/preact'
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { useFocusScope } from '../../../design-system/headless-preact/use-focus-scope'
import { InlineSpinner } from '../../components/common/inline-spinner'
import { kSigil } from '../../components/keeper-badge'
import {
  authSession,
  currentSessionEpoch,
  isEpochCurrent,
  type AuthSession,
} from '../../core/auth'
import {
  markViewSynced,
  subscribeObserverFrames,
  subscribeObserverReconnect,
  subscribeObserverResync,
} from '../../core/observer'
import {
  KEEPER_ENTITY_TAB_LABELS,
  KEEPER_ENTITY_TABS,
  parseKeeperEntityTab,
  type KeeperEntityTab,
} from '../../routes/router'
import { pushShellToast } from '../../shell/shell-state'
import type { WorkspaceViewProps } from '../types'
import { PersonalKeeperChatPanel } from './personal-keeper-chat'
import {
  assignPersonalKeeperRuntimeApi,
  createPersonalKeeperApi,
  decodePersonalKeeperObserverFrame,
  fetchPersonalKeepersApi,
  fetchPersonalProviderAccountsApi,
  formatPersonalKeeperError,
  validatePersonalKeeperName,
  type PersonalKeeper,
  type PersonalKeeperObserverSignal,
  type PersonalProviderAccountsData,
  type PersonalRuntimeOption,
} from './personal-keepers-wire'

type MultiAccountSignedInSession = Extract<AuthSession, { readonly kind: 'multi_account_signed_in' }>

export interface PersonalKeepersWorkspaceProps extends WorkspaceViewProps {
  readonly session: MultiAccountSignedInSession
}

function runtimeOptionLabel(rt: PersonalRuntimeOption): string {
  const details = [
    rt.model ?? (rt.unread ? `모델 미확인: ${rt.unread}` : '모델 미지정'),
    rt.integration_id,
    rt.account_kind === 'key' ? 'API key' : rt.account_kind === 'login' ? '로그인' : null,
  ].filter(Boolean)
  return `${rt.runtime_id} (${details.join(' · ')})`
}

export function PersonalKeepersWorkspace(props: PersonalKeepersWorkspaceProps) {
  const { session } = props
  const activeTab: KeeperEntityTab = parseKeeperEntityTab(props.entityTab)

  const [keepers, setKeepers] = useState<readonly PersonalKeeper[]>([])
  const [keepersLoading, setKeepersLoading] = useState(true)
  const [keepersError, setKeepersError] = useState<string | null>(null)

  const [providerData, setProviderData] = useState<PersonalProviderAccountsData | null>(null)
  const [providerError, setProviderError] = useState<string | null>(null)

  const [query, setQuery] = useState('')
  const [localSelectedId, setLocalSelectedId] = useState<string | null>(props.entityId ?? null)
  const [createOpen, setCreateOpen] = useState(false)

  const [selectedRuntimeDraft, setSelectedRuntimeDraft] = useState('')
  const [assignBusy, setAssignBusy] = useState(false)
  const [assignErrorState, setAssignErrorState] = useState<{
    readonly keeperId: string
    readonly message: string
  } | null>(null)

  const [observerSignal, setObserverSignal] = useState<PersonalKeeperObserverSignal | null>(null)
  const [conversationRefreshTick, setConversationRefreshTick] = useState(0)

  const mountedRef = useRef(true)
  const listAbortRef = useRef<AbortController | null>(null)
  const providerAbortRef = useRef<AbortController | null>(null)
  const assignAbortRef = useRef<AbortController | null>(null)

  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
      listAbortRef.current?.abort('unmount')
      providerAbortRef.current?.abort('unmount')
      assignAbortRef.current?.abort('unmount')
    }
  }, [])

  useEffect(() => {
    if (props.entityId) {
      setLocalSelectedId(props.entityId)
    }
  }, [props.entityId])

  const loadKeepers = useCallback(async () => {
    if (authSession.peek().kind !== 'multi_account_signed_in') return
    listAbortRef.current?.abort('superseded')
    const ctrl = new AbortController()
    listAbortRef.current = ctrl
    const startEpoch = currentSessionEpoch()
    setKeepersLoading(true)
    const res = await fetchPersonalKeepersApi(ctrl.signal)
    if (
      !mountedRef.current
      || !isEpochCurrent(startEpoch)
      || ctrl.signal.aborted
      || authSession.peek().kind !== 'multi_account_signed_in'
    ) {
      return
    }
    setKeepersLoading(false)
    if (!res.ok) {
      if (res.error.kind === 'aborted' || res.error.kind === 'epoch_stale') return
      setKeepers([])
      setKeepersError(formatPersonalKeeperError(res.error, 'list'))
      return
    }
    setKeepers(res.value)
    setKeepersError(null)
    markViewSynced()
  }, [])

  const loadProviderAccounts = useCallback(async () => {
    if (authSession.peek().kind !== 'multi_account_signed_in') return
    providerAbortRef.current?.abort('superseded')
    const ctrl = new AbortController()
    providerAbortRef.current = ctrl
    const startEpoch = currentSessionEpoch()
    const res = await fetchPersonalProviderAccountsApi(ctrl.signal)
    if (
      !mountedRef.current
      || !isEpochCurrent(startEpoch)
      || ctrl.signal.aborted
      || authSession.peek().kind !== 'multi_account_signed_in'
    ) {
      return
    }
    if (!res.ok) {
      if (res.error.kind === 'aborted' || res.error.kind === 'epoch_stale') return
      setProviderData(null)
      setProviderError(formatPersonalKeeperError(res.error, 'list'))
      return
    }
    setProviderData(res.value)
    setProviderError(null)
  }, [])

  const refreshAll = useCallback(async () => {
    await Promise.all([loadKeepers(), loadProviderAccounts()])
  }, [loadKeepers, loadProviderAccounts])

  useEffect(() => {
    void refreshAll()
  }, [refreshAll])

  // Subscribe cleanly to shared `GET /api/v1/auth/events` keeper chat/preview/lifecycle events.
  useEffect(() => {
    let timer: ReturnType<typeof setTimeout> | null = null
    let disposed = false
    let pendingKeepers = false
    let pendingConversation = false

    const flush = () => {
      timer = null
      if (disposed || authSession.peek().kind !== 'multi_account_signed_in') return
      const doKeepers = pendingKeepers
      const doConversation = pendingConversation
      pendingKeepers = false
      pendingConversation = false
      if (doKeepers) void loadKeepers()
      if (doConversation) setConversationRefreshTick((n) => n + 1)
    }

    const schedule = (needKeepers: boolean, needConversation: boolean) => {
      if (disposed) return
      if (needKeepers) pendingKeepers = true
      if (needConversation) pendingConversation = true
      if (timer !== null) return
      timer = setTimeout(flush, 450)
    }

    const unsubFrames = subscribeObserverFrames((frame) => {
      if (disposed || authSession.peek().kind !== 'multi_account_signed_in') return
      const decoded = decodePersonalKeeperObserverFrame(frame)
      if (!decoded) return
      setObserverSignal(decoded)
      if (decoded.refreshKeepers || decoded.refreshConversation) {
        schedule(decoded.refreshKeepers, decoded.refreshConversation)
      }
    })
    const unsubResync = subscribeObserverResync(() => schedule(true, true))
    const unsubReconnect = subscribeObserverReconnect(() => schedule(true, true))

    return () => {
      disposed = true
      unsubFrames()
      unsubResync()
      unsubReconnect()
      if (timer !== null) clearTimeout(timer)
    }
  }, [loadKeepers])

  const runtimes = providerData?.runtimes ?? []
  const runtimeById = useMemo(() => {
    const map = new Map<string, PersonalRuntimeOption>()
    for (const rt of runtimes) map.set(rt.runtime_id, rt)
    return map
  }, [runtimes])

  const filteredKeepers = useMemo(() => {
    const q = query.trim().toLowerCase()
    if (!q) return keepers
    return keepers.filter((k) => {
      const rt = k.runtime_id ? runtimeById.get(k.runtime_id) : null
      return (
        k.keeper_id.toLowerCase().includes(q)
        || (k.runtime_id?.toLowerCase().includes(q) ?? false)
        || (rt?.model?.toLowerCase().includes(q) ?? false)
        || (rt?.integration_id?.toLowerCase().includes(q) ?? false)
      )
    })
  }, [keepers, query, runtimeById])

  const activeKeeper = useMemo<PersonalKeeper | null>(() => {
    if (keepers.length === 0) return null
    const wanted = props.entityId ?? localSelectedId
    if (wanted) {
      const exact = keepers.find((k) => k.keeper_id === wanted)
      if (exact) return exact
      // Explicit entityId not owned by this account must never fall back to another keeper.
      if (props.entityId) return null
    }
    return keepers[0] ?? null
  }, [keepers, props.entityId, localSelectedId])

  useEffect(() => {
    setSelectedRuntimeDraft(activeKeeper?.runtime_id ?? '')
    setAssignErrorState(null)
  }, [activeKeeper?.keeper_id, activeKeeper?.runtime_id])

  const handleSelectKeeper = useCallback(
    (keeperId: string) => {
      setLocalSelectedId(keeperId)
      props.onNavigate(`/keepers/${encodeURIComponent(keeperId)}/${activeTab}`)
    },
    [props, activeTab],
  )

  const handleSelectTab = useCallback(
    (tab: KeeperEntityTab) => {
      if (!activeKeeper) return
      props.onNavigate(`/keepers/${encodeURIComponent(activeKeeper.keeper_id)}/${tab}`)
    },
    [props, activeKeeper],
  )

  const handleCreatedKeeper = useCallback(
    (keeperId: string) => {
      setCreateOpen(false)
      setLocalSelectedId(keeperId)
      void loadKeepers()
      props.onNavigate(`/keepers/${encodeURIComponent(keeperId)}/chat`)
    },
    [props, loadKeepers],
  )

  const handleAssignRuntime = async (keeperId: string, runtimeId: string) => {
    if (assignBusy || !runtimeId || authSession.peek().kind !== 'multi_account_signed_in') return
    assignAbortRef.current?.abort('superseded')
    const ctrl = new AbortController()
    assignAbortRef.current = ctrl
    const startEpoch = currentSessionEpoch()
    setAssignBusy(true)
    setAssignErrorState(null)
    const res = await assignPersonalKeeperRuntimeApi(keeperId, runtimeId, ctrl.signal)
    if (
      !mountedRef.current
      || !isEpochCurrent(startEpoch)
      || ctrl.signal.aborted
      || authSession.peek().kind !== 'multi_account_signed_in'
    ) {
      return
    }
    setAssignBusy(false)
    if (!res.ok) {
      if (res.error.kind === 'aborted' || res.error.kind === 'epoch_stale') return
      setAssignErrorState({ keeperId, message: formatPersonalKeeperError(res.error, 'assign') })
      if (res.error.kind === 'server' || res.error.kind === 'network' || res.error.kind === 'decode') {
        void loadKeepers()
      }
      return
    }
    setKeepers((prev) =>
      prev.map((item) =>
        item.keeper_id === res.value.keeper_id
          ? { ...item, runtime_id: res.value.runtime_id }
          : item,
      ),
    )
    setAssignErrorState(null)
    pushShellToast(
      res.value.record === 'existing'
        ? `${res.value.keeper_id}는 이미 ${res.value.runtime_id}에 연결되어 있습니다.`
        : `${res.value.keeper_id}에 런타임 ${res.value.runtime_id}을(를) 연결했습니다.`,
      'success',
    )
  }

  const assignedRuntime = activeKeeper?.runtime_id
    ? runtimeById.get(activeKeeper.runtime_id) ?? null
    : null
  const activeRuntimeUnavailable =
    activeKeeper?.runtime_id !== null
    && activeKeeper !== null
    && providerData !== null
    && providerError === null
    && assignedRuntime === null
  const assignError =
    assignErrorState !== null && activeKeeper !== null && assignErrorState.keeperId === activeKeeper.keeper_id
      ? assignErrorState.message
      : null

  const renderRuntimeAssignmentSection = (keeper: PersonalKeeper, testIdPrefix: string) => html`
    <div class="kp-ma-runtime-bar" data-testid=${`${testIdPrefix}-runtime-bar`}>
      <select
        class="kp-input kp-ma-runtime-select"
        aria-label="개인 Keeper 런타임 선택"
        data-testid=${`${testIdPrefix}-runtime-select`}
        disabled=${assignBusy || runtimes.length === 0}
        value=${selectedRuntimeDraft}
        onChange=${(e: Event) => {
          setSelectedRuntimeDraft((e.currentTarget as HTMLSelectElement).value)
          if (assignErrorState) setAssignErrorState(null)
        }}
      >
        <option value="">
          ${runtimes.length === 0 ? '연결 가능한 개인 런타임 없음' : '런타임 선택…'}
        </option>
        ${runtimes.map((rt) => html`
          <option key=${rt.runtime_id} value=${rt.runtime_id}>
            ${runtimeOptionLabel(rt)}
          </option>
        `)}
      </select>
      <button
        type="button"
        class="btn-primary"
        data-testid=${`${testIdPrefix}-assign-btn`}
        disabled=${assignBusy || !selectedRuntimeDraft || selectedRuntimeDraft === (keeper.runtime_id ?? '')}
        onClick=${() => void handleAssignRuntime(keeper.keeper_id, selectedRuntimeDraft)}
      >
        ${assignBusy
          ? html`<${InlineSpinner} size="xs" /> 연결 중…`
          : keeper.runtime_id ? '런타임 변경' : '런타임 연결'}
      </button>
      ${runtimes.length === 0 && html`
        <button
          type="button"
          class="btn-ghost"
          onClick=${() => props.onNavigate('/runtime/quotas')}
        >
          Runtime → Quotas에서 계정 연결
        </button>
      `}
    </div>
  `

  return html`
    <div
      class="kp-root"
      data-workspace="keepers"
      data-keepers-mode="multi_account"
      data-testid="ma-personal-keepers-workspace"
    >
      <!-- Left 260px Personal Keeper Roster -->
      <aside class="kp-roster" aria-label="개인 Keeper 목록">
        <div class="kp-roster-head">
          <div class="kp-roster-top">
            <h2 class="kp-roster-title">
              <span class="kp-roster-title-text" title=${`Personal Keepers (${keepers.length})`}>
                Personal (<span class="tnum">${keepers.length}</span>)
              </span>
            </h2>
            <button
              type="button"
              class="btn-primary"
              data-testid="ma-create-keeper-btn"
              onClick=${() => setCreateOpen(true)}
            >
              + Create Keeper
            </button>
          </div>

          <div class="kp-roster-note" data-testid="ma-roster-role">
            <span class="kp-pill" data-tone="info">${session.role}</span>
          </div>

          <input
            type="search"
            class="kp-input"
            placeholder="개인 Keeper, 런타임 검색…"
            aria-label="개인 Keeper 검색"
            value=${query}
            onInput=${(e: Event) => setQuery((e.currentTarget as HTMLInputElement).value)}
          />
        </div>

        ${keepersLoading && keepers.length === 0
          ? html`<div class="kp-empty" role="status">개인 Keeper 목록 불러오는 중…</div>`
          : keepersError
            ? html`
                <div class="kp-scroll-pane">
                  <div class="ap-error" role="alert" data-testid="ma-keepers-list-error">
                    ${keepersError}
                  </div>
                  <button type="button" class="btn-ghost" onClick=${() => void refreshAll()}>
                    목록 다시 불러오기
                  </button>
                </div>
              `
            : filteredKeepers.length === 0
              ? html`
                  <div class="kp-empty" data-testid="ma-keepers-empty">
                    ${keepers.length === 0
                      ? '소유한 개인 Keeper가 없습니다. "+ Create Keeper"로 새 Keeper를 만드세요.'
                      : '검색 조건에 일치하는 개인 Keeper가 없습니다.'}
                  </div>
                `
              : html`
                  <div class="kp-roster-list" role="list" aria-label="개인 Keeper 목록">
                    ${filteredKeepers.map((k) => {
                      const selected = activeKeeper?.keeper_id === k.keeper_id
                      const rt = k.runtime_id ? runtimeById.get(k.runtime_id) ?? null : null
                      const runtimeUnavailable =
                        k.runtime_id !== null && providerData !== null && providerError === null && rt === null
                      const subLine = k.runtime_id
                        ? runtimeUnavailable
                          ? `${k.runtime_id} · 재연결 필요`
                          : rt?.model
                            ? `${k.runtime_id} · ${rt.model}`
                            : k.runtime_id
                        : '런타임 미지정'
                      const runtimeTone = k.runtime_id && !runtimeUnavailable ? 'ok' : 'warn'
                      const runtimeBadge = !k.runtime_id
                        ? '미지정'
                        : runtimeUnavailable
                          ? '재연결 필요'
                          : '연결됨'
                      return html`
                        <button
                          key=${k.keeper_id}
                          type="button"
                          role="listitem"
                          class="kp-roster-row"
                          data-keeper=${k.keeper_id}
                          data-selected=${selected ? 'true' : 'false'}
                          aria-current=${selected ? 'true' : undefined}
                          onClick=${() => handleSelectKeeper(k.keeper_id)}
                        >
                          <span class="kp-roster-avatar">
                            <span class="kp-hero-portrait-sigil kp-ma-roster-sigil" aria-hidden="true">
                              ${kSigil(k.keeper_id)}
                            </span>
                            <span
                              class="kp-status-dot"
                              data-tone=${runtimeTone}
                            />
                          </span>
                          <span class="kp-roster-info">
                            <span class="kp-roster-name">${k.keeper_id}</span>
                            <span class="kp-roster-sub" title=${subLine}>${subLine}</span>
                          </span>
                          <span class="kp-roster-right">
                            <span class="kp-pill" data-tone=${runtimeTone}>
                              ${runtimeBadge}
                            </span>
                          </span>
                        </button>
                      `
                    })}
                  </div>
                `}

        ${createOpen && html`
          <${CreatePersonalKeeperModal}
            existingIds=${keepers.map((k) => k.keeper_id)}
            runtimes=${runtimes}
            onClose=${() => setCreateOpen(false)}
            onCreated=${handleCreatedKeeper}
            onUncertainCreate=${() => void loadKeepers()}
            onNavigate=${props.onNavigate}
          />
        `}
      </aside>

      <!-- Right Stage -->
      <section class="kp-stage" aria-label="개인 Keeper 워크스페이스">
        ${!activeKeeper
          ? html`
              <div class="kp-scroll-pane">
                ${props.entityId && !keepersLoading && !keepersError
                  ? html`
                      <div class="kp-card" data-testid="ma-keeper-not-found" role="status">
                        <h3>개인 Keeper를 찾을 수 없습니다: ${props.entityId}</h3>
                        <p class="kp-roster-sub kp-wrap-text">
                          현재 계정(<code class="mono">${session.accountId}</code>)이 소유한 <code>/api/v1/auth/keepers</code> 목록에 해당 Keeper가 없습니다.
                        </p>
                        <div class="kp-lifecycle-bar">
                          <button type="button" class="btn-ghost" onClick=${() => props.onNavigate('/keepers')}>
                            목록으로 돌아가기
                          </button>
                          <button type="button" class="btn-primary" onClick=${() => setCreateOpen(true)}>
                            + Create Keeper
                          </button>
                        </div>
                      </div>
                    `
                  : html`
                      <div class="kp-empty">
                        ${keepersLoading
                          ? '개인 Keeper 목록 불러오는 중…'
                          : '표시할 개인 Keeper를 선택하거나 "+ Create Keeper"로 새로 만드세요.'}
                      </div>
                    `}
              </div>
            `
          : html`
              <header class="kp-hero" data-testid="ma-keeper-header">
                <div class="kp-hero-top">
                  <div class="kp-hero-id">
                    <div class="kp-hero-portrait-ring">
                      <span class="kp-hero-portrait-sigil" aria-label=${activeKeeper.keeper_id}>
                        ${kSigil(activeKeeper.keeper_id)}
                      </span>
                    </div>

                    <div class="kp-hero-text">
                      <h1 class="kp-hero-name">${activeKeeper.keeper_id}</h1>
                      <div class="kp-pill-row">
                        <span class="kp-pill" data-tone="info">Personal Keeper</span>
                        <span
                          class="kp-pill"
                          data-tone=${activeKeeper.runtime_id && !activeRuntimeUnavailable ? 'ok' : 'warn'}
                          data-testid="ma-keeper-runtime-pill"
                        >
                          ${!activeKeeper.runtime_id
                            ? '런타임 미지정'
                            : activeRuntimeUnavailable
                              ? `Runtime: ${activeKeeper.runtime_id} (재연결 필요)`
                              : `Runtime: ${activeKeeper.runtime_id}`}
                        </span>
                        ${assignedRuntime?.model && html`
                          <span class="kp-pill" data-tone="brass">${assignedRuntime.model}</span>
                        `}
                        ${assignedRuntime?.unread && html`
                          <span class="kp-pill" data-tone="warn">
                            런타임 주의: ${assignedRuntime.unread}
                          </span>
                        `}
                      </div>
                    </div>
                  </div>

                  ${renderRuntimeAssignmentSection(activeKeeper, 'ma-header')}
                </div>

                ${assignError && html`
                  <div class="ap-error" role="alert" data-testid="ma-assign-error">${assignError}</div>
                `}
                ${providerError && html`
                  <div class="ap-error" role="alert" data-testid="ma-provider-accounts-error">
                    개인 런타임 목록 조회 실패: ${providerError}
                  </div>
                `}

                <nav class="kp-tabs" role="tablist" aria-label="Keeper 상세 탭" data-mobile-only="true">
                  ${KEEPER_ENTITY_TABS.map((tab) => html`
                    <button
                      key=${tab}
                      type="button"
                      role="tab"
                      class="kp-tab"
                      aria-selected=${activeTab === tab ? 'true' : 'false'}
                      onClick=${() => handleSelectTab(tab)}
                    >
                      ${KEEPER_ENTITY_TAB_LABELS[tab]}
                    </button>
                  `)}
                </nav>
              </header>

              <div class="kp-body">
                ${activeTab === 'chat' && html`
                  <${PersonalKeeperChatPanel}
                    key=${`ma-chat:${activeKeeper.keeper_id}`}
                    keeper=${activeKeeper}
                    assignedRuntime=${assignedRuntime}
                    observerSignal=${observerSignal}
                    externalRefreshTick=${conversationRefreshTick}
                    onNavigate=${props.onNavigate}
                  />
                `}

                ${activeTab === 'config' && html`
                  <div class="kp-scroll-pane" data-keeper-tab="config">
                    <section class="kp-card" aria-label="개인 Keeper 런타임 연결">
                      <div class="kp-card-head">
                        <h3>Personal Runtime Assignment</h3>
                        <button
                          type="button"
                          class="btn-ghost"
                          onClick=${() => props.onNavigate('/runtime/quotas')}
                        >
                          Runtime → Quotas →
                        </button>
                      </div>
                      <p class="kp-roster-sub kp-wrap-text">
                        개인 Keeper는 본인 소유의 런타임(<code>/api/v1/auth/provider-accounts</code>)을 연결해 실행합니다.
                      </p>
                      ${renderRuntimeAssignmentSection(activeKeeper, 'ma-config')}
                    </section>

                    <section
                      class="kp-card"
                      data-testid="ma-keeper-su-only-tab"
                      data-tab="config"
                      role="status"
                    >
                      <div class="kp-card-head">
                        <h3>TOML Config, Secrets & OAuth Tools (싱글유저 로컬 전용)</h3>
                      </div>
                      <p class="kp-roster-sub kp-wrap-text">
                        Keeper TOML 설정 스키마 CAS, 쓰기 전용 시크릿 환경변수(<code>/api/v1/keepers/:k/secrets</code>),
                        OAuth 연결 도구(<code>/api/v1/keepers/oauth/attached-tools</code>)는 싱글유저 로컬 세션 전용이며
                        멀티 계정 서버에 마운트되어 있지 않습니다. 개인 모델 자격 증명은 <strong>Runtime → Quotas</strong>에서 관리하세요.
                      </p>
                      <div class="kp-lifecycle-bar">
                        <button
                          type="button"
                          class="btn-primary"
                          onClick=${() => handleSelectTab('chat')}
                        >
                          Chat으로 돌아가기
                        </button>
                      </div>
                    </section>
                  </div>
                `}

                ${(activeTab === 'memory' || activeTab === 'portrait-candle' || activeTab === 'work-sandbox' || activeTab === 'prompt') && html`
                  <${SingleUserOnlyTabNotice}
                    keeperId=${activeKeeper.keeper_id}
                    tab=${activeTab}
                    onBackToChat=${() => handleSelectTab('chat')}
                    onNavigate=${props.onNavigate}
                  />
                `}
              </div>
            `}
      </section>
    </div>
  `
}

interface SingleUserOnlyTabDetails {
  readonly title: string
  readonly description: string
  /** A screen this session can open for the nearest workspace-wide view, when one exists. */
  readonly secondary: { readonly label: string; readonly path: string } | null
}

function singleUserOnlyTabDetails(tab: 'memory' | 'portrait-candle' | 'work-sandbox' | 'prompt', keeperId: string): SingleUserOnlyTabDetails {
  switch (tab) {
    case 'memory':
      return {
        title: `Memory OS · ${keeperId}`,
        description:
          'Keeper Memory OS Facts·Journal·Internals 조회 및 복구/철회(/api/v1/keepers/:k/memory-*)는 싱글유저 로컬 세션 전용입니다. 멀티 계정 서버에서는 마운트되지 않아 요청을 전송하지 않습니다.',
        secondary: { label: 'World Memory →', path: '/knowledge/memory' },
      }
    case 'portrait-candle':
      return {
        title: `Portrait & Candle · ${keeperId}`,
        description:
          'Keeper 초상화 렌더링(/api/v1/keepers/:k/portrait.png)과 장신구 상점(/api/v1/keepers/:k/items)은 싱글유저 로컬 세션 전용입니다. 워크스페이스 전체 Candle 원장은 Work → Candle에서 볼 수 있습니다.',
        secondary: { label: 'Work → Candle →', path: '/work/candle' },
      }
    case 'work-sandbox':
      return {
        title: `Work & Sandbox · ${keeperId}`,
        description:
          'Keeper 운영자 노트(/operator-note), 도구 호출 통계/상세(/tool-stats, /tool-calls), 원시 트레이스, 개별 샌드박스 텔레메트리는 싱글유저 로컬 세션 전용입니다. 워크스페이스 작업은 Work → Tasks에서 확인할 수 있습니다.',
        secondary: { label: 'Work → Tasks →', path: '/work/tasks' },
      }
    case 'prompt':
      return {
        title: `Prompt · ${keeperId}`,
        description:
          'Keeper 가 마지막으로 조립한 프롬프트(/api/v1/keepers/:k/last-prompt)와 Provider 요청(/provider-input)은 싱글유저 로컬 세션 전용입니다.',
        secondary: null,
      }
  }
}

function SingleUserOnlyTabNotice(props: {
  readonly keeperId: string
  readonly tab: 'memory' | 'portrait-candle' | 'work-sandbox' | 'prompt'
  readonly onBackToChat: () => void
  readonly onNavigate: (path: string) => void
}) {
  const details = singleUserOnlyTabDetails(props.tab, props.keeperId)

  return html`
    <div class="kp-scroll-pane" data-keeper-tab=${props.tab}>
      <section
        class="kp-card"
        data-testid="ma-keeper-su-only-tab"
        data-tab=${props.tab}
        role="status"
      >
        <div class="kp-card-head">
          <h3>${details.title}</h3>
          <span class="kp-pill" data-tone="info">싱글유저 로컬 전용</span>
        </div>
        <p class="kp-roster-sub kp-wrap-text">${details.description}</p>
        <div class="kp-lifecycle-bar">
          <button type="button" class="btn-primary" onClick=${props.onBackToChat}>
            Chat으로 돌아가기
          </button>
          ${details.secondary !== null && html`
            <button
              type="button"
              class="btn-ghost"
              onClick=${() => { if (details.secondary !== null) props.onNavigate(details.secondary.path) }}
            >
              ${details.secondary.label}
            </button>
          `}
        </div>
      </section>
    </div>
  `
}

interface CreatePersonalKeeperModalProps {
  readonly existingIds: readonly string[]
  readonly runtimes: readonly PersonalRuntimeOption[]
  readonly onClose: () => void
  readonly onCreated: (keeperId: string) => void
  readonly onUncertainCreate: () => void
  readonly onNavigate: (path: string) => void
}

function CreatePersonalKeeperModal(props: CreatePersonalKeeperModalProps) {
  const [keeperName, setKeeperName] = useState('')
  const [runtimeId, setRuntimeId] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const modalRef = useRef<HTMLDivElement>(null)
  const inputRef = useRef<HTMLInputElement>(null)
  const submitAbortRef = useRef<AbortController | null>(null)
  const mountedRef = useRef(true)
  const onCloseRef = useRef(props.onClose)
  onCloseRef.current = props.onClose

  useFocusScope({
    containerRef: modalRef,
    active: true,
    initialFocus: () => inputRef.current,
  })

  useEffect(() => {
    mountedRef.current = true
    queueMicrotask(() => inputRef.current?.focus())
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.defaultPrevented || event.isComposing || event.keyCode === 229) return
      if (event.key === 'Escape') {
        event.preventDefault()
        event.stopPropagation()
        onCloseRef.current()
      }
    }
    window.addEventListener('keydown', onKeyDown)
    return () => {
      mountedRef.current = false
      submitAbortRef.current?.abort('modal_unmount')
      window.removeEventListener('keydown', onKeyDown)
    }
  }, [])

  const handleSubmit = async (event: Event) => {
    event.preventDefault()
    if (busy || authSession.peek().kind !== 'multi_account_signed_in') return
    const check = validatePersonalKeeperName(keeperName)
    if (!check.ok) {
      setError(check.error)
      return
    }
    if (props.existingIds.includes(check.value)) {
      setError(`이미 "${check.value}" 이름의 개인 Keeper가 있습니다.`)
      return
    }
    submitAbortRef.current?.abort('superseded')
    const ctrl = new AbortController()
    submitAbortRef.current = ctrl
    const startEpoch = currentSessionEpoch()
    setBusy(true)
    setError(null)

    const madeRes = await createPersonalKeeperApi(check.value, ctrl.signal)
    if (
      !mountedRef.current
      || !isEpochCurrent(startEpoch)
      || ctrl.signal.aborted
      || authSession.peek().kind !== 'multi_account_signed_in'
    ) {
      return
    }
    if (!madeRes.ok) {
      setBusy(false)
      if (madeRes.error.kind !== 'aborted' && madeRes.error.kind !== 'epoch_stale') {
        setError(formatPersonalKeeperError(madeRes.error, 'create'))
        if (
          madeRes.error.kind === 'server'
          || madeRes.error.kind === 'network'
          || madeRes.error.kind === 'decode'
        ) {
          props.onUncertainCreate()
        }
      }
      return
    }

    // Only assign the chosen runtime when this request created the keeper freshly.
    let assignFailureMessage: string | null = null
    if (madeRes.value.record === 'made' && runtimeId) {
      const assignRes = await assignPersonalKeeperRuntimeApi(madeRes.value.keeper_id, runtimeId, ctrl.signal)
      if (
        !mountedRef.current
        || !isEpochCurrent(startEpoch)
        || ctrl.signal.aborted
        || authSession.peek().kind !== 'multi_account_signed_in'
      ) {
        return
      }
      if (!assignRes.ok && assignRes.error.kind !== 'aborted' && assignRes.error.kind !== 'epoch_stale') {
        assignFailureMessage = formatPersonalKeeperError(assignRes.error, 'assign')
      }
    }

    setBusy(false)
    if (assignFailureMessage !== null) {
      pushShellToast(
        `개인 Keeper "${madeRes.value.keeper_id}"를 생성했지만 런타임 연결에 실패했습니다: ${assignFailureMessage}`,
        'info',
      )
    } else {
      pushShellToast(
        madeRes.value.record === 'existing'
          ? `기존 개인 Keeper "${madeRes.value.keeper_id}"를 열었습니다.`
          : `개인 Keeper "${madeRes.value.keeper_id}"를 생성했습니다.`,
        'success',
      )
    }
    props.onCreated(madeRes.value.keeper_id)
  }

  return html`
    <div
      ref=${modalRef}
      class="kp-modal-backdrop"
      role="dialog"
      aria-modal="true"
      aria-label="새 개인 Keeper 생성"
      data-testid="ma-create-keeper-modal"
      onClick=${(e: MouseEvent) => {
        if (e.target === e.currentTarget) props.onClose()
      }}
    >
      <form class="kp-modal" onSubmit=${(e: Event) => void handleSubmit(e)}>
        <div class="kp-card-head">
          <h3>+ Create Personal Keeper</h3>
          <button type="button" class="btn-ghost" onClick=${props.onClose}>닫기</button>
        </div>

        <p class="kp-roster-sub kp-wrap-text">
          본인 계정 소유의 개인 Keeper를 생성합니다 (<code>POST /api/v1/auth/keepers</code>).
        </p>

        ${error && html`<div class="ap-error" role="alert" data-testid="ma-create-keeper-error">${error}</div>`}

        <label class="kp-kv-box">
          <span class="kp-kv-k">Keeper ID (필수 · 영문/숫자/._-)</span>
          <input
            ref=${inputRef}
            type="text"
            class="kp-input"
            aria-label="개인 Keeper 이름"
            placeholder="e.g. my-code-reviewer"
            disabled=${busy}
            value=${keeperName}
            onInput=${(e: Event) => {
              setKeeperName((e.currentTarget as HTMLInputElement).value)
              if (error) setError(null)
            }}
          />
        </label>

        <label class="kp-kv-box">
          <span class="kp-kv-k">초기 연결 런타임 (선택)</span>
          <select
            class="kp-input"
            aria-label="초기 연결 런타임"
            disabled=${busy || props.runtimes.length === 0}
            value=${runtimeId}
            onChange=${(e: Event) => setRuntimeId((e.currentTarget as HTMLSelectElement).value)}
          >
            <option value="">지정 안 함 (생성 후 연결)</option>
            ${props.runtimes.map((rt) => html`
              <option key=${rt.runtime_id} value=${rt.runtime_id}>
                ${runtimeOptionLabel(rt)}
              </option>
            `)}
          </select>
        </label>

        ${props.runtimes.length === 0 && html`
          <div class="kp-notice" data-tone="info" role="note">
            아직 연결된 개인 런타임이 없습니다. 생성 후 <strong>Runtime → Quotas</strong>에서 계정을 연결할 수 있습니다.
            <button
              type="button"
              class="btn-ghost kp-toggle-btn"
              onClick=${() => {
                props.onClose()
                props.onNavigate('/runtime/quotas')
              }}
            >
              Runtime → Quotas 이동
            </button>
          </div>
        `}

        <div class="kp-lifecycle-bar">
          <button type="button" class="btn-ghost" disabled=${busy} onClick=${props.onClose}>
            취소
          </button>
          <button
            type="submit"
            class="btn-primary"
            data-testid="ma-create-keeper-submit"
            disabled=${busy}
          >
            ${busy ? html`<${InlineSpinner} size="xs" /> 생성 중…` : '개인 Keeper 생성'}
          </button>
        </div>
      </form>
    </div>
  `
}
