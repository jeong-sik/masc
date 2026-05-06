import { readFileSync } from 'node:fs'

import { describe, expect, it } from 'vitest'

const readSource = (relativePath: string) =>
  readFileSync(new URL(relativePath, import.meta.url), 'utf8')

describe('cockpit status tray source', () => {
  const sources = [
    ['live cockpit kit', '../cockpit-kit/StatusTray.jsx'],
    ['design-system cockpit kit', '../design-system/ui_kits/cockpit/StatusTray.jsx'],
  ] as const

  it.each(sources)('uses MASC_DATA threshold knobs in %s', (_label, path) => {
    const src = readSource(path)
    expect(src).toContain('status_tray_thresholds')
    expect(src).toContain('statusTrayThresholds')
    expect(src).toContain('failUrgent')
    expect(src).toContain('cascadeInfo')
  })

  it.each(sources)('does not branch on fixed event thresholds in %s', (_label, path) => {
    const src = readSource(path)
    expect(src).not.toMatch(/\bfails\s*>=\s*3\b/)
    expect(src).not.toMatch(/\bcascades\s*>=\s*2\b/)
    expect(src).not.toMatch(/\bcounts\.fails\s*>=\s*3\b/)
    expect(src).not.toMatch(/\bcounts\.cascades\s*>=\s*2\b/)
  })
})
