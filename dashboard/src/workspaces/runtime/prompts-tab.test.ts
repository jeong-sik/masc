// @vitest-environment jsdom

import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { authSession, resetAuthStateForTests, resourceCache } from '../../core'
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

function serve(prompts: readonly unknown[], answer: (body: unknown) => Response) {
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
      return jsonResponse({ prompts, held_back: [], runtime_assets: [] })
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

  const mount = () => render(html`<${RuntimeWorkspace} subroute="prompts" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`, container)
  const listKeys = () => Array.from(container.querySelectorAll('[role="listitem"] .mono')).map(n => n.textContent)
  const pick = async (key: string) => {
    const row = await vi.waitFor(() => {
      const found = Array.from(container.querySelectorAll<HTMLButtonElement>('[role="listitem"]'))
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

  it('clears an override so the file text is in force again', async () => {
    const server = serve(
      [prompt('judge.board', { category: 'judge', source: 'override', override_value: 'mine', has_override: true, effective: 'mine' })],
      () => applied('judge.board', 'file'),
    )
    mount()
    await pick('judge.board')
    click('[data-view="edit"]')
    await flushUi()
    click('[data-testid="prompt-clear"]')
    await vi.waitFor(() => expect(server.posts).toEqual([{ url: '/api/v1/prompts', body: { action: 'clear', key: 'judge.board' } }]))
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
