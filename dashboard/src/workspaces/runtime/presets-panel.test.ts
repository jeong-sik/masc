// @vitest-environment jsdom

import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { authSession, bumpSessionEpoch, resetAuthStateForTests, resourceCache } from '../../core'
import { resetShellStateForTests, shellToasts } from '../../shell/shell-state'
import { RuntimeWorkspace } from './index'
import { listing, manifest, restored, show } from './presets-wire.test-fixture'

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
}

async function flushUi(ms = 25): Promise<void> {
  await new Promise(resolve => setTimeout(resolve, ms))
}

function prompt(key: string, effective: string, source = 'file') {
  return {
    key,
    override_default_moved: false,
    category: 'keeper',
    operator_surface: 'primary',
    authoring_issues: [],
    description: `${key} 설명`,
    current: effective,
    effective,
    file_value: effective,
    override_value: source === 'override' ? effective : null,
    file_path: '/workspace/.masc/config/prompts/keeper.md',
    file_exists: true,
    source,
    has_override: source === 'override',
    char_count: effective.length,
    required_file: false,
    template_variables: [],
  }
}

const CATALOG = {
  prompts: [
    prompt('keeper.worldview', '<world>\n</world>'),
    prompt('judge.board', 'judge the board.', 'override'),
  ],
  held_back: [],
  runtime_assets: [],
}

interface Post { readonly url: string; readonly body: unknown }

interface Serve {
  readonly answer: (url: string, body: unknown) => Response | Promise<Response>
  readonly catalog?: unknown
  readonly unreadable?: readonly unknown[]
  readonly showOf?: (name: string) => Response
}

function serve(options: Serve | Serve['answer']) {
  const { answer, catalog = CATALOG, unreadable = [], showOf = (name: string) => jsonResponse(show(name)) } =
    typeof options === 'function' ? { answer: options } : options
  const posts: Post[] = []
  const reads: string[] = []
  globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input)
    if (init?.method === 'POST') {
      const body: unknown = JSON.parse(String(init.body))
      posts.push({ url, body })
      return answer(url, body)
    }
    reads.push(url)
    if (url === '/api/v1/prompts') return jsonResponse(catalog)
    if (url === '/api/v1/presets') return jsonResponse(listing(['default', '_autosave', 'night'], unreadable))
    if (url.startsWith('/api/v1/presets/show?name=')) return showOf(decodeURIComponent(url.split('=')[1]!))
    return jsonResponse({})
  }) as typeof fetch
  return { posts, reads: (url: string) => reads.filter(r => r === url).length }
}

const SHOW_DEFAULT = '/api/v1/presets/show?name=default'

describe('Runtime → Prompts → 프리셋', () => {
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
    bumpSessionEpoch()
    resetShellStateForTests()
    container.remove()
    resourceCache.clearAll()
    globalThis.fetch = originalFetch
    vi.restoreAllMocks()
  })

  const click = (selector: string) => {
    const el = container.querySelector<HTMLButtonElement>(selector)
    expect(el).not.toBeNull()
    el!.click()
  }
  const pick = async (name: string) => {
    const row = await vi.waitFor(() => {
      const found = Array.from(container.querySelectorAll<HTMLButtonElement>('[role="listitem"] button'))
        .find(b => b.querySelector('.mono')?.textContent === name)
      expect(found).toBeDefined()
      return found!
    })
    row.click()
    await flushUi()
  }
  const mount = () => {
    render(html`<${RuntimeWorkspace} subroute="prompts" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`, container)
    click('[data-section="presets"]')
  }
  const open = async (name: string) => {
    mount()
    await pick(name)
    await vi.waitFor(() => expect(container.querySelector('[data-testid="preset-override"]')).not.toBeNull())
  }
  const text = () => container.textContent ?? ''
  const typeInto = async (label: string, text: string) => {
    const input = container.querySelector<HTMLInputElement>(`input[aria-label="${label}"]`)!
    input.value = text
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await flushUi()
  }

  it('compares the preset with the text in force and names the overrides a restore clears', async () => {
    serve({
      answer: () => jsonResponse({}),
      catalog: { ...CATALOG, prompts: [prompt('keeper.worldview', '<world>\n</world>', 'override'), prompt('judge.board', 'judge the board.', 'override')] },
    })
    await open('default')
    expect(container.querySelector('[data-testid="preset-override"] summary')?.textContent).toContain('지금과 다름')
    expect(container.querySelector('[data-testid="preset-override-diff"]')).not.toBeNull()
    const clears = container.querySelector('[data-testid="preset-clears"]')?.textContent ?? ''
    expect(clears).toContain('judge.board')
    expect(clears).not.toContain('keeper.worldview')
    expect(text()).toContain('지금 설정과 다름')
    expect(text()).toContain('max_output_tokens: 4096 · thinking: 지금 값 유지')
    expect(text()).toContain('max_output_tokens: 지움 · thinking: 지움')
  })

  it('says why when the preset on the list cannot be read', async () => {
    serve({ answer: () => jsonResponse({}), showOf: () => jsonResponse({ ok: false, error: 'manifest names night, directory is default' }, 404) })
    mount()
    await pick('default')
    await vi.waitFor(() => expect(container.querySelector('[data-testid="preset-absent"]')).not.toBeNull())
  })

  it('creates a preset, and replaces one only after the operator says so', async () => {
    const server = serve((url) => url === '/api/v1/presets/create'
      ? jsonResponse({ ok: false, error: 'preset default already exists' }, 409)
      : jsonResponse({ ok: true, preset: manifest('default') }))
    await open('default')
    await typeInto('새 프리셋 이름', 'a b')
    expect(container.querySelector<HTMLButtonElement>('[data-testid="preset-save"]')?.disabled).toBe(true)
    await typeInto('새 프리셋 이름', 'default')
    await typeInto('새 프리셋 설명', 'night shift')
    click('[data-testid="preset-save"]')
    await vi.waitFor(() => expect(container.querySelector('[data-testid="preset-taken"]')).not.toBeNull())
    expect(server.posts).toEqual([{ url: '/api/v1/presets/create', body: { name: 'default', description: 'night shift' } }])
    const showReads = server.reads(SHOW_DEFAULT)
    click('[data-testid="preset-replace"]')
    await vi.waitFor(() => expect(server.posts).toHaveLength(2))
    expect(server.posts[1]).toEqual({ url: '/api/v1/presets', body: { name: 'default', description: 'night shift' } })
    await vi.waitFor(() => expect(server.reads(SHOW_DEFAULT)).toBeGreaterThan(showReads))
  })

  it('reads the lists again when a save answers 2xx without the preset', async () => {
    const server = serve(() => jsonResponse({ ok: true }))
    mount()
    await vi.waitFor(() => expect(container.querySelector('[data-testid="preset-save-form"]')).not.toBeNull())
    await typeInto('새 프리셋 이름', 'night')
    const listingReads = server.reads('/api/v1/presets')
    click('[data-testid="preset-save"]')
    await vi.waitFor(() => expect(server.reads('/api/v1/presets')).toBeGreaterThan(listingReads))
    expect(container.querySelector('[data-testid="preset-refusal"]')).toBeNull()
  })

  it('says the outcome is unknown and reads the lists again when no answer came back', async () => {
    const server = serve(() => { throw new TypeError('Failed to fetch') })
    await open('default')
    click('[data-testid="preset-restore"]')
    await flushUi()
    const listingReads = server.reads('/api/v1/presets')
    click('[data-testid="preset-restore-go"]')
    await vi.waitFor(() => expect(container.querySelector('[data-testid="preset-refusal"]')?.textContent).toContain('결과를 알 수 없어요'))
    await vi.waitFor(() => expect(server.reads('/api/v1/presets')).toBeGreaterThan(listingReads))
  })

  it('restores only after the confirm, reports each surface and reads the prompts again', async () => {
    const server = serve(() => jsonResponse(restored('default')))
    await open('default')
    click('[data-testid="preset-restore"]')
    await flushUi()
    expect(container.querySelector('[data-testid="preset-restore-confirm"]')?.textContent).toContain('_autosave')
    expect(server.posts).toEqual([])
    const catalogReads = server.reads('/api/v1/prompts')
    const showReads = server.reads(SHOW_DEFAULT)
    click('[data-testid="preset-restore-go"]')
    await vi.waitFor(() => expect(container.querySelector('[data-testid="preset-restore-report"]')).not.toBeNull())
    expect(server.posts).toEqual([{ url: '/api/v1/presets/restore', body: { name: 'default' } }])
    const report = container.querySelector('[data-testid="preset-restore-report"]')!.textContent!
    expect(report).toContain('keeper TOML not found')
    expect(report).toContain('capability catalog')
    expect(report).toContain('일부만 복원했어요')
    expect(shellToasts.value.at(-1)?.tone).toBe('warning')
    await vi.waitFor(() => expect(server.reads('/api/v1/prompts')).toBe(catalogReads + 1))
    await vi.waitFor(() => expect(server.reads(SHOW_DEFAULT)).toBeGreaterThan(showReads))
    await pick('night')
    expect(container.querySelector('[data-testid="preset-restore-report"]')?.textContent).toContain('default')
    click('[data-section="prompts"]')
    await vi.waitFor(() => expect(container.querySelector('[data-testid="preset-restore-report"]')?.textContent).toContain('default'))
    click('[data-testid="preset-restore-report"] button')
    await vi.waitFor(() => expect(container.querySelector('[data-testid="preset-restore-report"]')).toBeNull())
  })

  it('prevents another preset write after selection or view changes and shows runtime failure', async () => {
    let release: (r: Response) => void = () => {}
    const server = serve(() => new Promise<Response>(resolve => { release = resolve }))
    await open('default')
    click('[data-testid="preset-restore"]')
    await flushUi()
    click('[data-testid="preset-restore-go"]')
    await flushUi()
    await pick('night')
    await vi.waitFor(() => expect(container.querySelector<HTMLButtonElement>('[data-testid="preset-restore"]')?.disabled).toBe(true))
    click('[data-testid="preset-restore"]')
    expect(server.posts).toHaveLength(1)
    click('[data-section="prompts"]')
    await vi.waitFor(() => expect(container.querySelector('[data-testid="preset-write-pending"]')?.textContent).toContain('default'))
    release(jsonResponse(restored('default', { status: 'failed', error: 'runtime write failed' })))
    await vi.waitFor(() => expect(container.querySelector('[data-testid="preset-restore-report"]')?.textContent).toContain('runtime write failed'))
    expect(shellToasts.value.at(-1)?.tone).toBe('error')
    expect(container.querySelector('[data-testid="preset-write-pending"]')).toBeNull()
  })

  it('keeps a refused delete visible after leaving the Presets view', async () => {
    let release: (r: Response) => void = () => {}
    serve(() => new Promise<Response>(resolve => { release = resolve }))
    await open('default')
    click('[data-testid="preset-delete"]')
    await flushUi()
    click('[data-testid="preset-delete-go"]')
    await flushUi()
    click('[data-section="prompts"]')
    await flushUi()
    release(jsonResponse({ ok: false, error: 'preset default not found' }, 404))
    await vi.waitFor(() => expect(container.querySelector('[data-testid="preset-refusal"]')?.textContent).toContain('preset default not found'))
    expect(shellToasts.value.at(-1)?.tone).toBe('error')
  })

  it('deletes a readable-named unreadable preset once, and offers nothing for a name the server refuses', async () => {
    let release: (r: Response) => void = () => {}
    const server = serve({
      answer: () => new Promise<Response>(resolve => { release = resolve }),
      unreadable: [
        { name: 'broken', reason: 'manifest.json: invalid JSON' },
        { name: 'my preset', reason: 'invalid preset name' },
      ],
    })
    mount()
    await vi.waitFor(() => expect(container.querySelectorAll('[data-testid="preset-unreadable-delete"]')).toHaveLength(1))
    click('[data-testid="preset-unreadable-delete"]')
    await flushUi()
    click('[data-testid="preset-unreadable-delete-go"]')
    await flushUi()
    click('[data-testid="preset-unreadable-delete-go"]')
    await flushUi()
    release(jsonResponse({ ok: true, deleted: 'broken' }))
    await vi.waitFor(() => expect(container.querySelector('[data-testid="preset-unreadable-delete-go"]')).toBeNull())
    expect(server.posts).toEqual([{ url: '/api/v1/presets/delete', body: { name: 'broken' } }])
  })

  it('deletes only after the confirm and shows a refusal', async () => {
    const server = serve(() => jsonResponse({ ok: false, error: 'preset default not found' }, 404))
    await open('default')
    click('[data-testid="preset-delete"]')
    await flushUi()
    expect(server.posts).toEqual([])
    click('[data-testid="preset-delete-go"]')
    await vi.waitFor(() => expect(container.querySelector('[data-testid="preset-refusal"]')?.textContent).toContain('preset default not found'))
    expect(server.posts).toEqual([{ url: '/api/v1/presets/delete', body: { name: 'default' } }])
  })

  it('offers no save, restore or delete to a session without the admin permission', async () => {
    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: true,
      authMethods: { google: false, github: false, dev_token: false },
      workspaceId: 'default',
      role: 'player',
      canTokenAdmin: false,
    }
    const server = serve(() => jsonResponse({}))
    await open('default')
    expect(container.querySelector('[data-testid="preset-save-form"]')).toBeNull()
    expect(container.querySelector('[data-testid="preset-restore"]')).toBeNull()
    expect(container.querySelector('[data-testid="preset-delete"]')).toBeNull()
    expect(server.posts).toEqual([])
  })
})
