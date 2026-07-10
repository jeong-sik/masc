import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  clearLspDiagnosticSnapshot,
  EMPTY_LSP_STATUS_SNAPSHOT,
  LspConnection,
  lspDiagnosticSnapshot,
  lspStatusSnapshot,
  parseLspStatusSnapshot,
  resolveLspDiagnosticFilePath,
} from './ide-lsp-client'
import {
  TRANSPORT_RETRY_BASE_MS,
  TRANSPORT_RETRY_MAX_ATTEMPTS,
} from '../../config/constants'
import { clearStoredToken, setStoredToken } from '../../api/core'

const mockSockets: MockWebSocket[] = []

class MockWebSocket {
  static CONNECTING = 0
  static OPEN = 1
  static CLOSING = 2
  static CLOSED = 3

  readyState = MockWebSocket.CONNECTING
  sent: string[] = []
  onopen: ((event: Event) => void) | null = null
  onmessage: ((event: MessageEvent) => void) | null = null
  onerror: ((event: Event) => void) | null = null
  onclose: ((event: CloseEvent) => void) | null = null
  failSend = false

  constructor(readonly url: string, readonly protocols?: string | string[]) {
    mockSockets.push(this)
  }

  send(data: string): void {
    if (this.readyState !== MockWebSocket.OPEN) throw new Error('socket not open')
    if (this.failSend) throw new Error('send failed')
    this.sent.push(data)
  }

  open(): void {
    this.readyState = MockWebSocket.OPEN
    this.onopen?.(new Event('open'))
  }

  message(payload: unknown): void {
    this.onmessage?.({ data: JSON.stringify(payload) } as MessageEvent)
  }

  close(event: Partial<Pick<CloseEvent, 'code' | 'reason' | 'wasClean'>> = {}): void {
    if (this.readyState === MockWebSocket.CLOSED) return
    this.readyState = MockWebSocket.CLOSED
    this.onclose?.({
      code: event.code ?? 1000,
      reason: event.reason ?? '',
      wasClean: event.wasClean ?? true,
    } as CloseEvent)
  }
}

function installWebSocketMock(): void {
  mockSockets.length = 0
  vi.stubGlobal('WebSocket', MockWebSocket)
}

afterEach(() => {
  vi.useRealTimers()
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
  lspDiagnosticSnapshot.value = new Map()
  lspStatusSnapshot.value = EMPTY_LSP_STATUS_SNAPSHOT
  clearStoredToken()
  mockSockets.length = 0
})

describe('resolveLspDiagnosticFilePath', () => {
  afterEach(() => {
    lspDiagnosticSnapshot.value = new Map()
  })

  it('keeps safe relative diagnostic URIs as IDE file paths', () => {
    expect(resolveLspDiagnosticFilePath(
      'file://lib/keeper/runtime.ml',
      'lib/keeper/current.ml',
    )).toBe('lib/keeper/runtime.ml')
  })

  it('maps absolute diagnostic URIs only when they match the current IDE file suffix', () => {
    expect(resolveLspDiagnosticFilePath(
      'file:///Users/dancer/me/workspace/yousleepwhen/masc/lib/keeper/current.ml',
      'lib/keeper/current.ml',
    )).toBe('lib/keeper/current.ml')
    expect(resolveLspDiagnosticFilePath(
      'file:///Users/dancer/me/workspace/yousleepwhen/masc/lib/keeper/other.ml',
      'lib/keeper/current.ml',
    )).toBeNull()
  })

  it('ignores missing or unsafe diagnostic URIs instead of falling back to the current file', () => {
    expect(resolveLspDiagnosticFilePath(undefined, 'lib/keeper/current.ml')).toBeNull()
    expect(resolveLspDiagnosticFilePath(
      'file:///tmp/current.ml',
      'lib/keeper/current.ml',
    )).toBeNull()
  })

})

describe('clearLspDiagnosticSnapshot', () => {
  afterEach(() => {
    lspDiagnosticSnapshot.value = new Map()
  })

  it('clears only the normalized diagnostic snapshot for the previous file', () => {
    lspDiagnosticSnapshot.value = new Map([
      [
        'lib/keeper/old.ml',
        [
          {
            file_path: 'lib/keeper/old.ml',
            line: 7,
            severity: 1,
            message: 'old diagnostic',
          },
        ],
      ],
      [
        'lib/keeper/current.ml',
        [
          {
            file_path: 'lib/keeper/current.ml',
            line: 3,
            severity: 2,
            message: 'current diagnostic',
          },
        ],
      ],
    ])

    clearLspDiagnosticSnapshot('lib\\keeper\\old.ml')

    expect(lspDiagnosticSnapshot.value.has('lib/keeper/old.ml')).toBe(false)
    expect(lspDiagnosticSnapshot.value.get('lib/keeper/current.ml')).toHaveLength(1)
  })
})

describe('LspConnection', () => {
  it('carries the stored dashboard bearer on the WebSocket upgrade', () => {
    installWebSocketMock()
    setStoredToken('lsp-token')

    const conn = new LspConnection(() => {}, () => {})
    conn.connect()

    expect(mockSockets[0]?.url).toBe('ws://localhost:3000/api/v1/ide/lsp')
    expect(mockSockets[0]?.protocols).toEqual([
      'masc.ide.v1',
      'masc.bearer.hex.6c73702d746f6b656e',
    ])
    conn.dispose()
  })

  it('reconnects the active LSP socket when the dashboard bearer changes', () => {
    installWebSocketMock()
    const conn = new LspConnection(() => {}, () => {})
    conn.connect()
    const first = mockSockets[0]!

    setStoredToken('fresh-lsp-token')

    expect(first.readyState).toBe(MockWebSocket.CLOSED)
    expect(mockSockets).toHaveLength(2)
    expect(mockSockets[1]?.url).toBe('ws://localhost:3000/api/v1/ide/lsp')
    expect(mockSockets[1]?.protocols).toEqual([
      'masc.ide.v1',
      'masc.bearer.hex.66726573682d6c73702d746f6b656e',
    ])
    conn.dispose()
  })

  it('publishes typed masc/lspStatus notifications', () => {
    installWebSocketMock()
    const conn = new LspConnection(() => {}, () => {})
    conn.connect()
    const socket = mockSockets[0]!
    socket.open()

    socket.message({
      jsonrpc: '2.0',
      method: 'masc/lspStatus',
      params: {
        langs: [{
          lang: 'ocaml',
          connected: false,
          overlay_only: true,
          command: 'ocamllsp',
          last_error: 'ocamllsp unavailable',
        }],
      },
    })

    expect(lspStatusSnapshot.value).toEqual({
      langs: [{
        lang: 'ocaml',
        connected: false,
        overlay_only: true,
        command: 'ocamllsp',
        last_error: 'ocamllsp unavailable',
      }],
    })
    conn.dispose()
  })

  it('rejects malformed masc/lspStatus payloads without mutating the snapshot', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    lspStatusSnapshot.value = {
      langs: [{
        lang: 'ocaml',
        connected: true,
        overlay_only: false,
        command: 'ocamllsp',
        last_error: null,
      }],
    }

    expect(parseLspStatusSnapshot({ langs: [{ lang: 'ocaml', connected: true }] }))
      .toBeNull()

    installWebSocketMock()
    const conn = new LspConnection(() => {}, () => {})
    conn.connect()
    const socket = mockSockets[0]!
    socket.open()
    socket.message({
      jsonrpc: '2.0',
      method: 'masc/lspStatus',
      params: { langs: [{ lang: 'ocaml', connected: true }] },
    })

    expect(warn).toHaveBeenCalledWith('[LSP] invalid masc/lspStatus payload')
    expect(lspStatusSnapshot.value.langs).toHaveLength(1)
    expect(lspStatusSnapshot.value.langs[0]?.connected).toBe(true)
    conn.dispose()
  })

  it('settles pending requests when the socket closes', async () => {
    installWebSocketMock()
    const conn = new LspConnection(() => {}, () => {})
    conn.connect()
    const socket = mockSockets[0]!
    socket.open()

    const hover = conn.requestHover('lib/keeper/current.ml', 0, 0)
    expect(socket.sent).toHaveLength(2)

    socket.close({ code: 1011, reason: 'server restart', wasClean: false })

    await expect(hover).resolves.toBeNull()
    conn.dispose()
  })

  it('ignores stale socket events after reconnecting', async () => {
    installWebSocketMock()
    const conn = new LspConnection(() => {}, () => {})
    conn.connect()
    const oldSocket = mockSockets[0]!
    oldSocket.open()

    conn.connect()
    const currentSocket = mockSockets[1]!
    currentSocket.open()

    const hover = conn.requestHover('lib/keeper/current.ml', 0, 0)
    expect(currentSocket.sent).toHaveLength(2)

    oldSocket.close({ code: 1006, wasClean: false })
    oldSocket.message({ id: 3, result: { contents: 'stale' } })

    currentSocket.message({ id: 3, result: { contents: 'current' } })

    await expect(hover).resolves.toEqual({ contents: 'current' })
    conn.dispose()
  })

  it('cancels scheduled reconnect when disposed', () => {
    vi.useFakeTimers()
    installWebSocketMock()
    const conn = new LspConnection(() => {}, () => {})
    conn.connect()
    const socket = mockSockets[0]!

    socket.close({ code: 1006, wasClean: false })
    conn.dispose()
    vi.advanceTimersByTime(5000)

    expect(mockSockets).toHaveLength(1)
  })

  it('uses exponential reconnect delays while the LSP socket stays down', () => {
    vi.useFakeTimers()
    vi.spyOn(Math, 'random').mockReturnValue(0)
    installWebSocketMock()
    const conn = new LspConnection(() => {}, () => {})
    conn.connect()
    const firstSocket = mockSockets[0]!

    firstSocket.close({ code: 1006, wasClean: false })
    vi.advanceTimersByTime(TRANSPORT_RETRY_BASE_MS - 1)
    expect(mockSockets).toHaveLength(1)
    vi.advanceTimersByTime(1)
    expect(mockSockets).toHaveLength(2)

    mockSockets[1]!.close({ code: 1006, wasClean: false })
    vi.advanceTimersByTime((TRANSPORT_RETRY_BASE_MS * 2) - 1)
    expect(mockSockets).toHaveLength(2)
    vi.advanceTimersByTime(1)
    expect(mockSockets).toHaveLength(3)
    conn.dispose()
  })

  it('stops reconnecting after the retry budget is exhausted', () => {
    vi.useFakeTimers()
    vi.spyOn(Math, 'random').mockReturnValue(0)
    installWebSocketMock()
    const errors: unknown[] = []
    const conn = new LspConnection(() => {}, err => errors.push(err))
    conn.connect()

    for (let attempt = 1; attempt <= TRANSPORT_RETRY_MAX_ATTEMPTS; attempt += 1) {
      mockSockets[mockSockets.length - 1]!.close({ code: 1006, wasClean: false })
      vi.advanceTimersByTime(60_000)
      expect(mockSockets).toHaveLength(attempt + 1)
    }

    mockSockets[mockSockets.length - 1]!.close({ code: 1006, wasClean: false })
    vi.advanceTimersByTime(60_000)

    expect(mockSockets).toHaveLength(TRANSPORT_RETRY_MAX_ATTEMPTS + 1)
    expect(errors.some(err => err instanceof Error && err.message.includes('exhausted'))).toBe(true)
    conn.dispose()
  })

  it('does not reconnect after terminal LSP close codes', async () => {
    vi.useFakeTimers()
    installWebSocketMock()
    const errors: unknown[] = []
    const conn = new LspConnection(() => {}, err => errors.push(err))
    conn.connect()
    const socket = mockSockets[0]!
    socket.open()
    const hover = conn.requestHover('lib/keeper/current.ml', 0, 0)

    socket.close({ code: 4401, reason: 'unauthorized', wasClean: false })
    vi.advanceTimersByTime(60_000)

    await expect(hover).resolves.toBeNull()
    expect(mockSockets).toHaveLength(1)
    expect(errors.some(err => err instanceof Error && err.message.includes('4401'))).toBe(true)
    conn.dispose()
  })

  it('notifies readiness after initial connect and reconnect initialize', async () => {
    vi.useFakeTimers()
    installWebSocketMock()
    const onReady = vi.fn()
    const conn = new LspConnection(() => {}, () => {}, onReady)
    conn.connect()
    const firstSocket = mockSockets[0]!
    firstSocket.open()
    const firstInitialize = JSON.parse(firstSocket.sent[0]!) as { id: number }
    firstSocket.message({ id: firstInitialize.id, result: {} })
    await Promise.resolve()

    expect(onReady).toHaveBeenCalledTimes(1)

    firstSocket.close({ code: 1006, wasClean: false })
    vi.advanceTimersByTime(5000)
    const secondSocket = mockSockets[1]!
    secondSocket.open()
    const secondInitialize = JSON.parse(secondSocket.sent[0]!) as { id: number }
    secondSocket.message({ id: secondInitialize.id, result: {} })
    await Promise.resolve()

    expect(onReady).toHaveBeenCalledTimes(2)
    conn.dispose()
  })

  it('routes notification send failures through reconnect instead of throwing', async () => {
    vi.useFakeTimers()
    installWebSocketMock()
    const errors: unknown[] = []
    const conn = new LspConnection(() => {}, err => errors.push(err))
    conn.connect()
    const socket = mockSockets[0]!
    socket.open()
    const initialize = JSON.parse(socket.sent[0]!) as { id: number }
    socket.message({ id: initialize.id, result: {} })
    await Promise.resolve()

    expect(socket.sent).toHaveLength(2)
    socket.failSend = true

    expect(() => conn.notifyDidOpen('lib/keeper/current.ml', 'ocaml')).not.toThrow()
    expect(errors).toHaveLength(1)
    expect(socket.readyState).toBe(MockWebSocket.CLOSED)

    vi.advanceTimersByTime(5000)
    expect(mockSockets).toHaveLength(2)
    conn.dispose()
  })
})
