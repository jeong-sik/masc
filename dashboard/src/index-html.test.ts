import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

const html = readFileSync(resolve(__dirname, '../index.html'), 'utf8')

describe('dashboard index.html startup resources', () => {
  it('does not block first paint on remote font stylesheets', () => {
    expect(html).not.toContain('fonts.googleapis.com')
    expect(html).not.toContain('fonts.gstatic.com')
    expect(html).not.toMatch(/<link[^>]+rel=["']stylesheet["'][^>]+https:\/\//i)
  })
})
