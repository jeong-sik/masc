import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

function source(file: string): string {
  return readFileSync(resolve(__dirname, file), 'utf8')
}

describe('hidden discrete anchor mobile contract', () => {
  // keeper-detail-comms.ts held the playground PR link that carried this
  // contract. #38095 removed the PR list with the pr_history field that fed
  // it, so the anchor is gone on purpose and nothing in this file should pin
  // it back. The remaining row keeps the contract where a hidden anchor still
  // ships.
  it.each([
    ['agent-core-health-chip.ts', 'v2-shell-action v2-mobile-operator-target'],
  ])('opts %s into the semantic runtime target (%s)', (file, marker) => {
    expect(source(file)).toContain(marker)
    expect(source(file)).toContain('v2-mobile-operator-target')
  })
})
