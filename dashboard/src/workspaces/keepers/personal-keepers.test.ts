// @vitest-environment jsdom

import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { html } from 'htm/preact'
import { act, cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { authSession, bumpSessionEpoch, resetAuthStateForTests, type AuthSession } from '../../core/auth'
import { resetObserverStateForTests, startObserverStream } from '../../core/observer'
import { resourceCache } from '../../core/resource-cache'
import { resetPortraitCacheForTests } from '../../lib/portrait-cache'
import { resetRouterForTests } from '../../routes/router'
import { resetShellStateForTests, shellToasts } from '../../shell/shell-state'
import { KeepersWorkspace } from './index'
import {
  assignPersonalKeeperRuntimeApi,
  createPersonalKeeperApi,
  decodeAssignedPersonalKeeper,
  decodeDeletedPersonalConversation,
  decodeMadePersonalKeeper,
  decodePersonalConversation,
  decodePersonalKeeperObserverFrame,
  decodePersonalKeepersList,
  decodePersonalProviderAccounts,
  decodePersonalTurnAnswer,
  decodeStartedPersonalConversation,
  deletePersonalConversationApi,
  fetchPersonalConversationApi,
  fetchPersonalKeepersApi,
  fetchPersonalProviderAccountsApi,
  PERSONAL_KEEPER_MESSAGE_MAX_BYTES,
  sendPersonalKeeperTurnApi,
  startPersonalConversationApi,
  validatePersonalKeeperName,
  validatePersonalTurnMessage,
} from './personal-keepers-wire'

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

function makeMaSession(
  role: 'admin' | 'worker',
  accountId = role === 'admin' ? 'acct-admin' : 'acct-worker',
  csrfToken = role === 'admin' ? 'csrf-admin-tok' : 'csrf-worker-tok',
): Extract<AuthSession, { readonly kind: 'multi_account_signed_in' }> {
  return {
    kind: 'multi_account_signed_in',
    mode: 'multi_account',
    accountId,
    email: `${accountId}@example.com`,
    displayName: accountId,
    role,
    csrfToken,
    workspaceId: 'default',
    authMethods: { google: true, github: true, dev_token: false },
  }
}

const SAMPLE_PROVIDER_ACCOUNTS = {
  provider_accounts: [
    {
      provider_account_id: 'pa-claude-1',
      kind: 'login',
      integration_id: 'claude',
    },
    {
      provider_account_id: 'pa-key-2',
      kind: 'key',
      key: 'readable',
      integration_id: 'claude',
    },
  ],
  runtimes: [
    {
      runtime_id: 'rt-claude-sonnet',
      provider_account_id: 'pa-claude-1',
      model: 'claude-sonnet-4-6',
    },
    {
      runtime_id: 'rt-claude-opus',
      provider_account_id: 'pa-key-2',
      model: 'claude-opus-4-6',
    },
  ],
}

describe('Multi-Account Personal Keepers wire decoders and validators', () => {
  beforeEach(() => {
    resetAuthStateForTests()
    resetObserverStateForTests()
    resetPortraitCacheForTests()
    resetRouterForTests('/keepers')
    resetShellStateForTests()
    resourceCache.clearAll()
  })

  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  it('rejects malformed payloads fail-closed across all personal keeper decoders', () => {
    // 1. GET /api/v1/auth/keepers
    expect(() => decodePersonalKeepersList(null)).toThrow()
    expect(() => decodePersonalKeepersList({})).toThrow()
    expect(() => decodePersonalKeepersList({ keepers: 'oops' })).toThrow()
    expect(() => decodePersonalKeepersList({ keepers: [null] })).toThrow()
    expect(() => decodePersonalKeepersList({ keepers: [{ keeper_id: 'alpha' }] })).toThrow()
    expect(() => decodePersonalKeepersList({ keepers: [{ keeper_id: '', runtime_id: null }] })).toThrow()
    expect(() => decodePersonalKeepersList({ keepers: [{ keeper_id: 'alpha', runtime_id: 42 }] })).toThrow()
    expect(() => decodePersonalKeepersList({
      keepers: [
        { keeper_id: 'dup', runtime_id: null },
        { keeper_id: 'dup', runtime_id: 'rt-1' },
      ],
    })).toThrow()
    expect(decodePersonalKeepersList({
      keepers: [{ keeper_id: 'alpha', runtime_id: null }, { keeper_id: 'beta', runtime_id: 'rt-1' }],
    })).toEqual([
      { keeper_id: 'alpha', runtime_id: null },
      { keeper_id: 'beta', runtime_id: 'rt-1' },
    ])

    // 2. GET /api/v1/auth/provider-accounts
    expect(() => decodePersonalProviderAccounts({})).toThrow()
    expect(() => decodePersonalProviderAccounts({ provider_accounts: 'bad', runtimes: [] })).toThrow()
    expect(() => decodePersonalProviderAccounts({ provider_accounts: [null], runtimes: [] })).toThrow()
    expect(() => decodePersonalProviderAccounts({
      provider_accounts: [{ provider_account_id: 'pa-1', kind: 'oauth', integration_id: 'claude' }],
      runtimes: [],
    })).toThrow()
    expect(() => decodePersonalProviderAccounts({
      provider_accounts: [],
      runtimes: [{ runtime_id: 'rt-1', provider_account_id: 'pa-1' }],
    })).toThrow()
    expect(decodePersonalProviderAccounts(SAMPLE_PROVIDER_ACCOUNTS).runtimes).toHaveLength(2)

    // 3. POST /api/v1/auth/keepers & /assign
    expect(() => decodeMadePersonalKeeper({ keeper_id: 'other', record: 'made' }, 'alpha')).toThrow()
    expect(() => decodeMadePersonalKeeper({ keeper_id: 'alpha', record: 'created' }, 'alpha')).toThrow()
    expect(decodeMadePersonalKeeper({ keeper_id: 'alpha', record: 'existing' }, 'alpha')).toEqual({
      keeper_id: 'alpha',
      record: 'existing',
    })

    expect(() => decodeAssignedPersonalKeeper({ keeper_id: 'alpha', runtime_id: 'rt-2', record: 'assigned' }, 'alpha', 'rt-1')).toThrow()
    expect(() => decodeAssignedPersonalKeeper({ keeper_id: 'alpha', runtime_id: 'rt-1', record: 'ok' }, 'alpha', 'rt-1')).toThrow()
    expect(decodeAssignedPersonalKeeper({ keeper_id: 'alpha', runtime_id: 'rt-1', record: 'assigned' }, 'alpha', 'rt-1')).toEqual({
      keeper_id: 'alpha',
      runtime_id: 'rt-1',
      record: 'assigned',
    })

    // 4. GET /api/v1/auth/keepers/conversation
    expect(() => decodePersonalConversation({}, 'alpha')).toThrow()
    expect(() => decodePersonalConversation({
      keeper_id: 'alpha',
      current_conversation_id: null,
      conversations: 'bad',
      conversation_id: null,
      turns: [],
    }, 'alpha')).toThrow()
    expect(() => decodePersonalConversation({
      keeper_id: 'alpha',
      current_conversation_id: null,
      conversations: [],
      conversation_id: null,
      turns: [{ message: 'hi', asked_at_ms: 1000, outcome: 'unrecorded', model_may_have_read: true }],
    }, 'alpha')).toThrow()
    expect(() => decodePersonalConversation({
      keeper_id: 'alpha',
      current_conversation_id: 'c-1',
      conversations: [{ conversation_id: 'c-1', provider_account_id: 'pa-1', started_at_ms: 1000, deletion: 'pending' }],
      conversation_id: 'c-1',
      turns: [],
    }, 'alpha')).toThrow()
    expect(() => decodePersonalConversation({
      keeper_id: 'alpha',
      current_conversation_id: 'c-1',
      conversations: [{ conversation_id: 'c-1', provider_account_id: 'pa-1', started_at_ms: 1000 }],
      conversation_id: 'c-1',
      turns: [{ message: 'hi', asked_at_ms: 1000, outcome: 'unknown_outcome' }],
    }, 'alpha')).toThrow()
    // Valid historical read + deletion: failed entry when current_conversation_id is null
    const decodedConv = decodePersonalConversation({
      keeper_id: 'alpha',
      current_conversation_id: null,
      conversations: [
        { conversation_id: 'c-old', provider_account_id: 'pa-1', started_at_ms: 1_700_000_000_000 },
        { conversation_id: 'c-stuck', provider_account_id: 'pa-1', started_at_ms: 1_700_000_005_000, deletion: 'failed' },
      ],
      conversation_id: 'c-old',
      turns: [
        {
          message: 'hello',
          asked_at_ms: 1_700_000_001_000,
          outcome: 'answered',
          text: 'world',
          model: 'claude-sonnet-4-6',
          answered_at_ms: 1_700_000_002_000,
        },
        {
          message: 'retry',
          asked_at_ms: 1_700_000_003_000,
          outcome: 'failed',
          failure: 'no_quota',
          failed_at_ms: 1_700_000_004_000,
          model_may_have_read: true,
        },
        {
          message: 'interrupted',
          asked_at_ms: 1_700_000_005_000,
          outcome: 'unrecorded',
          model_may_have_read: true,
        },
      ],
    }, 'alpha', 'c-old')
    expect(decodedConv.conversations).toHaveLength(2)
    expect(decodedConv.conversations[1]?.deletion).toBe('failed')
    expect(decodedConv.turns).toHaveLength(3)

    // 5. POST /api/v1/auth/keepers/turn
    expect(() => decodePersonalTurnAnswer({
      keeper_id: 'alpha',
      runtime_id: 'rt-1',
      model: 'claude-sonnet-4-6',
      text: 'ok',
      conversation_id: 'c-1',
    }, 'alpha')).toThrow()
    expect(decodePersonalTurnAnswer({
      keeper_id: 'alpha',
      runtime_id: 'rt-1',
      model: 'codex-1',
      text: 'ephemeral answer',
    }, 'alpha')).toEqual({
      keeper_id: 'alpha',
      runtime_id: 'rt-1',
      model: 'codex-1',
      text: 'ephemeral answer',
      recorded: false,
      conversation_id: null,
      continued: null,
    })

    // 6. POST /conversation & DELETE /conversation/<id>
    expect(() => decodeStartedPersonalConversation({ keeper_id: 'alpha', conversation_id: '' }, 'alpha')).toThrow()
    expect(() => decodeDeletedPersonalConversation({ conversation_id: 'c-1', vendor_copy: 'deleted' }, 'c-1')).toThrow()
    expect(decodeDeletedPersonalConversation({ conversation_id: 'c-1', vendor_copy: 'may_remain' }, 'c-1')).toEqual({
      conversation_id: 'c-1',
      vendor_copy: 'may_remain',
    })

    // 7. Validators
    expect(validatePersonalKeeperName('..').ok).toBe(false)
    expect(validatePersonalKeeperName('bad/name').ok).toBe(false)
    expect(validatePersonalKeeperName('good_keeper-1.0').ok).toBe(true)
    expect(validatePersonalTurnMessage('   \n\t ').ok).toBe(false)
    expect(validatePersonalTurnMessage('a'.repeat(PERSONAL_KEEPER_MESSAGE_MAX_BYTES + 1)).ok).toBe(false)
    expect(validatePersonalTurnMessage('안녕').ok).toBe(true)
  })

  it('fails closed before calling fetch when session is not multi_account_signed_in and enforces strict assign key order + CSRF header', async () => {
    const fetchSpy = vi.fn()
    vi.stubGlobal('fetch', fetchSpy)

    // Single-user session must never hit /api/v1/auth/keepers*
    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: true,
      role: 'admin',
      canTokenAdmin: true,
      canTokenRead: true,
      workspaceId: 'default',
      authMethods: { google: false, github: false, dev_token: false },
    }
    expect((await fetchPersonalKeepersApi()).ok).toBe(false)
    expect((await fetchPersonalProviderAccountsApi()).ok).toBe(false)
    expect((await createPersonalKeeperApi('alpha')).ok).toBe(false)
    expect((await assignPersonalKeeperRuntimeApi('alpha', 'rt-1')).ok).toBe(false)
    expect((await fetchPersonalConversationApi('alpha')).ok).toBe(false)
    expect((await startPersonalConversationApi('alpha')).ok).toBe(false)
    expect((await sendPersonalKeeperTurnApi('alpha', 'hello')).ok).toBe(false)
    expect((await deletePersonalConversationApi('c-1')).ok).toBe(false)
    expect(fetchSpy).not.toHaveBeenCalled()

    // Multi-account worker: verify strict JSON key order on POST /assign + CSRF header + zero Authorization header
    authSession.value = makeMaSession('worker')
    const captured: { url: string; method: string; body: string | null; csrf: string | null; auth: string | null }[] = []
    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const headers = new Headers(init?.headers)
      captured.push({
        url: String(input),
        method: init?.method ?? 'GET',
        body: typeof init?.body === 'string' ? init.body : null,
        csrf: headers.get('x-masc-csrf-token'),
        auth: headers.get('authorization'),
      })
      return jsonResponse({ keeper_id: 'alpha', runtime_id: 'rt-claude-sonnet', record: 'assigned' })
    }))

    const assignRes = await assignPersonalKeeperRuntimeApi('alpha', 'rt-claude-sonnet')
    expect(assignRes.ok).toBe(true)
    expect(captured).toEqual([
      {
        url: '/api/v1/auth/keepers/assign',
        method: 'POST',
        body: '{"keeper_id":"alpha","runtime_id":"rt-claude-sonnet"}',
        csrf: 'csrf-worker-tok',
        auth: null,
      },
    ])
  })
})

describe('Multi-Account Personal Keepers UI flows (Worker & Admin)', () => {
  beforeEach(() => {
    resetAuthStateForTests()
    resetObserverStateForTests()
    resetPortraitCacheForTests()
    resetRouterForTests('/keepers')
    resetShellStateForTests()
    resourceCache.clearAll()
  })

  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  it('supports full MA Worker personal keeper lifecycle: list, create, assign, read/switch/start/turn/delete conversations with zero SU /api/v1/keepers/* 404 calls', async () => {
    authSession.value = makeMaSession('worker')
    const seenRequests: { method: string; url: string; body: string | null }[] = []
    let keepersState: { keeper_id: string; runtime_id: string | null }[] = [
      { keeper_id: 'alpha', runtime_id: 'rt-claude-sonnet' },
    ]
    let conversationsState: {
      conversation_id: string
      provider_account_id: string
      started_at_ms: number
      deletion?: 'failed'
    }[] = [
      { conversation_id: 'conv-old-1', provider_account_id: 'pa-claude-1', started_at_ms: 1_700_000_000_000 },
      { conversation_id: 'conv-cur-2', provider_account_id: 'pa-claude-1', started_at_ms: 1_700_000_100_000 },
      { conversation_id: 'conv-bad-3', provider_account_id: 'pa-claude-1', started_at_ms: 1_700_000_150_000, deletion: 'failed' },
    ]
    let currentConvId: string | null = 'conv-cur-2'
    const turnsByConv: Record<string, Record<string, unknown>[]> = {
      'conv-old-1': [
        {
          message: 'Earlier question',
          asked_at_ms: 1_700_000_010_000,
          outcome: 'answered',
          text: 'Earlier answer',
          model: 'claude-sonnet-4-6',
          answered_at_ms: 1_700_000_020_000,
        },
      ],
      'conv-cur-2': [
        {
          message: 'Failed prompt',
          asked_at_ms: 1_700_000_110_000,
          outcome: 'failed',
          failure: 'no_quota',
          failed_at_ms: 1_700_000_115_000,
          model_may_have_read: true,
        },
      ],
    }

    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      const method = (init?.method ?? 'GET').toUpperCase()
      const body = typeof init?.body === 'string' ? init.body : null
      seenRequests.push({ method, url, body })

      if (method === 'GET' && url === '/api/v1/auth/keepers') {
        return jsonResponse({ keepers: keepersState })
      }
      if (method === 'GET' && url === '/api/v1/auth/provider-accounts') {
        return jsonResponse(SAMPLE_PROVIDER_ACCOUNTS)
      }
      if (method === 'POST' && url === '/api/v1/auth/keepers') {
        const parsed = JSON.parse(body ?? '{}') as { keeper_id: string }
        keepersState = [...keepersState, { keeper_id: parsed.keeper_id, runtime_id: null }]
        return jsonResponse({ keeper_id: parsed.keeper_id, record: 'made' })
      }
      if (method === 'POST' && url === '/api/v1/auth/keepers/assign') {
        const parsed = JSON.parse(body ?? '{}') as { keeper_id: string; runtime_id: string }
        keepersState = keepersState.map((k) =>
          k.keeper_id === parsed.keeper_id ? { ...k, runtime_id: parsed.runtime_id } : k,
        )
        return jsonResponse({ keeper_id: parsed.keeper_id, runtime_id: parsed.runtime_id, record: 'assigned' })
      }
      if (method === 'GET' && url.startsWith('/api/v1/auth/keepers/conversation?')) {
        const params = new URLSearchParams(url.split('?')[1] ?? '')
        const keeperId = params.get('keeper_id') ?? ''
        const reqConvId = params.get('conversation_id')
        const shownId = reqConvId ?? currentConvId
        return jsonResponse({
          keeper_id: keeperId,
          current_conversation_id: currentConvId,
          conversations: conversationsState,
          conversation_id: shownId,
          turns: shownId ? (turnsByConv[shownId] ?? []) : [],
        })
      }
      if (method === 'POST' && url === '/api/v1/auth/keepers/turn') {
        const parsed = JSON.parse(body ?? '{}') as { keeper_id: string; message: string }
        const convId = currentConvId ?? 'conv-cur-2'
        turnsByConv[convId] = [
          ...(turnsByConv[convId] ?? []),
          {
            message: parsed.message,
            asked_at_ms: 1_700_000_200_000,
            outcome: 'answered',
            text: `Reply to: ${parsed.message}`,
            model: 'claude-sonnet-4-6',
            answered_at_ms: 1_700_000_201_000,
          },
        ]
        return jsonResponse({
          keeper_id: parsed.keeper_id,
          runtime_id: 'rt-claude-sonnet',
          model: 'claude-sonnet-4-6',
          text: `Reply to: ${parsed.message}`,
          conversation_id: convId,
          continued: true,
        })
      }
      if (method === 'POST' && url === '/api/v1/auth/keepers/conversation') {
        const parsed = JSON.parse(body ?? '{}') as { keeper_id: string }
        const newId = 'conv-new-4'
        currentConvId = newId
        conversationsState = [
          ...conversationsState,
          { conversation_id: newId, provider_account_id: 'pa-claude-1', started_at_ms: 1_700_000_300_000 },
        ]
        turnsByConv[newId] = []
        return jsonResponse({ keeper_id: parsed.keeper_id, conversation_id: newId })
      }
      if (method === 'DELETE' && url.startsWith('/api/v1/auth/keepers/conversation/')) {
        const convId = decodeURIComponent(url.slice('/api/v1/auth/keepers/conversation/'.length))
        conversationsState = conversationsState.filter((c) => c.conversation_id !== convId)
        if (currentConvId === convId) currentConvId = null
        return jsonResponse({ conversation_id: convId, vendor_copy: 'may_remain' })
      }
      throw new Error(`Unexpected request: ${method} ${url}`)
    }))

    const onNavigate = vi.fn()
    const view = render(html`<${KeepersWorkspace} subroute="" onNavigate=${onNavigate} onInspect=${vi.fn()} />`)

    // 1. Renders personal keeper list + current conversation failed turn with model_may_have_read notice
    await waitFor(() => {
      expect(view.getByTestId('ma-turn-failed')).toBeTruthy()
      expect(view.container.textContent).toContain('모델이 이 메시지를 읽었을 수 있습니다')
    })

    // 2. Switch to historical conversation -> read-only banner + earlier turn shown
    fireEvent.click(view.container.querySelector('[data-conversation-id="conv-old-1"] .kp-ma-conv-select')!)
    await waitFor(() => {
      expect(view.getByTestId('ma-historical-banner')).toBeTruthy()
      expect(view.container.textContent).toContain('Earlier answer')
    })

    // Return to current conversation
    fireEvent.click(view.getByRole('button', { name: '현재 대화로 이동' }))
    await waitFor(() => {
      expect(view.queryByTestId('ma-historical-banner')).toBeNull()
    })

    // 3. Send a synchronous turn and confirm transcript updates from authoritative re-read
    const textarea = view.getByLabelText('개인 Keeper 메시지 입력')
    fireEvent.input(textarea, { target: { value: 'Hello personal keeper' } })
    fireEvent.click(view.getByTestId('ma-send-turn-btn'))
    await waitFor(() => {
      expect(view.container.textContent).toContain('Reply to: Hello personal keeper')
    })

    // 4. Reassign runtime via header dropdown -> strict key order body
    const rtSelect = view.getByTestId('ma-header-runtime-select') as HTMLSelectElement
    rtSelect.value = 'rt-claude-opus'
    fireEvent(rtSelect, new Event('change', { bubbles: true }))
    await waitFor(() => {
      expect((view.getByTestId('ma-header-assign-btn') as HTMLButtonElement).disabled).toBe(false)
    })
    fireEvent.click(view.getByTestId('ma-header-assign-btn'))
    await waitFor(() => {
      expect(view.getByTestId('ma-keeper-runtime-pill').textContent).toContain('rt-claude-opus')
    })
    const assignReq = seenRequests.find((r) => r.url === '/api/v1/auth/keepers/assign')
    expect(assignReq?.body).toBe('{"keeper_id":"alpha","runtime_id":"rt-claude-opus"}')

    // 5. Start new conversation
    fireEvent.click(view.getByTestId('ma-new-conversation-btn'))
    await waitFor(() => {
      expect(view.container.querySelector('[data-conversation-id="conv-new-4"]')).not.toBeNull()
    })

    // 6. Retry deleting the failed-deletion conversation (conv-bad-3)
    fireEvent.click(view.getByTestId('ma-delete-conv-conv-bad-3'))
    fireEvent.click(view.getByTestId('ma-confirm-delete-conv-bad-3'))
    await waitFor(() => {
      expect(view.container.querySelector('[data-conversation-id="conv-bad-3"]')).toBeNull()
    })
    expect(shellToasts.value.some((t) => t.message.includes('공급자 측 사본'))).toBe(true)

    // 7. Create a new personal keeper with initial runtime
    fireEvent.click(view.getByTestId('ma-create-keeper-btn'))
    fireEvent.input(view.getByLabelText('개인 Keeper 이름'), { target: { value: 'worker-bot' } })
    const modalRtSelect = view.getByLabelText('초기 연결 런타임') as HTMLSelectElement
    modalRtSelect.value = 'rt-claude-sonnet'
    fireEvent(modalRtSelect, new Event('change', { bubbles: true }))
    fireEvent.click(view.getByTestId('ma-create-keeper-submit'))
    await waitFor(() => {
      expect(onNavigate).toHaveBeenCalledWith('/keepers/worker-bot/chat')
    })
    expect(seenRequests.some((r) => r.method === 'POST' && r.url === '/api/v1/auth/keepers' && r.body === '{"keeper_id":"worker-bot"}')).toBe(true)
    expect(seenRequests.some((r) => r.method === 'POST' && r.url === '/api/v1/auth/keepers/assign' && r.body === '{"keeper_id":"worker-bot","runtime_id":"rt-claude-sonnet"}')).toBe(true)

    // 8. ZERO single-user 404 endpoints were ever called
    expect(seenRequests.some((r) =>
      r.url.startsWith('/api/v1/keepers')
      || r.url.startsWith('/api/v1/gate/keepers')
      || r.url.includes('portrait.png')
      || r.url.startsWith('/api/v1/config/schema')
      || r.url.startsWith('/api/v1/infra/sandboxes'),
    )).toBe(false)
  })

  it('keeps SU-only tabs (memory, portrait-candle, work-sandbox, config) honest in MA Admin and rejects malformed payloads without silent fallback', async () => {
    authSession.value = makeMaSession('admin')
    const seenUrls: string[] = []

    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      seenUrls.push(url)
      if (url === '/api/v1/auth/keepers') {
        return jsonResponse({ keepers: [{ keeper_id: 'admin-keeper', runtime_id: 'rt-claude-sonnet' }] })
      }
      if (url === '/api/v1/auth/provider-accounts') {
        return jsonResponse(SAMPLE_PROVIDER_ACCOUNTS)
      }
      throw new Error(`Unexpected SU fetch in MA SU-only tab: ${url}`)
    }))

    for (const tab of ['memory', 'portrait-candle', 'work-sandbox', 'config'] as const) {
      seenUrls.length = 0
      const view = render(
        html`<${KeepersWorkspace} subroute="detail" entityId="admin-keeper" entityTab=${tab} onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      )
      await waitFor(() => {
        const notice = view.getByTestId('ma-keeper-su-only-tab')
        expect(notice.getAttribute('data-tab')).toBe(tab)
      })
      expect(seenUrls.some((u) =>
        u.startsWith('/api/v1/keepers')
        || u.startsWith('/api/v1/config/schema')
        || u.startsWith('/api/v1/infra/sandboxes')
        || u.startsWith('/api/v1/candle/ledger'),
      )).toBe(false)
      view.unmount()
    }

    // Malformed /api/v1/auth/keepers payload surfaces explicit decode error instead of empty list
    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url === '/api/v1/auth/keepers') {
        return jsonResponse({ keepers: [null] })
      }
      return jsonResponse(SAMPLE_PROVIDER_ACCOUNTS)
    }))
    const badView = render(html`<${KeepersWorkspace} subroute="" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`)
    await waitFor(() => {
      expect(badView.getByTestId('ma-keepers-list-error').textContent).toContain('서버 응답 형식이 계약과 다릅니다')
    })
    badView.unmount()
  })

  it('subscribes to GET /api/v1/auth/events keeper preview/chat events without roster storms and aborts/purges cleanly on sign-out and epoch change', async () => {
    authSession.value = makeMaSession('worker', 'acct-alice', 'csrf-alice')
    let keeperListCalls = 0
    let convReadCalls = 0
    let abortedTurnSignal: AbortSignal | null = null
    let releaseSlowTurn!: () => void

    const encoder = new TextEncoder()
    let sseController!: ReadableStreamDefaultController<Uint8Array>
    const sseStream = new ReadableStream<Uint8Array>({
      start(controller) {
        sseController = controller
      },
    })

    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      const method = (init?.method ?? 'GET').toUpperCase()
      if (url === '/api/v1/auth/events') {
        return new Response(sseStream, { status: 200, headers: { 'Content-Type': 'text/event-stream' } })
      }
      if (method === 'GET' && url === '/api/v1/auth/keepers') {
        keeperListCalls += 1
        return jsonResponse({ keepers: [{ keeper_id: 'alice-keeper', runtime_id: 'rt-claude-sonnet' }] })
      }
      if (method === 'GET' && url === '/api/v1/auth/provider-accounts') {
        return jsonResponse(SAMPLE_PROVIDER_ACCOUNTS)
      }
      if (method === 'GET' && url.startsWith('/api/v1/auth/keepers/conversation?')) {
        convReadCalls += 1
        return jsonResponse({
          keeper_id: 'alice-keeper',
          current_conversation_id: 'c-alice',
          conversations: [{ conversation_id: 'c-alice', provider_account_id: 'pa-claude-1', started_at_ms: 1_700_000_000_000 }],
          conversation_id: 'c-alice',
          turns: [{
            message: 'Secret Alice prompt',
            asked_at_ms: 1_700_000_001_000,
            outcome: 'answered',
            text: 'Secret Alice reply',
            model: 'claude-sonnet-4-6',
            answered_at_ms: 1_700_000_002_000,
          }],
        })
      }
      if (method === 'POST' && url === '/api/v1/auth/keepers/turn') {
        abortedTurnSignal = init?.signal ?? null
        return await new Promise<Response>((_resolve, reject) => {
          releaseSlowTurn = () => reject(new DOMException('Aborted', 'AbortError'))
          init?.signal?.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true })
        })
      }
      throw new Error(`Unexpected request: ${method} ${url}`)
    }))

    // Start shared MA observer stream (`GET /api/v1/auth/events`)
    const streamPromise = startObserverStream({ autoReconnect: false })
    const view = render(html`<${KeepersWorkspace} subroute="" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`)

    await waitFor(() => {
      expect(view.container.textContent).toContain('Secret Alice reply')
    })
    const listCallsBeforePreview = keeperListCalls

    // Push keeper_turn_preview_changed over /api/v1/auth/events -> updates live preview banner WITHOUT reloading roster
    act(() => {
      sseController.enqueue(encoder.encode(
        `data: ${JSON.stringify({
          type: 'keeper_turn_preview_changed',
          name: 'kp-engine-1',
          observation: { preview: { status_text: 'Thinking on patch', activity: 'streaming', text_tail: 'Checking diff…' } },
        })}\n\n`,
      ))
    })

    await waitFor(() => {
      const strip = view.getByTestId('ma-keeper-observer-signal')
      expect(strip.textContent).toContain('Thinking on patch')
      expect(strip.textContent).toContain('Checking diff…')
    })
    expect(keeperListCalls).toBe(listCallsBeforePreview)

    // Verify observer frame decoder ignores unrelated non-keeper frames cleanly
    expect(decodePersonalKeeperObserverFrame({ id: '1', event: 'message', data: { type: 'heartbeat' }, raw: '' })).toBeNull()

    // Start a slow turn, then simulate sign-out + sessionEpoch bump -> aborts in-flight turn & purges Alice's state
    fireEvent.input(view.getByLabelText('개인 Keeper 메시지 입력'), { target: { value: 'In-flight turn before logout' } })
    fireEvent.click(view.getByTestId('ma-send-turn-btn'))
    await waitFor(() => {
      expect(abortedTurnSignal).not.toBeNull()
      expect(view.getByTestId('ma-turn-pending')).toBeTruthy()
    })

    act(() => {
      authSession.value = {
        kind: 'multi_account_signed_out',
        mode: 'multi_account',
        authMethods: { google: true, github: true, dev_token: false },
      }
      bumpSessionEpoch()
    })

    await waitFor(() => {
      expect(view.getByTestId('keepers-mode-notice')).toBeTruthy()
    })
    expect(abortedTurnSignal!.aborted).toBe(true)
    expect(view.container.textContent).not.toContain('Secret Alice reply')
    expect(view.container.textContent).not.toContain('alice-keeper')
    expect(convReadCalls).toBeGreaterThanOrEqual(1)

    try { sseController.close() } catch { /* stream already cancelled by epoch bump */ }
    releaseSlowTurn()
    await streamPromise.catch(() => {})
  })

  it('handles ephemeral turn replies, preserves draft on turn error with conversation re-read, and purges state across account switches', async () => {
    authSession.value = makeMaSession('worker', 'acct-alice', 'csrf-alice')
    let turnAttempt = 0
    let convReads = 0

    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      const method = (init?.method ?? 'GET').toUpperCase()
      const currentAccount = authSession.peek().kind === 'multi_account_signed_in'
        ? (authSession.peek() as Extract<AuthSession, { readonly kind: 'multi_account_signed_in' }>).accountId
        : ''

      if (method === 'GET' && url === '/api/v1/auth/keepers') {
        return jsonResponse({
          keepers: currentAccount === 'acct-bob'
            ? [{ keeper_id: 'bob-keeper', runtime_id: null }]
            : [{ keeper_id: 'alice-ephemeral', runtime_id: 'rt-claude-sonnet' }],
        })
      }
      if (method === 'GET' && url === '/api/v1/auth/provider-accounts') {
        return jsonResponse(SAMPLE_PROVIDER_ACCOUNTS)
      }
      if (method === 'GET' && url.startsWith('/api/v1/auth/keepers/conversation?')) {
        convReads += 1
        const params = new URLSearchParams(url.split('?')[1] ?? '')
        return jsonResponse({
          keeper_id: params.get('keeper_id'),
          current_conversation_id: null,
          conversations: [],
          conversation_id: null,
          turns: [],
        })
      }
      if (method === 'POST' && url === '/api/v1/auth/keepers/turn') {
        turnAttempt += 1
        if (turnAttempt === 1) {
          return jsonResponse({ error: 'No quota left.', code: 'no_quota' }, 429)
        }
        return jsonResponse({
          keeper_id: 'alice-ephemeral',
          runtime_id: 'rt-claude-sonnet',
          model: 'codex-ephemeral',
          text: 'One-shot ephemeral reply',
        })
      }
      throw new Error(`Unexpected request: ${method} ${url}`)
    }))

    const view = render(html`<${KeepersWorkspace} subroute="" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`)
    await waitFor(() => {
      expect(view.getByTestId('ma-conversation-empty')).toBeTruthy()
    })
    const readsBeforeError = convReads

    // 1. 429 no_quota -> surfaces code-mapped Korean error, preserves draft, and re-reads conversation
    const textarea = view.getByLabelText('개인 Keeper 메시지 입력') as HTMLTextAreaElement
    fireEvent.input(textarea, { target: { value: 'Keep this draft on error' } })
    fireEvent.click(view.getByTestId('ma-send-turn-btn'))
    await waitFor(() => {
      expect(view.getByTestId('ma-turn-action-error').textContent).toContain('할당량')
    })
    expect((view.getByLabelText('개인 Keeper 메시지 입력') as HTMLTextAreaElement).value).toBe('Keep this draft on error')
    expect(convReads).toBeGreaterThan(readsBeforeError)

    // 2. Retry succeeds with ephemeral (unrecorded) answer -> clears draft and displays honest ephemeral card
    fireEvent.click(view.getByTestId('ma-send-turn-btn'))
    await waitFor(() => {
      expect(view.getByTestId('ma-ephemeral-reply').textContent).toContain('One-shot ephemeral reply')
      expect(view.getByTestId('ma-ephemeral-reply').textContent).toContain('일회성 응답 (미저장)')
    })
    expect((view.getByLabelText('개인 Keeper 메시지 입력') as HTMLTextAreaElement).value).toBe('')

    // 3. Account switch (acct-alice -> acct-bob) remounts workspace, purges Alice's ephemeral reply & loads Bob's keeper
    act(() => {
      authSession.value = makeMaSession('admin', 'acct-bob', 'csrf-bob')
      bumpSessionEpoch()
    })
    await waitFor(() => {
      expect(view.container.textContent).toContain('bob-keeper')
    })
    expect(view.container.textContent).not.toContain('alice-ephemeral')
    expect(view.container.textContent).not.toContain('One-shot ephemeral reply')
  })

  it('keeps retry UI visible when DELETE on viewed historical conversation returns 503 conversation_not_deleted and skips follow-up GET on 401', async () => {
    authSession.value = makeMaSession('worker')
    let deletionFailed = false
    const seenConvGets: string[] = []
    let turnShouldReturn401 = false

    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      const method = (init?.method ?? 'GET').toUpperCase()

      if (method === 'GET' && url === '/api/v1/auth/keepers') {
        return jsonResponse({ keepers: [{ keeper_id: 'alpha', runtime_id: 'rt-claude-sonnet' }] })
      }
      if (method === 'GET' && url === '/api/v1/auth/provider-accounts') {
        return jsonResponse(SAMPLE_PROVIDER_ACCOUNTS)
      }
      if (method === 'GET' && url.startsWith('/api/v1/auth/keepers/conversation?')) {
        seenConvGets.push(url)
        const params = new URLSearchParams(url.split('?')[1] ?? '')
        const reqConvId = params.get('conversation_id')
        // Mirrors server_preview_keeper_conversation.ml:120-124: Deletion_failed returns 404 when queried by id
        if (reqConvId === 'conv-hist-1' && deletionFailed) {
          return jsonResponse({ error: 'No conversation of this Keeper has this id.', code: 'unknown_conversation' }, 404)
        }
        return jsonResponse({
          keeper_id: 'alpha',
          current_conversation_id: 'conv-cur-2',
          conversations: [
            {
              conversation_id: 'conv-hist-1',
              provider_account_id: 'pa-claude-1',
              started_at_ms: 1_700_000_000_000,
              ...(deletionFailed ? { deletion: 'failed' } : {}),
            },
            {
              conversation_id: 'conv-cur-2',
              provider_account_id: 'pa-claude-1',
              started_at_ms: 1_700_000_100_000,
            },
          ],
          conversation_id: reqConvId ?? 'conv-cur-2',
          turns: reqConvId === 'conv-hist-1'
            ? [{
                message: 'Old question',
                asked_at_ms: 1_700_000_001_000,
                outcome: 'answered',
                text: 'Old answer',
                model: 'claude-sonnet-4-6',
                answered_at_ms: 1_700_000_002_000,
              }]
            : [{
                message: 'Current question',
                asked_at_ms: 1_700_000_101_000,
                outcome: 'answered',
                text: 'Current answer kept on 401',
                model: 'claude-sonnet-4-6',
                answered_at_ms: 1_700_000_102_000,
              }],
        })
      }
      if (method === 'DELETE' && url === '/api/v1/auth/keepers/conversation/conv-hist-1') {
        deletionFailed = true
        return jsonResponse({ error: 'Files could not all be removed.', code: 'conversation_not_deleted' }, 503)
      }
      if (method === 'POST' && url === '/api/v1/auth/keepers/turn' && turnShouldReturn401) {
        return jsonResponse({ error: 'Session expired.' }, 401)
      }
      throw new Error(`Unexpected request: ${method} ${url}`)
    }))

    const view = render(html`<${KeepersWorkspace} subroute="" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`)
    await waitFor(() => {
      expect(view.container.textContent).toContain('Current answer kept on 401')
    })

    // 1. Open historical conv-hist-1, then delete it and receive 503 conversation_not_deleted
    fireEvent.click(view.container.querySelector('[data-conversation-id="conv-hist-1"] .kp-ma-conv-select')!)
    await waitFor(() => {
      expect(view.container.textContent).toContain('Old answer')
    })
    seenConvGets.length = 0

    fireEvent.click(view.getByTestId('ma-delete-conv-conv-hist-1'))
    fireEvent.click(view.getByTestId('ma-confirm-delete-conv-hist-1'))

    await waitFor(() => {
      expect(view.getByTestId('ma-turn-action-error').textContent).toContain('삭제 실패 상태')
      expect(view.getByTestId('ma-delete-conv-conv-hist-1').textContent).toContain('삭제 재시도')
    })
    // Must re-read keeper's current view without conversation_id=conv-hist-1 (zero 404s)
    expect(seenConvGets).toEqual(['/api/v1/auth/keepers/conversation?keeper_id=alpha'])
    expect(view.queryByTestId('ma-conversation-error')).toBeNull()
    expect(view.container.textContent).toContain('Current answer kept on 401')

    // 2. When a mutation returns 401 unauthorized, skip follow-up GET so transcript is not wiped
    turnShouldReturn401 = true
    seenConvGets.length = 0
    fireEvent.input(view.getByLabelText('개인 Keeper 메시지 입력'), { target: { value: 'Expired session msg' } })
    fireEvent.click(view.getByTestId('ma-send-turn-btn'))
    await waitFor(() => {
      expect(view.getByTestId('ma-turn-action-error').textContent).toContain('세션이 만료')
    })
    expect(seenConvGets).toEqual([])
    expect(view.container.textContent).toContain('Current answer kept on 401')
  })

  it('fires zero duplicate or aborted conversation GETs after an SSE refresh tick across historical, keeper, and tab switches', async () => {
    authSession.value = makeMaSession('worker')
    const convRequests: { url: string; aborted: boolean }[] = []

    const encoder = new TextEncoder()
    let sseController!: ReadableStreamDefaultController<Uint8Array>
    const sseStream = new ReadableStream<Uint8Array>({
      start(controller) {
        sseController = controller
      },
    })

    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (url === '/api/v1/auth/events') {
        return new Response(sseStream, { status: 200, headers: { 'Content-Type': 'text/event-stream' } })
      }
      if (url === '/api/v1/auth/keepers') {
        return jsonResponse({
          keepers: [
            { keeper_id: 'alpha', runtime_id: 'rt-claude-sonnet' },
            { keeper_id: 'beta', runtime_id: 'rt-claude-sonnet' },
          ],
        })
      }
      if (url === '/api/v1/auth/provider-accounts') {
        return jsonResponse(SAMPLE_PROVIDER_ACCOUNTS)
      }
      if (url.startsWith('/api/v1/auth/keepers/conversation?')) {
        const entry = { url, aborted: false }
        convRequests.push(entry)
        init?.signal?.addEventListener('abort', () => { entry.aborted = true }, { once: true })
        const params = new URLSearchParams(url.split('?')[1] ?? '')
        const keeperId = params.get('keeper_id') ?? 'alpha'
        const reqConvId = params.get('conversation_id')
        return jsonResponse({
          keeper_id: keeperId,
          current_conversation_id: `cur-${keeperId}`,
          conversations: [
            { conversation_id: `old-${keeperId}`, provider_account_id: 'pa-claude-1', started_at_ms: 1_700_000_000_000 },
            { conversation_id: `cur-${keeperId}`, provider_account_id: 'pa-claude-1', started_at_ms: 1_700_000_100_000 },
          ],
          conversation_id: reqConvId ?? `cur-${keeperId}`,
          turns: [],
        })
      }
      throw new Error(`Unexpected request: ${url}`)
    }))

    const streamPromise = startObserverStream({ autoReconnect: false })
    const view = render(
      html`<${KeepersWorkspace} subroute="detail" entityId="alpha" entityTab="chat" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
    )
    await waitFor(() => {
      expect(convRequests).toHaveLength(1)
    })

    // Trigger an SSE keeper_chat_appended tick (450ms debounce -> externalRefreshTick becomes 1)
    act(() => {
      sseController.enqueue(encoder.encode(
        `data: ${JSON.stringify({ type: 'keeper_chat_appended', name: 'kp-alpha' })}\n\n`,
      ))
    })
    await waitFor(() => {
      expect(convRequests).toHaveLength(2)
    }, { timeout: 2000 })

    // 1. Click historical conversation after externalRefreshTick > 0 -> exactly 1 GET, 0 aborts
    convRequests.length = 0
    fireEvent.click(view.container.querySelector('[data-conversation-id="old-alpha"] .kp-ma-conv-select')!)
    await waitFor(() => {
      expect(view.getByTestId('ma-historical-banner')).toBeTruthy()
    })
    expect(convRequests).toEqual([{ url: '/api/v1/auth/keepers/conversation?keeper_id=alpha&conversation_id=old-alpha', aborted: false }])

    // 2. Return to current conversation -> exactly 1 GET, 0 aborts
    convRequests.length = 0
    fireEvent.click(view.getByRole('button', { name: '현재 대화로 이동' }))
    await waitFor(() => {
      expect(view.queryByTestId('ma-historical-banner')).toBeNull()
    })
    expect(convRequests).toEqual([{ url: '/api/v1/auth/keepers/conversation?keeper_id=alpha', aborted: false }])

    // 3. Switch to memory tab and back to chat -> fresh PersonalKeeperChatPanel fires exactly 1 GET, 0 aborts
    convRequests.length = 0
    view.rerender(
      html`<${KeepersWorkspace} subroute="detail" entityId="alpha" entityTab="memory" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
    )
    expect(view.getByTestId('ma-keeper-su-only-tab')).toBeTruthy()
    expect(convRequests).toEqual([])

    view.rerender(
      html`<${KeepersWorkspace} subroute="detail" entityId="alpha" entityTab="chat" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
    )
    await waitFor(() => {
      expect(convRequests).toHaveLength(1)
    })
    await new Promise((r) => setTimeout(r, 20))
    expect(convRequests).toEqual([{ url: '/api/v1/auth/keepers/conversation?keeper_id=alpha', aborted: false }])

    // 4. Switch to keeper beta -> exactly 1 GET, 0 aborts
    convRequests.length = 0
    view.rerender(
      html`<${KeepersWorkspace} subroute="detail" entityId="beta" entityTab="chat" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
    )
    await waitFor(() => {
      expect(convRequests).toHaveLength(1)
    })
    await new Promise((r) => setTimeout(r, 20))
    expect(convRequests).toEqual([{ url: '/api/v1/auth/keepers/conversation?keeper_id=beta', aborted: false }])

    try { sseController.close() } catch { /* stream closed */ }
    await streamPromise.catch(() => {})
  })

  it('flags hidden/blocked assigned runtimes as warn (재연결 필요) and emits a single toast when create succeeds but initial assign fails', async () => {
    authSession.value = makeMaSession('worker')
    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      const method = (init?.method ?? 'GET').toUpperCase()
      if (method === 'GET' && url === '/api/v1/auth/keepers') {
        return jsonResponse({ keepers: [{ keeper_id: 'stale-rt-keeper', runtime_id: 'rt-removed-99' }] })
      }
      if (method === 'GET' && url === '/api/v1/auth/provider-accounts') {
        return jsonResponse(SAMPLE_PROVIDER_ACCOUNTS)
      }
      if (method === 'GET' && url.startsWith('/api/v1/auth/keepers/conversation?')) {
        return jsonResponse({
          keeper_id: 'stale-rt-keeper',
          current_conversation_id: null,
          conversations: [],
          conversation_id: null,
          turns: [],
        })
      }
      if (method === 'POST' && url === '/api/v1/auth/keepers') {
        return jsonResponse({ keeper_id: 'fresh-bot', record: 'made' })
      }
      if (method === 'POST' && url === '/api/v1/auth/keepers/assign') {
        return jsonResponse({ error: 'No Runtime of yours has this id.' }, 404)
      }
      throw new Error(`Unexpected request: ${method} ${url}`)
    }))

    const view = render(html`<${KeepersWorkspace} subroute="" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`)
    await waitFor(() => {
      const pill = view.getByTestId('ma-keeper-runtime-pill')
      expect(pill.getAttribute('data-tone')).toBe('warn')
      expect(pill.textContent).toContain('재연결 필요')
    })

    // Create keeper succeeds, optional initial assign fails -> exactly 1 non-contradictory toast
    fireEvent.click(view.getByTestId('ma-create-keeper-btn'))
    fireEvent.input(view.getByLabelText('개인 Keeper 이름'), { target: { value: 'fresh-bot' } })
    const modalRtSelect = view.getByLabelText('초기 연결 런타임') as HTMLSelectElement
    modalRtSelect.value = 'rt-claude-sonnet'
    fireEvent(modalRtSelect, new Event('change', { bubbles: true }))
    fireEvent.click(view.getByTestId('ma-create-keeper-submit'))

    await waitFor(() => {
      expect(shellToasts.value).toHaveLength(1)
    })
    expect(shellToasts.value[0]?.tone).toBe('info')
    expect(shellToasts.value[0]?.message).toContain('런타임 연결에 실패했습니다')
  })
})
