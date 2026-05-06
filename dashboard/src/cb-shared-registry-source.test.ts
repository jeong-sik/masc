import { readFileSync } from 'node:fs'

import { describe, expect, it } from 'vitest'

const readSource = (relativePath: string) =>
  readFileSync(new URL(relativePath, import.meta.url), 'utf8')

describe('cb-shared keeper registry source', () => {
  const sources = [
    ['live cockpit kit', '../cockpit-kit/cb-shared.jsx'],
    ['design-system preview', '../design-system/preview/cb-shared.jsx'],
  ] as const

  const bakedInKeeperNames = [
    'nick0cave',
    'masc-improver',
    'sangsu',
    'qa-king',
    'rama',
  ]

  it.each(sources)('does not bake keeper names into %s', (_label, path) => {
    const src = readSource(path)
    for (const name of bakedInKeeperNames) {
      expect(src).not.toContain(name)
    }
  })

  it.each(sources)('uses runtime data plus hash fallback in %s', (_label, path) => {
    const src = readSource(path)
    expect(src).toContain('MASC_DATA')
    expect(src).toContain('keeper_registry')
    expect(src).toContain('_hash12')
  })
})
