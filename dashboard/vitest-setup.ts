import { expect, vi } from 'vitest'
import { html } from 'htm/preact'
import { toHaveNoViolations } from 'jest-axe'

// Wire jest-axe's `toHaveNoViolations` matcher into Vitest's `expect`.
// Lets `*.a11y.test.ts` files call `expect(await axe(node)).toHaveNoViolations()`.
expect.extend(toHaveNoViolations)

type StorageLike = Pick<Storage, 'getItem' | 'setItem' | 'removeItem' | 'clear' | 'key' | 'length'>

function hasStorageApi(value: unknown): value is StorageLike {
  return typeof value === 'object'
    && value !== null
    && typeof (value as StorageLike).getItem === 'function'
    && typeof (value as StorageLike).setItem === 'function'
    && typeof (value as StorageLike).removeItem === 'function'
    && typeof (value as StorageLike).clear === 'function'
    && typeof (value as StorageLike).key === 'function'
    && typeof (value as StorageLike).length === 'number'
}

function createMemoryStorage(): Storage {
  const store = new Map<string, string>()
  return {
    getItem(key: string): string | null {
      return store.has(key) ? (store.get(key) ?? null) : null
    },
    setItem(key: string, value: string): void {
      store.set(String(key), String(value))
    },
    removeItem(key: string): void {
      store.delete(String(key))
    },
    clear(): void {
      store.clear()
    },
    key(index: number): string | null {
      return Array.from(store.keys())[index] ?? null
    },
    get length(): number {
      return store.size
    },
  } as Storage
}

function installStorageShim(name: 'localStorage' | 'sessionStorage'): void {
  let activeStorage = hasStorageApi(globalThis[name]) ? globalThis[name] : createMemoryStorage()
  const host = typeof window !== 'undefined' ? window : globalThis
  Object.defineProperty(host, name, {
    configurable: true,
    enumerable: true,
    get: () => activeStorage,
    set: (value: Storage | undefined) => {
      activeStorage = value === undefined
        ? undefined
        : (hasStorageApi(value) ? value : createMemoryStorage())
    },
  })
}

installStorageShim('localStorage')
installStorageShim('sessionStorage')

// Mock all lucide-preact icons to a lightweight span to avoid happy-dom timeout issues.
// Uses a Proxy to avoid ESM frozen descriptor collisions across parallel test workers.
vi.mock('lucide-preact', async (importOriginal) => {
  const actual = await importOriginal<typeof import('lucide-preact')>()
  const iconCache = new Map<string, unknown>()

  const mockIcon = (key: string) =>
    ({ size, className, ...props }: any) =>
      html`<span data-icon=${key} width=${size} height=${size} class=${className} ...${props}></span>`

  return new Proxy(actual, {
    get(target, prop: string) {
      if (prop === '__esModule' || prop === 'createLucideIcon' || prop === 'default') {
        return target[prop as keyof typeof target]
      }
      const val = target[prop as keyof typeof target]
      if (typeof val !== 'function') return val
      if (!iconCache.has(prop)) iconCache.set(prop, mockIcon(prop))
      return iconCache.get(prop)
    },
  })
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

// DOMPurify 3.4.9 reports isSupported=true under happy-dom but fails basic
// security behavior such as stripping <script>. Keep production on real
// DOMPurify; tests use this lightweight browser-path stand-in so Markdown and
// Shiki tests exercise the supported sanitizer branch.
vi.mock('dompurify', () => {
  const dropWithContent = new Set([
    'base', 'embed', 'iframe', 'link', 'meta', 'noscript', 'object', 'script',
    'style', 'template',
  ])
  const uriAttrs = new Set(['action', 'formaction', 'href', 'src', 'xlink:href'])

  function toSet(values: unknown): Set<string> {
    return Array.isArray(values) ? new Set(values.map(value => String(value).toLowerCase())) : new Set()
  }

  function unwrap(element: Element): void {
    const parent = element.parentNode
    if (!parent) return
    while (element.firstChild) parent.insertBefore(element.firstChild, element)
    parent.removeChild(element)
  }

  function sanitizeNode(parent: ParentNode, allowedTags: Set<string>, allowedAttrs: Set<string>): void {
    let node = parent.firstChild
    while (node) {
      const next = node.nextSibling
      if (node.nodeType === Node.ELEMENT_NODE) {
        const element = node as Element
        const tag = element.tagName.toLowerCase()
        if (dropWithContent.has(tag)) {
          element.remove()
        } else if (allowedTags.size > 0 && !allowedTags.has(tag)) {
          sanitizeNode(element, allowedTags, allowedAttrs)
          unwrap(element)
        } else {
          for (const attr of Array.from(element.attributes)) {
            const attrName = attr.name.toLowerCase()
            const compact = attr.value.replace(/[\u0000-\u001F\u007F\s]+/g, '').toLowerCase()
            const forbiddenByConfig = allowedAttrs.size > 0 && !allowedAttrs.has(attrName)
            const unsafeUri = uriAttrs.has(attrName) && /^(?:javascript|vbscript):/.test(compact)
            if (attrName.startsWith('on') || forbiddenByConfig || unsafeUri) {
              element.removeAttribute(attr.name)
            }
          }
          sanitizeNode(element, allowedTags, allowedAttrs)
        }
      } else if (node.nodeType !== Node.TEXT_NODE) {
        node.parentNode?.removeChild(node)
      }
      node = next
    }
  }

  function sanitize(
    raw: string,
    config?: { ALLOWED_TAGS?: unknown; ALLOWED_ATTR?: unknown }
  ): string {
    const template = document.createElement('template')
    template.innerHTML = raw
    sanitizeNode(template.content, toSet(config?.ALLOWED_TAGS), toSet(config?.ALLOWED_ATTR))
    return template.innerHTML
  }

  return {
    __esModule: true,
    default: () => ({
      isSupported: true,
      sanitize,
    }),
  }
})

// Mock Mermaid to avoid heavyweight parsing/rendering during happy-dom tests.
const mermaidMock = {
  initialize: vi.fn(),
  render: vi.fn(async (_id: string, source: string) => ({
    svg: `<svg><text>${source}</text></svg>`,
  })),
}
vi.mock('mermaid', () => ({
  default: mermaidMock,
  ...mermaidMock,
}))

// Block real network requests in tests. Tests that intentionally need
// fetch must install an explicit mock (vi.fn() or msw).
vi.stubGlobal(
  'fetch',
  vi.fn((input: RequestInfo | URL, _init?: RequestInit) => {
    const url = typeof input === 'string' ? input : input.toString()
    throw new Error(
      `Real network request blocked in tests: ${url}\n` +
        `If this test intentionally uses fetch, mock it with vi.fn() or msw.`
    )
  })
)

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
