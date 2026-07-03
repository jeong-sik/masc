import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { declarationsForSelector } from './css-test-utils'

const css = readFileSync(resolve(__dirname, 'app-shell-v2.css'), 'utf-8')

describe('app-shell-v2.css code surface height chain', () => {
  const codeSurfaceHeightSelectors = [
    '.v2-app[data-surface="code"] .v2-body',
    '.v2-app[data-surface="code"] .v2-body > .h-full',
    '.v2-app[data-surface="code"] .v2-surface',
    '.v2-app[data-surface="code"] .v2-shell-surface',
    '.v2-app[data-surface="code"] .ide-v2-surface',
  ]

  for (const selector of codeSurfaceHeightSelectors) {
    it(`keeps ${selector} definite for IDE scroll containers`, () => {
      const declarations = declarationsForSelector(css, selector)

      expect(declarations.height).toBe('100%')
      expect(declarations['min-height']).toBe('0')
    })
  }
})
