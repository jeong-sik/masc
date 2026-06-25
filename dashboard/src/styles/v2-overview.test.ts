import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { declarationsForSelector } from './css-test-utils'

const css = readFileSync(resolve(__dirname, 'v2-overview.css'), 'utf-8')

describe('v2 overview CSS', () => {
  it('keeps mobile attention action below wrapping reason text', () => {
    expect(css).toContain('@media (max-width: 640px)')

    const row = declarationsForSelector(css, '.v2-overview-attention-row')
    expect(row.display).toBe('grid')
    expect(row['grid-template-columns']).toBe('auto minmax(0, 1fr)')

    const action = declarationsForSelector(css, '.v2-overview-attention-row .ov-attn-act')
    expect(action['grid-column']).toBe('2')
    expect(action['justify-self']).toBe('end')

    const reasonText = declarationsForSelector(
      css,
      '.v2-overview-attention-row .ov-attn-reason > span:last-child',
    )
    expect(reasonText['overflow-wrap']).toBe('anywhere')
  })
})
