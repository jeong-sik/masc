// @vitest-environment jsdom

import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { authSession, bumpSessionEpoch, resetAuthStateForTests, resourceCache } from '../../core'
import { resetShellStateForTests, shellToasts } from '../../shell/shell-state'
import { RuntimeWorkspace } from './index'

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
}

async function flushUi(ms = 25): Promise<void> {
  await new Promise(resolve => setTimeout(resolve, ms))
}

function prompt(key: string, overrides: Record<string, unknown> = {}) {
  return {
    key,
    override_default_moved: false,
    category: 'keeper',
    operator_surface: 'primary',
    authoring_issues: [],
    description: `${key} 설명`,
    current: '<world>\n</world>',
    effective: '<world>\n</world>',
    file_value: '<world>\n</world>',
    override_value: null,
    file_path: '/workspace/.masc/config/prompts/keeper.md',
    file_exists: true,
    source: 'file',
    has_override: false,
    char_count: 16,
    required_file: false,
    template_variables: [],
    ...overrides,
  }
}

interface Post { readonly url: string; readonly body: unknown }

function serve(
  prompts: readonly unknown[],
  answer: (body: unknown) => Response | Promise<Response>,
  heldBack: readonly unknown[] = [],
) {
  const posts: Post[] = []
  let catalogReads = 0
  globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input)
    if (init?.method === 'POST') {
      const body: unknown = JSON.parse(String(init.body))
      posts.push({ url, body })
      return answer(body)
    }
    if (url === '/api/v1/prompts') {
      catalogReads += 1
      return jsonResponse({ prompts, held_back: heldBack, runtime_assets: [] })
    }
    return jsonResponse({})
  }) as typeof fetch
  return { posts, catalogReads: () => catalogReads }
}

const applied = (key: string, source: string) => jsonResponse({
  ok: true,
  message: `Override saved for ${key}`,
  key,
  source,
  effective: 'x',
  curator_refresh: null,
})

describe('Runtime → Prompts', () => {
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
    resetShellStateForTests()
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    // Drafts and requests outlast the tab within a session; a new one starts empty.
    bumpSessionEpoch()
    resetShellStateForTests()
    container.remove()
    resourceCache.clearAll()
    globalThis.fetch = originalFetch
    vi.restoreAllMocks()
  })

  const mount = (subroute = 'prompts') =>
    render(html`<${RuntimeWorkspace} subroute=${subroute} onNavigate=${vi.fn()} onInspect=${vi.fn()} />`, container)
  const lastToast = () => shellToasts.value.at(-1)
  const listKeys = () => Array.from(container.querySelectorAll('[role="listitem"] .mono')).map(n => n.textContent)
  const pick = async (key: string) => {
    const row = await vi.waitFor(() => {
      const found = Array.from(container.querySelectorAll<HTMLButtonElement>('[role="listitem"] button'))
        .find(b => b.querySelector('.mono')?.textContent === key)
      expect(found).toBeDefined()
      return found!
    })
    row.click()
    await flushUi()
  }
  const click = (selector: string) => {
    const el = container.querySelector<HTMLButtonElement>(selector)
    expect(el).not.toBeNull()
    el!.click()
  }
  const type = async (text: string) => {
    const area = container.querySelector<HTMLTextAreaElement>('textarea')!
    area.value = text
    area.dispatchEvent(new Event('input', { bubbles: true }))
    await flushUi()
  }

  it('lists the prompts an operator writes, and the fragments only when asked', async () => {
    serve([prompt('keeper.worldview'), prompt('keeper.world.active_goals.row', { operator_surface: 'fragment' })], () => jsonResponse({}))
    mount()
    await vi.waitFor(() => expect(listKeys()).toEqual(['keeper.worldview']))
    container.querySelector<HTMLInputElement>('input[type="checkbox"]')!.click()
    await vi.waitFor(() => expect(listKeys()).toEqual(['keeper.worldview', 'keeper.world.active_goals.row']))
  })

  it('saves the edited text as the override and reads the catalog again', async () => {
    const server = serve([prompt('keeper.worldview')], () => applied('keeper.worldview', 'override'))
    mount()
    await pick('keeper.worldview')
    click('[data-view="edit"]')
    await flushUi()
    await type('<world>\n증거를 남긴 일을 잘한 일로 친다\n</world>')
    click('[data-testid="prompt-save"]')
    await vi.waitFor(() => expect(server.catalogReads()).toBe(2))
    expect(server.posts).toEqual([{
      url: '/api/v1/prompts',
      body: { action: 'set', key: 'keeper.worldview', value: '<world>\n증거를 남긴 일을 잘한 일로 친다\n</world>' },
    }])
    expect(container.querySelector('textarea')).toBeNull()
  })

  it('sends clear for an override and keeps a draft the operator has not saved', async () => {
    const server = serve(
      [prompt('judge.board', { category: 'judge', source: 'override', override_value: 'mine', has_override: true, effective: 'mine' })],
      () => applied('judge.board', 'file'),
    )
    mount()
    await pick('judge.board')
    click('[data-view="edit"]')
    await flushUi()
    await type('my unsaved draft')
    click('[data-testid="prompt-clear"]')
    await vi.waitFor(() => expect(server.posts).toEqual([{ url: '/api/v1/prompts', body: { action: 'clear', key: 'judge.board' } }]))
    await vi.waitFor(() => expect(server.catalogReads()).toBe(2))
    expect(container.querySelector<HTMLTextAreaElement>('textarea')?.value).toBe('my unsaved draft')
  })

  it('holds the editor read-only while a save is in flight', async () => {
    let release: (r: Response) => void = () => {}
    const server = serve([prompt('keeper.worldview')], () => new Promise<Response>(resolve => { release = resolve }))
    mount()
    await pick('keeper.worldview')
    click('[data-view="edit"]')
    await flushUi()
    await type('first')
    click('[data-testid="prompt-save"]')
    await vi.waitFor(() => expect(server.posts).toHaveLength(1))
    expect(container.querySelector<HTMLTextAreaElement>('textarea')?.readOnly).toBe(true)
    release(applied('keeper.worldview', 'override'))
    await vi.waitFor(() => expect(container.querySelector('textarea')).toBeNull())
  })

  it('keeps a prompt read-only while its save is in flight, after another prompt is picked and back', async () => {
    let release: (r: Response) => void = () => {}
    const server = serve(
      [prompt('keeper.worldview'), prompt('keeper.identity')],
      () => new Promise<Response>(resolve => { release = resolve }),
    )
    mount()
    await pick('keeper.worldview')
    click('[data-view="edit"]')
    await flushUi()
    await type('first')
    click('[data-testid="prompt-save"]')
    await vi.waitFor(() => expect(server.posts).toHaveLength(1))
    await pick('keeper.identity')
    await pick('keeper.worldview')
    expect(container.querySelector<HTMLTextAreaElement>('textarea')?.readOnly).toBe(true)
    expect(container.querySelector<HTMLButtonElement>('[data-testid="prompt-save"]')?.disabled).toBe(true)
    release(applied('keeper.worldview', 'override'))
    await vi.waitFor(() => expect(server.catalogReads()).toBe(2))
    expect(container.querySelector<HTMLTextAreaElement>('textarea')?.readOnly).toBe(false)
    expect(Array.from(container.querySelectorAll('[role="listitem"]')).some(n => n.textContent?.includes('저장 안 함'))).toBe(false)
    expect(server.posts).toEqual([{ url: '/api/v1/prompts', body: { action: 'set', key: 'keeper.worldview', value: 'first' } }])
  })

  it('tells a refusal that arrives while another prompt is open, and shows it again on return', async () => {
    let release: (r: Response) => void = () => {}
    serve(
      [prompt('keeper.worldview'), prompt('keeper.identity')],
      () => new Promise<Response>(resolve => { release = resolve }),
    )
    mount()
    await pick('keeper.worldview')
    click('[data-view="edit"]')
    await flushUi()
    await type('<world>{{goal}}</world>')
    click('[data-testid="prompt-save"]')
    await pick('keeper.identity')
    release(jsonResponse({ ok: false, error: 'SERVER-REASON' }, 400))
    await vi.waitFor(() =>
      expect(shellToasts.value.some(t => t.tone === 'error' && t.message.includes('keeper.worldview') && t.message.includes('SERVER-REASON'))).toBe(true))
    await pick('keeper.worldview')
    expect(container.querySelector('[data-testid="prompt-refusal"]')?.textContent).toContain('SERVER-REASON')
    expect(container.querySelector<HTMLTextAreaElement>('textarea')?.value).toBe('<world>{{goal}}</world>')
  })

  it('tells a refusal that arrives after leaving the Prompts tab, and shows it with the draft on return', async () => {
    let release: (r: Response) => void = () => {}
    serve([prompt('keeper.worldview')], () => new Promise<Response>(resolve => { release = resolve }))
    mount()
    await pick('keeper.worldview')
    click('[data-view="edit"]')
    await flushUi()
    await type('<world>{{goal}}</world>')
    click('[data-testid="prompt-save"]')
    await flushUi()
    mount('tools')
    await flushUi()
    expect(container.querySelector('[data-testid="runtime-prompts-tab"]')).toBeNull()
    release(jsonResponse({ ok: false, error: 'SERVER-REASON' }, 400))
    await vi.waitFor(() => expect(lastToast()?.message).toContain('SERVER-REASON'))
    expect(lastToast()?.tone).toBe('error')
    expect(lastToast()?.message).toContain('keeper.worldview')
    mount()
    await pick('keeper.worldview')
    expect(container.querySelector('[data-testid="prompt-refusal"]')?.textContent).toContain('SERVER-REASON')
    expect(container.querySelector<HTMLTextAreaElement>('textarea')?.value).toBe('<world>{{goal}}</world>')
  })

  it('sends one request per prompt, from the editor or the held-back banner', async () => {
    let release: (r: Response) => void = () => {}
    const server = serve(
      [prompt('keeper.worldview')],
      () => new Promise<Response>(resolve => { release = resolve }),
      [{ key: 'keeper.worldview', bytes: 12, reason: 'template variable {{post}} is no longer declared' }],
    )
    mount()
    await pick('keeper.worldview')
    click('[data-view="edit"]')
    await flushUi()
    await type('second')
    click('[data-testid="prompt-save"]')
    await vi.waitFor(() => expect(server.posts).toHaveLength(1))
    const clear = container.querySelector<HTMLButtonElement>('[data-testid="prompts-held-back-clear"]')!
    expect(clear.disabled).toBe(true)
    clear.click()
    await flushUi()
    expect(server.posts).toHaveLength(1)
    release(applied('keeper.worldview', 'override'))
    await vi.waitFor(() => expect(container.querySelector('textarea')).toBeNull())
  })

  it('says the outcome is unknown, keeps the draft and reads the catalog again when no answer came back', async () => {
    const server = serve([prompt('keeper.worldview')], () => { throw new TypeError('Failed to fetch') })
    mount()
    await pick('keeper.worldview')
    click('[data-view="edit"]')
    await flushUi()
    await type('<world>maybe</world>')
    click('[data-testid="prompt-save"]')
    await vi.waitFor(() => expect(container.querySelector('[data-testid="prompt-refusal"]')?.textContent).toContain('결과를 알 수 없어요'))
    expect(server.catalogReads()).toBe(2)
    expect(container.querySelector<HTMLTextAreaElement>('textarea')?.value).toBe('<world>maybe</world>')
  })

  it('keeps the editor until the catalog read after a save answers', async () => {
    let releaseRead: (r: Response) => void = () => {}
    let wrote = false
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      if (init?.method === 'POST') {
        wrote = true
        return applied('keeper.worldview', 'override')
      }
      if (String(input) === '/api/v1/prompts') {
        const catalog = { prompts: [prompt('keeper.worldview', wrote ? { effective: 'NEW TEXT', source: 'override' } : {})], held_back: [], runtime_assets: [] }
        return wrote ? new Promise<Response>(resolve => { releaseRead = () => resolve(jsonResponse(catalog)) }) : jsonResponse(catalog)
      }
      return jsonResponse({})
    }) as typeof fetch
    mount()
    await pick('keeper.worldview')
    click('[data-view="edit"]')
    await flushUi()
    await type('NEW TEXT')
    click('[data-testid="prompt-save"]')
    await flushUi(50)
    expect(container.querySelector<HTMLTextAreaElement>('textarea')?.readOnly).toBe(true)
    releaseRead(jsonResponse({}))
    await vi.waitFor(() => expect(container.querySelector('textarea')).toBeNull())
    expect(container.textContent).toContain('NEW TEXT')
  })

  it('tells the operator, without naming the prompt, that a session change lost the answer of a request in flight', async () => {
    serve([prompt('keeper.worldview')], () => new Promise<Response>(() => {}))
    mount()
    await pick('keeper.worldview')
    click('[data-view="edit"]')
    await flushUi()
    await type('lost')
    click('[data-testid="prompt-save"]')
    await flushUi()
    bumpSessionEpoch()
    await vi.waitFor(() => expect(lastToast()?.message).toContain('세션이 바뀌어서'))
    expect(lastToast()?.tone).toBe('warning')
    expect(lastToast()?.message).not.toContain('keeper.worldview')
  })

  it('keeps a draft when another prompt is picked and back again', async () => {
    serve([prompt('keeper.worldview'), prompt('keeper.identity')], () => jsonResponse({}))
    mount()
    await pick('keeper.worldview')
    click('[data-view="edit"]')
    await flushUi()
    await type('<world>draft</world>')
    await pick('keeper.identity')
    expect(container.querySelector('textarea')).toBeNull()
    await pick('keeper.worldview')
    expect(container.querySelector<HTMLTextAreaElement>('textarea')?.value).toBe('<world>draft</world>')
  })

  it('clears an override the server holds back from the banner', async () => {
    const server = serve(
      [prompt('keeper.worldview')],
      () => applied('judge.board', 'file'),
      [{ key: 'judge.board', bytes: 812, reason: 'template variable {{post}} is no longer declared' }],
    )
    mount()
    await vi.waitFor(() => expect(container.querySelector('[data-testid="prompts-held-back-clear"]')).not.toBeNull())
    click('[data-testid="prompts-held-back-clear"]')
    await vi.waitFor(() => expect(server.posts).toEqual([{ url: '/api/v1/prompts', body: { action: 'clear', key: 'judge.board' } }]))
  })

  it('reads the catalog again when the server applied the change but its answer does not decode', async () => {
    const server = serve([prompt('keeper.worldview')], () => jsonResponse({ ok: true, message: 'saved' }))
    mount()
    await pick('keeper.worldview')
    click('[data-view="edit"]')
    await flushUi()
    await type('<world>x</world>')
    click('[data-testid="prompt-save"]')
    await vi.waitFor(() => expect(server.catalogReads()).toBe(2))
    expect(container.querySelector('[data-testid="prompt-refusal"]')).toBeNull()
  })

  it('keeps the draft and the server reason when the override is refused', async () => {
    serve([prompt('keeper.worldview')], () => jsonResponse({ ok: false, error: 'unexpected template variable {{goal}}' }, 400))
    mount()
    await pick('keeper.worldview')
    click('[data-view="edit"]')
    await flushUi()
    await type('<world>{{goal}}</world>')
    click('[data-testid="prompt-save"]')
    const refusal = await vi.waitFor(() => {
      const el = container.querySelector('[data-testid="prompt-refusal"]')
      expect(el).not.toBeNull()
      return el!
    })
    expect(refusal.textContent).toContain('unexpected template variable {{goal}}')
    expect(container.querySelector<HTMLTextAreaElement>('textarea')?.value).toBe('<world>{{goal}}</world>')
  })

  it('offers no editor to a session that cannot use the admin override tool', async () => {
    authSession.value = { ...authSession.value, kind: 'single_user_local', role: 'player' } as typeof authSession.value
    const server = serve([prompt('keeper.worldview')], () => applied('keeper.worldview', 'override'))
    mount()
    await pick('keeper.worldview')
    expect(container.querySelector('[data-view="edit"]')).toBeNull()
    expect(container.querySelector('[data-testid="prompts-admin-locked"]')).not.toBeNull()
    expect(server.posts).toEqual([])
  })
})
