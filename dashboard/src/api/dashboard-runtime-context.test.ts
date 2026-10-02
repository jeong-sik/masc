import { afterEach, describe, expect, it, vi } from 'vitest'

const get = vi.hoisted(() => vi.fn())
vi.mock('./core', () => ({ get }))

import { fetchRuntimeProviders } from './dashboard-runtime'
import { runtimeCatalogDeclaredSpec } from '../lib/runtime-provider-summary'

afterEach(() => vi.clearAllMocks())

describe('declared runtime context window', () => {
  it.each([
    [null, null, 272000, 'model'],
    [400000, null, 400000, 'provider'],
    [400000, 1000000, 1000000, 'binding'],
    [400000, 128000, 128000, 'binding'],
  ])('preserves provider %s and binding %s before rendering %s from %s', async (provider, binding, expected, source) => {
    get.mockResolvedValue({ providers: [{ provider: 'scoped.shared', declared_spec: {
      provider: { max_context: provider }, model: { max_context: 272000 },
      binding: { max_context: binding },
    } }] })
    const { providers: [row] } = await fetchRuntimeProviders()
    if (row === undefined) throw new Error('Expected a runtime provider row')
    expect(row.declared_spec?.provider?.max_context).toBe(provider)
    expect(row.declared_spec?.binding?.max_context).toBe(binding)
    expect(runtimeCatalogDeclaredSpec(row)).toBe(`ctx:${expected} · ctx-source:${source}`)
  })
})
