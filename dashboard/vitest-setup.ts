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
