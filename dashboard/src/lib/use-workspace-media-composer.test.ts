import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { html } from 'htm/preact'
import { render } from 'preact'
import { useState } from 'preact/hooks'
import { authSession, setSingleUserToken, wipeTransientSecrets } from '../core/auth'
import { resourceCache } from '../core/resource-cache'
import { BoardTab } from '../workspaces/knowledge/board-tab'
import { TasksTab } from '../workspaces/work/tasks-tab'
import { useWorkspaceMediaComposer } from './use-workspace-media-composer'

const VALID_SHA = 'c'.repeat(64)
const PNG_BYTES = new Uint8Array([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
])

function TestComposer({
  draftKey,
  initialValue = '',
}: {
  draftKey: string
  initialValue?: string
}) {
  const [value, setValue] = useState(initialValue)
  const media = useWorkspaceMediaComposer({
    value,
    onChange: setValue,
    draftKey,
  })
  return html`
    <div
      data-testid="dropzone"
      ondragenter=${media.handleDragEnter}
      ondragover=${media.handleDragOver}
      ondragleave=${media.handleDragLeave}
      ondrop=${media.handleDrop}
    >
      <textarea
        ref=${media.textareaRef}
        data-testid="ta"
        value=${value}
        onInput=${(e: Event) => {
          media.syncSelection()
          setValue((e.target as HTMLTextAreaElement).value)
        }}
        onpaste=${media.handlePaste}
        onSelect=${media.syncSelection}
      />
      ${media.uploading && html`<span data-testid="uploading">uploading</span>`}
    </div>
  `
}

describe('useWorkspaceMediaComposer', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    resourceCache.clearAll()
    wipeTransientSecrets()
    setSingleUserToken('composer-admin-token')
    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: true,
      role: 'admin',
      canTokenAdmin: true,
      canTokenRead: true,
      authMethods: { google: false, github: false, dev_token: true },
      workspaceId: 'default',
    }
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    resourceCache.clearAll()
    wipeTransientSecrets()
    vi.restoreAllMocks()
  })

  it('aborts in-flight uploads and prevents stale insertion when draftKey changes', async () => {
    let capturedSignal: AbortSignal | undefined
    let resolveUpload: ((res: Response) => void) | null = null
    globalThis.fetch = vi.fn<typeof fetch>((_input, init) => {
      capturedSignal = init?.signal ?? undefined
      return new Promise<Response>((resolve) => {
        resolveUpload = resolve
      })
    })

    render(html`<${TestComposer} draftKey="board:reply:post-1" initialValue="Draft 1 " />`, container)
    const ta = container.querySelector<HTMLTextAreaElement>('[data-testid="ta"]')!
    const file = new File([PNG_BYTES], 'late.png', { type: 'image/png' })
    const paste = new Event('paste', { bubbles: true, cancelable: true })
    Object.defineProperty(paste, 'clipboardData', {
      value: { files: [file], items: [], types: ['Files'] },
    })
    ta.dispatchEvent(paste)

    await vi.waitFor(() => {
      expect(capturedSignal).toBeDefined()
      expect(container.querySelector('[data-testid="uploading"]')).not.toBeNull()
    })

    // Switch draft target (e.g. selecting another post) while upload is still in flight
    render(html`<${TestComposer} draftKey="board:reply:post-2" initialValue="Draft 1 " />`, container)

    await vi.waitFor(() => {
      expect(capturedSignal?.aborted).toBe(true)
      expect(container.querySelector('[data-testid="uploading"]')).toBeNull()
    })

    // Even if the mock resolves late, the new draft must stay untouched
    resolveUpload!(new Response(JSON.stringify({
      path: `/api/v1/media/${VALID_SHA}`,
      sha256: VALID_SHA,
      mime: 'image/png',
      bytes: PNG_BYTES.byteLength,
      width: 10,
      height: 10,
    }), { status: 201, headers: { 'Content-Type': 'application/json' } }))
    await new Promise((r) => setTimeout(r, 20))

    expect(ta.value).toBe('Draft 1 ')
  })

  it('wires image paste upload into live BoardTab new-post composer', async () => {
    const fetchMock = vi.fn<typeof fetch>(async (input, init) => {
      const url = String(input)
      if (url === '/api/v1/media' && init?.method === 'POST') {
        return new Response(JSON.stringify({
          path: `/api/v1/media/${VALID_SHA}`,
          sha256: VALID_SHA,
          mime: 'image/png',
          bytes: PNG_BYTES.byteLength,
          width: 64,
          height: 64,
        }), { status: 201, headers: { 'Content-Type': 'application/json' } })
      }
      return new Response(JSON.stringify({ posts: [], count: 0, total: 0 }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })
    })
    globalThis.fetch = fetchMock

    render(html`<${BoardTab} subroute="board" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`, container)
    const openBtn = await vi.waitFor(() => {
      const btn = [...container.querySelectorAll<HTMLButtonElement>('button')].find((b) =>
        b.textContent?.includes('+ 새 글'),
      )
      expect(btn).toBeDefined()
      return btn!
    })
    openBtn.click()

    const ta = await vi.waitFor(() => {
      const el = container.querySelector<HTMLTextAreaElement>('[data-testid="board-post-dropzone"] textarea')
      expect(el).not.toBeNull()
      return el!
    })
    const file = new File([PNG_BYTES], 'board-shot.png', { type: 'image/png' })
    const paste = new Event('paste', { bubbles: true, cancelable: true })
    Object.defineProperty(paste, 'clipboardData', {
      value: { files: [file], items: [], types: ['Files'] },
    })
    ta.dispatchEvent(paste)

    await vi.waitFor(() => {
      expect(ta.value).toContain(`![board-shot](/api/v1/media/${VALID_SHA})`)
    }, { timeout: 5000 })
  })

  it('wires image paste upload into live TasksTab new-task composer', async () => {
    const fetchMock = vi.fn<typeof fetch>(async (input, init) => {
      const url = String(input)
      if (url === '/api/v1/media' && init?.method === 'POST') {
        return new Response(JSON.stringify({
          path: `/api/v1/media/${VALID_SHA}`,
          sha256: VALID_SHA,
          mime: 'image/png',
          bytes: PNG_BYTES.byteLength,
          width: 64,
          height: 64,
        }), { status: 201, headers: { 'Content-Type': 'application/json' } })
      }
      if (url.includes('/api/v1/tasks')) {
        return new Response(JSON.stringify({ tasks: [], count: 0 }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        })
      }
      return new Response(JSON.stringify({ goals: [], count: 0 }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })
    })
    globalThis.fetch = fetchMock

    render(html`<${TasksTab} subroute="tasks" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`, container)
    const openBtn = await vi.waitFor(() => {
      const btn = [...container.querySelectorAll<HTMLButtonElement>('button')].find((b) =>
        b.textContent?.includes('+ 새 태스크'),
      )
      expect(btn).toBeDefined()
      return btn!
    })
    openBtn.click()

    const ta = await vi.waitFor(() => {
      const el = container.querySelector<HTMLTextAreaElement>('#new-task-desc')
      expect(el).not.toBeNull()
      return el!
    })
    const file = new File([PNG_BYTES], 'task-shot.png', { type: 'image/png' })
    const paste = new Event('paste', { bubbles: true, cancelable: true })
    Object.defineProperty(paste, 'clipboardData', {
      value: { files: [file], items: [], types: ['Files'] },
    })
    ta.dispatchEvent(paste)

    await vi.waitFor(() => {
      expect(ta.value).toContain(`![task-shot](/api/v1/media/${VALID_SHA})`)
    }, { timeout: 5000 })
  })
})
