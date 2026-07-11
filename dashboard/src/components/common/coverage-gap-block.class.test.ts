import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

const SOURCE = resolve(__dirname, 'coverage-gap-block.ts')

describe('CoverageGapBlock mobile action classes', () => {
  it('opts remediation links into the runtime mobile target contract', () => {
    const src = readFileSync(SOURCE, 'utf-8')
    expect(src).toContain('class="v2-mobile-operator-target inline-flex items-center gap-1 self-start')
  })
})
