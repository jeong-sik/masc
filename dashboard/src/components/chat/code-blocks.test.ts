import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ChatBlock, KeeperConversationEntry } from '../../types'
import { ChatTranscript } from './primitives'

const flushUi = (): Promise<void> => new Promise((resolve) => setTimeout(resolve, 40))

function entry(
  overrides: Partial<KeeperConversationEntry> & Pick<KeeperConversationEntry, 'id' | 'text'>,
): KeeperConversationEntry {
  const { id, text, ...rest } = overrides
  return {
    id,
    role: 'assistant',
    source: 'direct_assistant',
    label: 'sangsu',
    text,
    rawText: rest.rawText ?? text,
    timestamp: '2026-03-24T00:00:00.000Z',
    delivery: 'history',
    streamState: null,
    details: null,
    error: null,
    ...rest,
  }
}

function renderBlocks(blocks: ChatBlock[]) {
  return html`<${ChatTranscript}
    entries=${[entry({ id: 'b1', text: '', blocks })]}
    emptyText="empty"
  />`
}

describe('ChatCodeBlock Shiki highlighting', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders a highlighted code block with a copy button', async () => {
    render(renderBlocks([{ t: 'code', cap: 'config.ml', html: 'let x = 1', source: 'let x = 1' }]), container)

    const code = container.querySelector('[data-chat-block="code"]')
    expect(code).not.toBeNull()
    expect(code?.textContent).toContain('config.ml')

    await flushUi()
    expect(code?.querySelector('pre.shiki')).not.toBeNull()
    expect(code?.textContent).toContain('let x = 1')

    const copy = code?.querySelector('button[aria-label="코드 복사"]')
    expect(copy).not.toBeNull()
    expect(copy?.textContent?.trim()).toBe('복사')
  })

  it('copies the plain source text, not escaped HTML', async () => {
    const writeText = vi.fn().mockResolvedValue(undefined)
    const originalClipboard = navigator.clipboard
    Object.defineProperty(navigator, 'clipboard', {
      configurable: true,
      value: { writeText },
    })

    render(
      renderBlocks([
        { t: 'code', cap: 'example', html: '&lt;script&gt;alert(1)&lt;/script&gt;', source: '<script>alert(1)</script>' },
      ]),
      container,
    )

    await flushUi()
    const copy = container.querySelector('[data-chat-block="code"] button[aria-label="코드 복사"]') as HTMLButtonElement
    copy.click()
    await flushUi()

    expect(writeText).toHaveBeenCalledWith('<script>alert(1)</script>')

    Object.defineProperty(navigator, 'clipboard', {
      configurable: true,
      value: originalClipboard,
    })
  })

  it('falls back to the escaped HTML when Shiki fails', async () => {
    const { codeToHtml } = await import('shiki')
    vi.mocked(codeToHtml).mockRejectedValueOnce(new Error('unsupported language'))

    render(renderBlocks([{ t: 'code', cap: 'weirdlang', html: 'a &lt; b', source: 'a < b' }]), container)

    await flushUi()
    const code = container.querySelector('[data-chat-block="code"]')
    expect(code?.classList.contains('chat-block-code-fallback')).toBe(true)
    expect(code?.textContent).toContain('a < b')
  })
})

describe('ChatMermaidBlock diagram rendering', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders a mermaid block as SVG', async () => {
    render(renderBlocks([{ t: 'mermaid', source: 'graph TD; A-->B;', caption: 'flow' }]), container)

    const block = container.querySelector('[data-chat-block="mermaid"]')
    expect(block).not.toBeNull()
    expect(block?.textContent).toContain('flow')

    await flushUi()
    expect(block?.querySelector('svg')).not.toBeNull()
  })

  it('falls back to a code block when mermaid rendering errors', async () => {
    const { default: mermaid } = await import('mermaid')
    vi.mocked(mermaid.render).mockRejectedValueOnce(new Error('parse error'))

    render(renderBlocks([{ t: 'mermaid', source: 'invalid diagram', caption: 'broken' }]), container)

    await flushUi()
    expect(container.querySelector('[data-chat-block="mermaid"]')).toBeNull()
    const code = container.querySelector('[data-chat-block="code"]')
    expect(code).not.toBeNull()
    expect(code?.textContent).toContain('invalid diagram')
    expect(code?.textContent).toContain('mermaid')
  })
})
