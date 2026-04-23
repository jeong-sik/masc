import { vi } from 'vitest'
import { html } from 'htm/preact'

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
