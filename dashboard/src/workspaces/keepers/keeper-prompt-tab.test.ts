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

const SYSTEM = 'write well.\n'

// `Keeper_prompt_capture.to_json` with the keeper and surface the route prefixes.
const capture = (overrides: Record<string, unknown> = {}) => ({
  keeper: 'albini',
  dashboard_surface: '/api/v1/keepers/:name/last-prompt',
  captured_at: 1_788_220_000.125,
  trace_id: 'trace-one',
  absolute_turn: 7,
  blocks: [
    { id: 'keeper_instructions', bytes: 12, text: SYSTEM },
    { id: 'active_goals', bytes: 0, text: '' },
    { id: 'dynamic_context', bytes: 5, text: 'now.\n' },
  ],
  assembled: 'write well.\nnow.\n',
  assembled_bytes: 17,
  system_prompt: SYSTEM,
  system_prompt_partition: null,
  ...overrides,
})

// `masc.provider-input-manifest.v1` for the same turn.
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

function serve(lastPrompt: () => Response) {
  const reads: string[] = []
  globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
    const url = String(input)
    reads.push(url)
    if (url === LAST_PROMPT) return lastPrompt()
    if (url === PROVIDER_INPUT) return jsonResponse(manifest)
    if (url === PART_ZERO) return jsonResponse(partAnswer)
    return jsonResponse({ error: 'not served' }, 404)
  }) as typeof fetch
  return { reads }
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

  it('lists the blocks in assembly order and the request they went into', async () => {
    serve(() => jsonResponse(capture()))
    mount()
    await vi.waitFor(() => expect(container.querySelectorAll('[data-testid="keeper-prompt-block"]')).toHaveLength(3))
    const titles = Array.from(container.querySelectorAll('[data-testid="keeper-prompt-block"] strong')).map(n => n.textContent)
    expect(titles).toEqual(['1. Keeper 지시문', '2. 진행 중 Goal', '3. 턴 맥락'])
    await vi.waitFor(() => expect(container.querySelector('[data-testid="keeper-prompt-flow"]')?.textContent).toContain('openai-compatible/model-seven'))
    expect(container.querySelector('[data-testid="keeper-prompt-flow"]')?.textContent).toContain('message 1')
    click('[data-view="assembled"]')
    await flushUi()
    expect(container.querySelector('[data-testid="keeper-prompt-assembled"]')?.textContent).toBe('write well.\nnow.\n')
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
    expect(server.reads.filter(u => u === PART_ZERO)).toHaveLength(1)
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
