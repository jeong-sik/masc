import { afterEach, describe, expect, it, vi } from 'vitest'
import { h, render } from 'preact'
import { waitFor } from '@testing-library/preact'
import { IdeEditor } from './ide-editor'
import { createKeeperLineOwnershipStore } from './keeper-line-ownership-store'
import { EditorState } from '@codemirror/state'
import { EditorView } from '@codemirror/view'
import { lspDocumentStatus } from './ide-lsp-document-status'
import { createCodeDocumentStore } from './code-document-store'
import {
  clearLspDiagnosticSnapshot,
  EMPTY_LSP_STATUS_SNAPSHOT,
  LspConnection,
  lspDiagnosticSnapshot,
  lspExtension,
  lspScopeKey,
  lspStatusRejected,
  lspStatusSnapshot,
  parseLspStatusSnapshot,
  publishLspScope,
  resolveLspDiagnosticFilePath,
} from './ide-lsp-client'
import {
  TRANSPORT_RETRY_BASE_MS,
  TRANSPORT_RETRY_MAX_MS,
} from '../../config/constants'

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

  constructor(readonly url: string) {
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

const MOCK_WORKSPACE_ROOT = '/workspace/masc'

async function completeHandshake(socket: MockWebSocket, workspaceRoot = MOCK_WORKSPACE_ROOT): Promise<void> {
  socket.open()
  const initialize = JSON.parse(socket.sent[0]!) as { id: number }
  socket.message({
    id: initialize.id,
    result: { masc: { workspaceRoot } },
  })
  await Promise.resolve()
  await Promise.resolve()
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
  lspStatusRejected.value = false
  lspDocumentStatus.value = null
  mockSockets.length = 0
  // The published scope is process-wide, so a case that declares one must not
  // decide what the next case connects with.
  publishLspScope({ repoId: null, codebase: null, keeper: null })
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
          command: 'ocamllsp',
          last_error: 'ocamllsp unavailable',
        }],
      },
    })

    expect(lspStatusSnapshot.value).toEqual({
      langs: [{
        lang: 'ocaml',
        connected: false,
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
    // The kept snapshot is now a past reading, and the statusbar has to be
    // able to say so rather than present it as the current one.
    expect(lspStatusRejected.value).toBe(true)
    conn.dispose()
  })

  it('clears the rejection once a readable payload arrives', () => {
    vi.spyOn(console, 'warn').mockImplementation(() => {})
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
    expect(lspStatusRejected.value).toBe(true)

    socket.message({
      jsonrpc: '2.0',
      method: 'masc/lspStatus',
      params: {
        langs: [{ lang: 'ocaml', connected: true, command: 'ocamllsp', last_error: null }],
      },
    })
    expect(lspStatusRejected.value).toBe(false)
    expect(lspStatusSnapshot.value.langs).toHaveLength(1)
    conn.dispose()
  })

  it('settles pending requests when the socket closes', async () => {
    installWebSocketMock()
    const conn = new LspConnection(() => {}, () => {})
    conn.connect()
    const socket = mockSockets[0]!
    await completeHandshake(socket)

    const hover = conn.requestHover('lib/keeper/current.ml', 0, 0)
    // initialize, initialized, then the document request: a document cannot
    // be named until the handshake reports the workspace tree.
    expect(socket.sent).toHaveLength(3)

    socket.close({ code: 1011, reason: 'server restart', wasClean: false })

    await expect(hover).resolves.toBeNull()
    conn.dispose()
  })

  it('ignores stale socket events after reconnecting', async () => {
    installWebSocketMock()
    const conn = new LspConnection(() => {}, () => {})
    conn.connect()
    const oldSocket = mockSockets[0]!
    await completeHandshake(oldSocket)

    conn.connect()
    const currentSocket = mockSockets[1]!
    await completeHandshake(currentSocket)

    const hover = conn.requestHover('lib/keeper/current.ml', 0, 0)
    // initialize, initialized, then the document request: a document cannot
    // be named until the handshake reports the workspace tree.
    expect(currentSocket.sent).toHaveLength(3)

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

  it('recovers diagnostics after a prolonged transport outage', async () => {
    vi.useFakeTimers()
    vi.spyOn(Math, 'random').mockReturnValue(0)
    installWebSocketMock()
    const diagnostics = vi.fn()
    const ready = vi.fn()
    const conn = new LspConnection(diagnostics, () => {}, ready)
    conn.connect()

    // Simulate a day of unsuccessful connections, then a server returning.
    let elapsed = 0
    while (elapsed < 24 * 60 * 60 * 1000) {
      mockSockets[mockSockets.length - 1]!.close({ code: 1006, wasClean: false })
      vi.advanceTimersByTime(TRANSPORT_RETRY_MAX_MS)
      elapsed += TRANSPORT_RETRY_MAX_MS
    }
    const recovered = mockSockets[mockSockets.length - 1]!
    conn.syncDocument('lib/example.ml', 'let source = missing\n')
    await completeHandshake(recovered)
    diagnostics.mockClear()
    recovered.message({ method: 'textDocument/publishDiagnostics', params: {
      uri: 'file:///workspace/masc/lib/example.ml',
      diagnostics: [{ range: { start: { line: 2, character: 0 }, end: { line: 2, character: 3 } }, message: 'Unbound value', severity: 1 }],
    } })
    expect(ready).toHaveBeenCalledTimes(1)
    expect(diagnostics).toHaveBeenCalledWith('file:///workspace/masc/lib/example.ml', expect.any(Map))
    expect(diagnostics.mock.calls[0]![1].get(3)[0].message).toBe('Unbound value')
    conn.dispose()
    expect(vi.getTimerCount()).toBe(0)
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
    firstSocket.message({ id: firstInitialize.id, result: { masc: { workspaceRoot: MOCK_WORKSPACE_ROOT } } })
    await Promise.resolve()

    expect(onReady).toHaveBeenCalledTimes(1)

    firstSocket.close({ code: 1006, wasClean: false })
    vi.advanceTimersByTime(5000)
    const secondSocket = mockSockets[1]!
    secondSocket.open()
    const secondInitialize = JSON.parse(secondSocket.sent[0]!) as { id: number }
    secondSocket.message({ id: secondInitialize.id, result: { masc: { workspaceRoot: MOCK_WORKSPACE_ROOT } } })
    await Promise.resolve()

    expect(onReady).toHaveBeenCalledTimes(2)
    conn.dispose()
  })

  // The connection URL is how the server learns which codebase this editor is
  // looking at: it picks the tree our repo-relative document paths resolve
  // against. Without it the server had to guess.
  it('declares the repository scope on the connection URL', () => {
    installWebSocketMock()
    publishLspScope({
      repoId: 'masc',
      codebase: 'github.com_jeong-sik_masc',
      keeper: null,
    })
    const conn = new LspConnection(() => {}, () => {})
    conn.connect()
    const url = new URL(mockSockets[0]!.url)
    expect(url.searchParams.get('repo_id')).toBe('masc')
    expect(url.searchParams.get('codebase')).toBe('github.com_jeong-sik_masc')
    conn.dispose()
  })

  it('declares a keeper workspace without fabricating an overlay scope', () => {
    installWebSocketMock()
    publishLspScope({ repoId: null, codebase: null, keeper: 'analyst' })
    const conn = new LspConnection(() => {}, () => {})
    conn.connect()
    const url = mockSockets[0]!.url
    expect(url).toContain('keeper=analyst')
    expect(url).not.toContain('codebase=')
    conn.dispose()
  })

  it('declares no scope when none is published', () => {
    installWebSocketMock()
    publishLspScope({ repoId: null, codebase: null, keeper: null })
    const conn = new LspConnection(() => {}, () => {})
    conn.connect()
    expect(mockSockets[0]!.url).toMatch(/\/api\/v1\/ide\/lsp$/)
    conn.dispose()
  })

  // A repo-relative path prefixed with `file://` is not an absolute URI — its
  // first segment lands in the authority slot — so the server rejected the
  // document as outside its workspace and answered empty.
  it('names documents with an absolute URI under the advertised root', async () => {
    installWebSocketMock()
    publishLspScope({
      repoId: 'masc',
      codebase: 'github.com_jeong-sik_masc',
      keeper: null,
    })
    const conn = new LspConnection(() => {}, () => {})
    conn.connect()
    const socket = mockSockets[0]!
    await completeHandshake(socket)

    void conn.requestCodeLenses('lib/keeper/current.ml')
    const request = JSON.parse(socket.sent[socket.sent.length - 1]!) as {
      params: { textDocument: { uri: string } }
    }
    expect(request.params.textDocument.uri).toBe(
      `file://${MOCK_WORKSPACE_ROOT}/lib/keeper/current.ml`,
    )
    conn.dispose()
  })

  // Before the handshake reports the tree there is no way to name a document,
  // so a request must be skipped rather than sent with a guessed path.
  it('sends no document request before the workspace root is known', async () => {
    installWebSocketMock()
    const conn = new LspConnection(() => {}, () => {})
    conn.connect()
    const socket = mockSockets[0]!
    socket.open()

    const lenses = await conn.requestCodeLenses('lib/keeper/current.ml')
    expect(lenses.size).toBe(0)
    expect(socket.sent).toHaveLength(1)
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
    socket.message({
      id: initialize.id,
      result: { masc: { workspaceRoot: MOCK_WORKSPACE_ROOT } },
    })
    await Promise.resolve()

    expect(socket.sent).toHaveLength(2)
    socket.failSend = true

    expect(() => conn.syncDocument('lib/keeper/current.ml', 'let value = 1\n')).not.toThrow()
    expect(errors).toHaveLength(1)
    expect(socket.readyState).toBe(MockWebSocket.CLOSED)

    vi.advanceTimersByTime(5000)
    expect(mockSockets).toHaveLength(2)
    conn.dispose()
  })
})

function wire(socket: MockWebSocket, method: string) {
  return socket.sent.map(value => JSON.parse(value)).filter(value => value.method === method)
}
function readyLanguage(socket: MockWebSocket) {
  socket.message({ method: 'masc/lspStatus', params: {
    langs: [{ lang: 'ocaml', connected: true, command: 'ocamllsp', last_error: null }],
  } })
}
const sourceDiagnostic = { range: { start: { line: 0, character: 4 }, end: { line: 0, character: 11 } },
  message: 'Unbound value missing', severity: 1 }

describe('selected document LSP continuity', () => {
  it('sends actual source on open and monotonic full changes on store updates', async () => {
    installWebSocketMock()
    const conn = new LspConnection(() => {}, () => {})
    conn.syncDocument('current.ml', 'let value = missing\n')
    conn.connect()
    const socket = mockSockets[0]!
    await completeHandshake(socket)
    expect(wire(socket, 'textDocument/didOpen')[0].params.textDocument).toEqual({
      uri: 'file:///workspace/masc/current.ml', languageId: 'ocaml', version: 1,
      text: 'let value = missing\n',
    })
    conn.syncDocument('current.ml', 'let value = 1\n')
    conn.syncDocument('current.ml', 'let value = 1\n')
    conn.syncDocument('current.ml', 'let value = 2\n')
    expect(wire(socket, 'textDocument/didChange').map(request => request.params)).toEqual([
      { textDocument: { uri: 'file:///workspace/masc/current.ml', version: 2 }, contentChanges: [{ text: 'let value = 1\n' }] },
      { textDocument: { uri: 'file:///workspace/masc/current.ml', version: 3 }, contentChanges: [{ text: 'let value = 2\n' }] },
    ])
    expect(lspDocumentStatus.value?.version).toBe(3)
    conn.dispose()
  })

  it('discards a delayed old-version pull and distinguishes failed diagnostics from true empty', async () => {
    installWebSocketMock()
    const conn = new LspConnection(() => {}, () => {})
    conn.syncDocument('current.ml', 'let value = missing\n')
    conn.connect()
    const socket = mockSockets[0]!
    await completeHandshake(socket)
    readyLanguage(socket)
    const old = conn.requestDiagnostics('current.ml')
    const rejectedOld = expect(old).rejects.toThrow('Superseded')
    const oldId = wire(socket, 'textDocument/diagnostic').at(-1).id
    conn.syncDocument('current.ml', 'let value = 1\n')
    socket.message({ id: oldId, result: { kind: 'full', items: [sourceDiagnostic] } })
    await rejectedOld
    expect(lspDocumentStatus.value?.diagnostics.kind).toBe('pending')
    const failed = conn.requestDiagnostics('current.ml')
    const rejectedFailed = expect(failed).rejects.toEqual({ code: -32603, message: 'analysis failed' })
    socket.message({ id: wire(socket, 'textDocument/diagnostic').at(-1).id,
      error: { code: -32603, message: 'analysis failed' } })
    await rejectedFailed
    expect(lspDocumentStatus.value?.diagnostics.kind).toBe('failed')
    const clean = conn.requestDiagnostics('current.ml')
    socket.message({ id: wire(socket, 'textDocument/diagnostic').at(-1).id, result: { kind: 'full', items: [] } })
    expect((await clean).size).toBe(0)
    expect(lspDocumentStatus.value?.diagnostics).toEqual({ kind: 'complete', count: 0 })
    conn.dispose()
  })

  it('rejects mismatched URI/version and keeps unversioned server reports explicitly unconfirmed', async () => {
    installWebSocketMock()
    const observed = vi.fn()
    const conn = new LspConnection(observed, () => {})
    conn.syncDocument('current.ml', 'let value = 1\n')
    conn.connect()
    const socket = mockSockets[0]!
    await completeHandshake(socket)
    readyLanguage(socket)
    conn.syncDocument('current.ml', 'let value = missing\n')
    observed.mockClear()
    const push = (uri: string, version?: number) => socket.message({ method: 'textDocument/publishDiagnostics',
      params: { uri, version, diagnostics: [sourceDiagnostic] } })
    push('file:///other/current.ml', 2)
    push('file:///workspace/masc/current.ml', 1)
    expect(observed).not.toHaveBeenCalled()
    push('file:///workspace/masc/current.ml')
    expect(observed).toHaveBeenCalledTimes(1)
    expect(lspDocumentStatus.value?.diagnostics.kind).toBe('unversioned')
    // Actual ocamllsp 1.27.0 uses unversioned push reports and rejects pull.
    const unsupported = conn.requestDiagnostics('current.ml')
    const rejected = expect(unsupported).rejects.toEqual({ code: -32603, message: 'Request not supported yet!' })
    socket.message({ id: wire(socket, 'textDocument/diagnostic').at(-1).id,
      error: { code: -32603, message: 'Request not supported yet!' } })
    await rejected
    expect(lspDocumentStatus.value?.diagnostics).toEqual({ kind: 'unversioned', count: 1 })
    push('file:///workspace/masc/current.ml', 2)
    expect(observed).toHaveBeenCalledTimes(2)
    expect(lspDocumentStatus.value?.diagnostics).toEqual({ kind: 'complete', count: 1 })
    conn.dispose()
  })

  it('changes repository scope even without a CodeMirror transaction and rejects old socket evidence', async () => {
    installWebSocketMock()
    publishLspScope({ repoId: 'repo-a', codebase: 'a', keeper: null })
    const observed = vi.fn()
    const conn = new LspConnection(observed, () => {})
    conn.syncDocument('current.ml', 'let value = 1\n')
    conn.connect()
    const first = mockSockets[0]!
    await completeHandshake(first)
    readyLanguage(first)
    publishLspScope({ repoId: 'repo-b', codebase: 'b', keeper: null })
    await Promise.resolve()
    const second = mockSockets[1]!
    expect(second.url).toContain('repo_id=repo-b')
    expect(lspStatusSnapshot.value.langs).toEqual([])
    expect(lspDocumentStatus.value).toBeNull()
    second.open()
    second.message({ id: wire(second, 'initialize')[0].id, result: { masc: { workspaceRoot: '/workspace/other' } } })
    await Promise.resolve()
    expect(wire(second, 'textDocument/didOpen')).toEqual([])
    conn.syncDocument('current.ml', 'let fresh_repository_value = 2\n')
    expect(wire(second, 'textDocument/didOpen')[0].params.textDocument.uri).toBe('file:///workspace/other/current.ml')
    observed.mockClear()
    first.message({ method: 'textDocument/publishDiagnostics', params: {
      uri: 'file:///workspace/masc/current.ml', version: 1, diagnostics: [sourceDiagnostic],
    } })
    expect(observed).not.toHaveBeenCalled()
    second.close({ code: 4401, reason: 'unauthorized' })
    expect(lspDocumentStatus.value?.connection.kind).toBe('disconnected')
    expect(lspStatusSnapshot.value.langs).toEqual([])
    conn.dispose()
    expect(lspDocumentStatus.value).toBeNull()
  })

  it('does not report degraded empty responses as clean diagnostics', async () => {
    installWebSocketMock()
    const conn = new LspConnection(() => {}, () => {})
    conn.syncDocument('current.ml', 'let value = missing\n')
    conn.connect()
    const socket = mockSockets[0]!
    await completeHandshake(socket)
    socket.message({ method: 'masc/lspStatus', params: { langs: [
      { lang: 'ocaml', connected: false, command: 'ocamllsp', last_error: 'not installed' },
    ] } })
    const pending = conn.requestDiagnostics('current.ml')
    const rejected = expect(pending).rejects.toThrow('availability')
    socket.message({ id: wire(socket, 'textDocument/diagnostic').at(-1).id, result: { kind: 'full', items: [] } })
    await rejected
    expect(lspDocumentStatus.value?.connection).toEqual({ kind: 'unavailable', reason: 'not installed' })
    expect(lspDocumentStatus.value?.diagnostics.kind).not.toBe('complete')
    conn.dispose()
  })

  it('synchronizes the full CM document including lines beyond the display inventory', async () => {
    vi.useFakeTimers()
    installWebSocketMock()
    const content = 'let first = 1\nlet second = missing\n'
    const store = createCodeDocumentStore({ file_path: 'current.ml', language: 'ocaml', content }, { maxLines: 1 })
    expect(store.lines()).toHaveLength(1)
    const parent = document.createElement('div')
    document.body.append(parent)
    const view = new EditorView({ parent, state: EditorState.create({
      doc: store.document().content, extensions: [lspExtension({ filePath: 'current.ml' })],
    }) })
    try {
      const socket = mockSockets[0]!
      await completeHandshake(socket)
      readyLanguage(socket)
      expect(wire(socket, 'textDocument/didOpen')[0].params.textDocument.text).toBe(content)
      view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: 'let fixed = 2\n' } })
      expect(wire(socket, 'textDocument/didChange')[0].params.contentChanges).toEqual([{ text: 'let fixed = 2\n' }])
      await vi.advanceTimersByTimeAsync(300)
      expect(wire(socket, 'textDocument/diagnostic')).toHaveLength(1)
      for (const request of socket.sent.map(value => JSON.parse(value)).filter(value => value.id && value.method !== 'initialize')) {
        socket.message({ id: request.id, result: request.method === 'textDocument/diagnostic' ? { kind: 'full', items: [] } : [] })
      }
      await Promise.resolve()
      expect(lspDocumentStatus.value?.diagnostics).toEqual({ kind: 'complete', count: 0 })
      expect(socket.sent.map(value => JSON.parse(value).method)).not.toContain('workspace/applyEdit')
    } finally { view.destroy(); parent.remove() }
  })

  it('uses the proxy server language for JSX status and old editor cleanup cannot erase its successor', async () => {
    installWebSocketMock()
    const old = new LspConnection(() => {}, () => {})
    old.syncDocument('component.tsx', 'const before = 1\n')
    old.connect()
    await completeHandshake(mockSockets[0]!)
    const current = new LspConnection(() => {}, () => {})
    current.syncDocument('component.tsx', 'const after = 2\n')
    current.connect()
    const socket = mockSockets[1]!
    await completeHandshake(socket)
    socket.message({ method: 'masc/lspStatus', params: { langs: [
      { lang: 'typescript', connected: true, command: 'typescript-language-server', last_error: null },
    ] } })
    const diagnostic = { file_path: 'component.tsx', line: 1, message: 'current report' }
    lspDiagnosticSnapshot.value = new Map([['component.tsx', [diagnostic]]])
    old.dispose()
    expect(lspDocumentStatus.value?.connection.kind).toBe('connected')
    expect(lspDocumentStatus.value?.language).toBe('typescriptreact')
    expect(lspDiagnosticSnapshot.value.get('component.tsx')).toEqual([diagnostic])
    current.dispose()
  })
})


it('remounts the actual editor for a fresh same-path workspace snapshot even when null is batched away', async () => {
  installWebSocketMock()
  const scopeA = { repoId: 'repo-a', codebase: 'a', keeper: null }
  const scopeB = { repoId: 'repo-b', codebase: 'b', keeper: null }
  publishLspScope(scopeA)
  const store = createCodeDocumentStore({ file_path: 'current.ml', language: 'ocaml',
    content: 'let from_a = 1\n', lsp_scope: lspScopeKey(scopeA) })
  const container = document.createElement('div')
  document.body.append(container)
  render(h(IdeEditor, { documentStore: store, ownershipStore: createKeeperLineOwnershipStore('current.ml'), diffRows: () => [] }), container)
  try {
    await waitFor(() => expect(mockSockets.length).toBeGreaterThan(0))
    await completeHandshake(mockSockets.at(-1)!, '/workspace/a')
    expect(wire(mockSockets.at(-1)!, 'textDocument/didOpen')[0].params.textDocument.text).toBe('let from_a = 1\n')
    const originalEditor = container.querySelector('.cm-editor')
    publishLspScope(scopeB)
    // Both store publications occur before the next Preact render.
    store.invalidate()
    store.load({ file_path: 'current.ml', language: 'ocaml', content: 'let from_b = missing\n', lsp_scope: lspScopeKey(scopeB) })
    await waitFor(() => {
      expect(container.querySelector('.cm-content')?.textContent).toContain('from_b')
      expect(container.querySelector('.cm-editor')).not.toBe(originalEditor)
      expect(mockSockets.at(-1)!.url).toContain('repo_id=repo-b')
    })
    const current = mockSockets.at(-1)!
    await completeHandshake(current, '/workspace/b')
    readyLanguage(current)
    const opens = mockSockets.filter(socket => socket.url.includes('repo_id=repo-b'))
      .flatMap(socket => wire(socket, 'textDocument/didOpen'))
    expect(opens).toHaveLength(1)
    expect(opens[0].params.textDocument).toMatchObject({ uri: 'file:///workspace/b/current.ml', text: 'let from_b = missing\n' })
    current.message({ method: 'textDocument/publishDiagnostics', params: {
      uri: 'file:///workspace/b/current.ml', version: 1, diagnostics: [sourceDiagnostic],
    } })
    await waitFor(() => expect(container.querySelector('.cm-diagnostic-marker[title="Unbound value missing"]')).not.toBeNull())
    expect(lspDocumentStatus.value?.scope).toBe(lspScopeKey(scopeB))
    expect(lspDocumentStatus.value?.diagnostics).toEqual({ kind: 'complete', count: 1 })
  } finally { render(null, container); container.remove() }
})
