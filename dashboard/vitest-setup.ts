import { expect, vi } from 'vitest'
import { html } from 'htm/preact'
import { configure } from '@testing-library/preact'
import { toHaveNoViolations } from 'jest-axe'

// testing-library polls findBy*/waitFor for 1000ms by default, a budget that
// assumes the render has the machine to itself. Bisecting keeper-detail's
// failure showed a count threshold, not a poisoning file: every 44-file subset
// passed (taken from either end, so no file in the remainder is the cause) and
// the 48-file set failed. Vitest's own per-test limit stays at its 5s default;
// this raises only the poll budget.
configure({ asyncUtilTimeout: 5000 })

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