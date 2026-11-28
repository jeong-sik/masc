// @vitest-environment jsdom

import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { authSession, resetAuthStateForTests, resourceCache } from '../../core'
import { KeeperPromptTab } from './keeper-prompt-tab'

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
}

async function flushUi(ms = 25): Promise<void> {
  await new Promise(resolve => setTimeout(resolve, ms))
}

const SYSTEM = 'write well.\n\n\ngoal.\n'

const span = (source: unknown, bytes: number) => ({
  source, offset: 0, bytes, sha256: 'a'.repeat(64), subpartition: { status: 'not_applicable' },
})

// The shape of a real capture (`Keeper_prompt_capture.to_json` behind
// `handle_last_prompt_get`): the base instructions and the System observation
// make the system prompt; the other block is the extra context.
const capture = (overrides: Record<string, unknown> = {}) => ({
  keeper: 'albini',
  dashboard_surface: '/api/v1/keepers/:name/last-prompt',
  captured_at: 1_788_220_000.125,
  trace_id: 'trace-one',
  absolute_turn: 7,
  blocks: [
    { id: 'keeper_instructions', bytes: 12, text: 'write well.\n' },
    { id: 'active_goals', bytes: 6, text: 'goal.\n' },
    { id: 'dynamic_context', bytes: 5, text: 'now.\n' },
  ],
  assembled: 'now.\n',
  assembled_bytes: 5,
  system_prompt: SYSTEM,
  system_prompt_partition: {
    carrier: 'system_prompt',
    scope: 'canonical_issued_system_prompt_before_transport_projection',
    partition: {
      schema: 'masc.logical-context-partition.v2',
      scope: 'assembled_raw_utf8_before_message_or_ipc_encoding',
      bytes: 20,
      sha256: 'b'.repeat(64),
      spans: [
        span({ kind: 'unattributed', reason: 'existing_prefix' }, 12),
        span({ kind: 'unattributed', reason: 'separator' }, 2),
        span({ kind: 'block', block: 'active_goals' }, 6),
      ],
    },
  },
  ...overrides,
})

// `masc.provider-input-manifest.v1` for the same turn, as `manifest_to_json` writes it.
const manifest = {
  dashboard_surface: '/api/v1/keepers/:name/provider-input',
  schema: 'masc.provider-input-manifest.v1',
  keeper: 'albini',
  trace_id: 'trace-one',
  absolute_turn: 7,
  turn_ref: 'trace-one#7',
  runtime_profile: 'local',
  captured_at: 1_788_220_000.125,
  wire: {
    phase: 'Pre_dispatch_serialization',
    capture_id: 'capture-7',
    provider: 'openai-compatible',
    model: 'model-seven',
    http_codec: 'responses',
    stream: true,
    body_bytes: 8192,
    body_sha256: 'a'.repeat(64),
  },
  parts: [
    { index: 0, kind: 'system_prompt', bytes: new TextEncoder().encode(SYSTEM).length, sha256: 'b'.repeat(64) },
    { index: 1, kind: 'message', role: 'user', bytes: 42, sha256: 'c'.repeat(64) },
  ],
}

const partAnswer = {
  dashboard_surface: '/api/v1/keepers/:name/provider-input/part',
  schema: 'masc.provider-input-part.v1',
  keeper: 'albini',
  turn_ref: 'trace-one#7',
  part: manifest.parts[0],
  text: SYSTEM,
}

const LAST_PROMPT = '/api/v1/keepers/albini/last-prompt'
const PROVIDER_INPUT = '/api/v1/keepers/albini/provider-input?turn_ref=trace-one%237'
const PART_ZERO = '/api/v1/keepers/albini/provider-input/part?turn_ref=trace-one%237&index=0'

interface Answers {
  readonly lastPrompt: () => Response
  readonly providerInput?: () => Response
  readonly partZero?: () => Response
}

function serve(answers: Answers | Answers['lastPrompt']) {
  const { lastPrompt, providerInput = () => jsonResponse(manifest), partZero = () => jsonResponse(partAnswer) } =
    typeof answers === 'function' ? { lastPrompt: answers } : answers
  const reads: string[] = []
  globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
    const url = String(input)
    reads.push(url)
    if (url === LAST_PROMPT) return lastPrompt()
    if (url === PROVIDER_INPUT) return providerInput()
    if (url === PART_ZERO) return partZero()
    return jsonResponse({ error: 'not served' }, 404)
  }) as typeof fetch
  return { reads, count: (url: string) => reads.filter(r => r === url).length }
}

describe('Keeper → Prompt', () => {
  let container: HTMLDivElement
  let originalFetch: typeof globalThis.fetch

  beforeEach(() => {
    originalFetch = globalThis.fetch
    resetAuthStateForTests()
    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: false,
      authMethods: { google: false, github: false, dev_token: false },
      workspaceId: 'default',
    }
    resourceCache.clearAll()
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    resourceCache.clearAll()
    globalThis.fetch = originalFetch
    vi.restoreAllMocks()
  })

  const mount = () => render(html`<${KeeperPromptTab} keeperName="albini" />`, container)
  const click = (selector: string) => {
    const el = container.querySelector<HTMLElement>(selector)
    expect(el).not.toBeNull()
    el!.click()
  }

  const textOf = (testid: string) => container.querySelector(`[data-testid="${testid}"]`)?.textContent ?? ''

  it('lists the blocks in assembly order with where each went, and the turn\'s last request', async () => {
    serve(() => jsonResponse(capture()))
    mount()
    await vi.waitFor(() => expect(container.querySelectorAll('[data-testid="keeper-prompt-block"]')).toHaveLength(3))
    const titles = Array.from(container.querySelectorAll('[data-testid="keeper-prompt-block"] strong')).map(n => n.textContent)
    expect(titles).toEqual(['1. Keeper 지시문', '2. 진행 중 Goal', '3. 턴 맥락'])
    const destinations = Array.from(container.querySelectorAll('[data-testid="keeper-prompt-block-destination"]')).map(n => n.textContent)
    expect(destinations).toEqual(['→ System prompt', '→ System prompt', '→ 추가 맥락'])
    expect(textOf('keeper-prompt-flow-system-blocks')).toContain('블록 2개')
    expect(textOf('keeper-prompt-flow-system-blocks')).toContain('18 bytes')
    expect(textOf('keeper-prompt-flow-system')).toContain('20 bytes')
    expect(textOf('keeper-prompt-flow-extra-blocks')).toContain('블록 1개')
    expect(textOf('keeper-prompt-flow-extra')).toContain('5 bytes')
    await vi.waitFor(() => expect(textOf('keeper-prompt-flow-provider')).toContain('openai-compatible/model-seven'))
    expect(textOf('keeper-prompt-flow-provider')).toContain('message 1')
    click('[data-view="assembled"]')
    await flushUi()
    expect(container.querySelector('[data-testid="keeper-prompt-assembled"]')?.textContent).toBe('now.\n')
  })

  it('tells a turn with no request record from a request it could not read', async () => {
    serve({ lastPrompt: () => jsonResponse(capture()), providerInput: () => jsonResponse({ error: 'no provider-input snapshot' }, 404) })
    mount()
    await vi.waitFor(() => expect(textOf('keeper-prompt-flow-provider')).toContain('이 턴의 요청 기록이 없어요'))
    render(null, container)
    resourceCache.clearAll()
    serve({ lastPrompt: () => jsonResponse(capture()), providerInput: () => jsonResponse({ error: 'store unavailable' }, 503) })
    mount()
    await vi.waitFor(() => expect(textOf('keeper-prompt-flow-provider')).toContain('읽지 못했어요'))
  })

  it('reads the turn\'s request again on refresh, since it is written when the turn ends', async () => {
    let written = false
    const server = serve({
      lastPrompt: () => jsonResponse(capture()),
      providerInput: () => written ? jsonResponse(manifest) : jsonResponse({ error: 'no provider-input snapshot' }, 404),
    })
    mount()
    await vi.waitFor(() => expect(textOf('keeper-prompt-flow-provider')).toContain('이 턴의 요청 기록이 없어요'))
    written = true
    click('.refresh-btn')
    await vi.waitFor(() => expect(textOf('keeper-prompt-flow-provider')).toContain('openai-compatible/model-seven'))
    expect(server.count(PROVIDER_INPUT)).toBe(2)
  })

  it('reads a request part only when it is opened, and checks it against the manifest', async () => {
    const server = serve(() => jsonResponse(capture()))
    mount()
    await vi.waitFor(() => expect(server.reads).toContain(PROVIDER_INPUT))
    click('[data-view="provider"]')
    await vi.waitFor(() => expect(container.querySelectorAll('[data-testid="keeper-prompt-part"]')).toHaveLength(2))
    expect(server.reads).not.toContain(PART_ZERO)
    const first = container.querySelector<HTMLDetailsElement>('[data-testid="keeper-prompt-part"]')!
    first.open = true
    first.dispatchEvent(new Event('toggle'))
    await vi.waitFor(() => expect(first.querySelector('pre')?.textContent).toBe(SYSTEM))
    expect(server.count(PART_ZERO)).toBe(1)
  })

  it('tries a part again when it is opened again after a failed read', async () => {
    let fail = true
    const server = serve({
      lastPrompt: () => jsonResponse(capture()),
      partZero: () => fail ? jsonResponse({ error: 'blob store unavailable' }, 503) : jsonResponse(partAnswer),
    })
    mount()
    await vi.waitFor(() => expect(server.reads).toContain(PROVIDER_INPUT))
    click('[data-view="provider"]')
    const first = await vi.waitFor(() => {
      const found = container.querySelector<HTMLDetailsElement>('[data-testid="keeper-prompt-part"]')
      expect(found).not.toBeNull()
      return found!
    })
    // jsdom fires `toggle` itself when `open` changes.
    first.open = true
    await vi.waitFor(() => expect(first.querySelector('.ap-error')?.textContent).toContain('읽지 못했어요'))
    expect(server.count(PART_ZERO)).toBe(1)
    fail = false
    first.open = false
    await flushUi()
    first.open = true
    await vi.waitFor(() => expect(first.querySelector('pre')?.textContent).toBe(SYSTEM))
    expect(server.count(PART_ZERO)).toBe(2)
  })

  it('says the keeper has not assembled a turn yet', async () => {
    serve(() => jsonResponse({ error: 'this keeper has not assembled a turn since prompt capture existed' }, 404))
    mount()
    await vi.waitFor(() => expect(container.querySelector('[data-testid="keeper-prompt-not-captured"]')).not.toBeNull())
  })

  it('shows a decode failure instead of a made-up block', async () => {
    serve(() => jsonResponse(capture({ blocks: [{ id: 'block', bytes: 1, text: 'x' }] })))
    mount()
    await vi.waitFor(() => expect(container.querySelector('.ap-error[role="alert"]')?.textContent).toContain('프롬프트를 읽지 못했어요'))
    expect(container.querySelector('[data-testid="keeper-prompt-block"]')).toBeNull()
  })

  it('sends nothing for a session without the admin permission', async () => {
    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: true,
      authMethods: { google: false, github: false, dev_token: false },
      workspaceId: 'default',
      role: 'player',
      canTokenAdmin: false,
    }
    const server = serve(() => jsonResponse(capture()))
    mount()
    await flushUi()
    expect(container.querySelector('[data-testid="keeper-prompt-admin-locked"]')).not.toBeNull()
    expect(server.reads).toEqual([])
  })
})
