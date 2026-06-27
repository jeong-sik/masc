import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

describe('keeper detail state import boundary', () => {
  it('preloads keeper config without importing the config panel UI module', () => {
    const source = readFileSync(resolve(__dirname, 'keeper-detail-state.ts'), 'utf8')

    expect(source).toContain("from './keeper-config-state'")
    expect(source).not.toContain("from './keeper-config-panel'")
  })
})
