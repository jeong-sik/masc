import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

import { describe, expect, it } from 'vitest'

const sharedSources = [
  ['design-system ui kit', 'design-system/ui_kits/cockpit/cb-shared.jsx'],
  ['design-system preview', 'design-system/preview/cb-shared.jsx'],
] as const

describe('cb-shared telemetry primitives source', () => {
  for (const [label, file] of sharedSources) {
    it(`${label} does not fabricate telemetry traces`, () => {
      const source = readFileSync(resolve(process.cwd(), file), 'utf8')

      expect(source).not.toContain('Math.random()')
      expect(source).not.toContain('Array.from({ length: bars }')
      expect(source).not.toMatch(/function Heartbeat\([^)]*phase/)
      expect(source).toContain('data-empty="true"')
    })
  }
})
