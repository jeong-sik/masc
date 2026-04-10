import { vi } from 'vitest'
import { html } from 'htm/preact'

// Mock all lucide-preact icons to a lightweight span to avoid happy-dom timeout issues
// This drastically reduces mounting time during parallel test runs.
vi.mock('lucide-preact', async (importOriginal) => {
  const actual = await importOriginal<typeof import('lucide-preact')>()
  const mocked: Record<string, unknown> = Object.create(
    Object.getPrototypeOf(actual),
    Object.getOwnPropertyDescriptors(actual),
  )

  for (const key of Object.getOwnPropertyNames(actual)) {
    if (key === '__esModule' || key === 'createLucideIcon' || key === 'default')
      continue
    if (typeof actual[key as keyof typeof actual] !== 'function') continue

    Object.defineProperty(mocked, key, {
      configurable: true,
      enumerable: true,
      writable: true,
      value: ({ size, className, ...props }: any) =>
        html`<span data-icon=${key} width=${size} height=${size} class=${className} ...${props}></span>`,
    })
  }

  return mocked
})

// Mock Shiki to avoid heavy loading during happy-dom tests
vi.mock('shiki', () => {
  function escapeHtml(str: string): string {
    return str
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
  }
  return {
    createHighlighter: vi.fn().mockResolvedValue({
      getLoadedLanguages: vi.fn().mockReturnValue([]),
      loadLanguage: vi.fn().mockResolvedValue(undefined),
      codeToHtml: vi.fn((code: string) => `<pre class="shiki"><code>${escapeHtml(code)}</code></pre>`)
    })
  }
})

// Mock Mermaid to avoid heavyweight parsing/rendering during happy-dom tests.
vi.mock('mermaid', () => ({
  default: {
    initialize: vi.fn(),
    render: vi.fn(async (_id: string, source: string) => ({
      svg: `<svg><text>${source}</text></svg>`,
    })),
  },
}))

// Mock ninja-keys Web Component to avoid Happy DOM parsing errors
vi.mock('ninja-keys', () => {
  if (!customElements.get('ninja-keys')) {
    class NinjaKeysStub extends HTMLElement {
      data: unknown[] = []
    }

    customElements.define('ninja-keys', NinjaKeysStub)
  }

  return {}
})
