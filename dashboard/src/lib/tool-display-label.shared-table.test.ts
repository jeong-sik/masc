import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

import { toolDisplayLabel } from './tool-display-label.ts'

// The single input table both sides assert on (leader's term, task-2245).
// lib/tool_display.ml reads this exact file in the OCaml suite, so a mapping
// change that lands on only one side fails the other side's test too — the
// same togetherness promise as the sync rule (task-2258).
interface SharedRow {
  name: string
  label: string
}

const sharedTable = JSON.parse(
  readFileSync(
    resolve(__dirname, '../../../test/fixtures/tool-display-labels.json'),
    'utf8',
  ),
) as SharedRow[]

describe('toolDisplayLabel against the shared input table', () => {
  it('maps every shared row the same way the OCaml suite does', () => {
    expect(sharedTable.length).toBeGreaterThan(0)
    for (const row of sharedTable) {
      expect(toolDisplayLabel(row.name), row.name).toBe(row.label)
    }
  })
})
