// @vitest-environment jsdom
// ChatMermaidBlock renders mermaid via DOMPurify + a viewport-gated render
// (useInViewOnce). Under happy-dom DOMPurify fails its support check and
// IntersectionObserver never fires, so the diagram stays a placeholder. jsdom
// (no IntersectionObserver -> immediate render, DOMPurify supported) exercises
// the real render path, matching markdown-renderer.test.ts / dompurify.test.ts.
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { html } from 'htm/preact'
import { render } from 'preact'
import { waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ChatBlock, KeeperConversationEntry } from '../../types'
import { ChatTranscript } from './primitives'

const DASHBOARD_SRC = resolve(process.cwd(), 'src')
const ENTRY_STYLESHEET_IMPORT = /^import '\.\/(styles\/[\w-]+\.css)'$/gm

// Chat chrome classes whose box styling (border, radius, background, spacing)
// lives in a global stylesheet. ChatTranscript is a shared component, so these
// rules ship with the entry bundle (main.ts imports), not one workspace's sheet.
const ENTRY_STYLED_CHAT_CLASSES = ['chat-transcript', 'chat-bubble', 'chat-block-code'] as const

function entryStylesheetText(): string {
  const entry = readFileSync(resolve(DASHBOARD_SRC, 'main.ts'), 'utf8')
  // Group 1 is not optional in ENTRY_STYLESHEET_IMPORT, so every match has it.
  return Array.from(entry.matchAll(ENTRY_STYLESHEET_IMPORT), (match) =>
    readFileSync(resolve(DASHBOARD_SRC, match[1]!), 'utf8'),
  ).join('\n')
}

// A rule whose selector ends on the bare class (`.x {` or `.x,`) styles the
// element itself; `.x .child`, `.x:hover` and `.x-suffix` do not count.
function definesClassRule(css: string, className: string): boolean {
  return new RegExp(String.raw`(?:^|[\s,}])\.${className}\s*[,{]`, 'm').test(css)
}

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

    await waitFor(() => expect(code?.textContent).toContain('let x = 1'))

    const copy = code?.querySelector('button[aria-label="코드 복사"]')
    expect(copy).not.toBeNull()
    expect(copy?.textContent?.trim()).toBe('복사')
  })

  it('renders code and mermaid blocks with chat chrome classes that the entry bundle styles', () => {
    render(
      renderBlocks([
        { t: 'code', cap: 'config.ml', html: 'let x = 1', source: 'let x = 1' },
        { t: 'mermaid', source: 'graph TD; A-->B;', caption: 'flow' },
      ]),
      container,
    )

    expect(container.querySelectorAll('.chat-block-code[data-chat-block="code"]')).toHaveLength(2)
    const css = entryStylesheetText()
    for (const className of ENTRY_STYLED_CHAT_CLASSES) {
      expect(container.querySelector(`.${className}`), className).not.toBeNull()
      expect(definesClassRule(css, className), className).toBe(true)
    }
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

    const copy = await waitFor(() => {
      const btn = container.querySelector('[data-chat-block="code"] button[aria-label="코드 복사"]') as HTMLButtonElement | null
      expect(btn).not.toBeNull()
      return btn as HTMLButtonElement
    })
    copy.click()
    await waitFor(() => expect(writeText).toHaveBeenCalledWith('<script>alert(1)</script>'))

    Object.defineProperty(navigator, 'clipboard', {
      configurable: true,
      value: originalClipboard,
    })
  })
})

describe('ChatMermaidBlock fallback rendering', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders mermaid blocks safely as monospace code without mermaid bundle', async () => {
    render(renderBlocks([{ t: 'mermaid', source: 'graph TD; A-->B;', caption: 'flow' }]), container)

    const block = container.querySelector('[data-chat-block="code"]')
    expect(block).not.toBeNull()
    expect(block?.textContent).toContain('graph TD')
  })
})
