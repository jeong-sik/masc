import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

function source(file: string): string {
  return readFileSync(resolve(__dirname, file), 'utf8')
}

describe('hidden discrete anchor mobile contract', () => {
  it.each([
    ['dashboard-shell.ts', 'data-build-commit-link'],
    ['keeper-detail-comms.ts', 'target="_blank" rel="noopener" class="v2-mobile-operator-target'],
    ['oas-health-chip.ts', 'v2-shell-action v2-mobile-operator-target'],
  ])('opts %s into the semantic runtime target (%s)', (file, marker) => {
    expect(source(file)).toContain(marker)
    expect(source(file)).toContain('v2-mobile-operator-target')
  })
})
