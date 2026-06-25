import { describe, it, expect } from 'vitest'
import { readFusionSettings, applyFusionSettings, FUSION_SETTINGS_DEFAULTS } from './fusion-settings'

// SAMPLE still carries a [fusion.gate] per_hour_budget line: RFC-0277 removed the
// key from the backend, so the editor must IGNORE it (never read/write it) while
// leaving it untouched in the file. The preservation test below pins that.
const SAMPLE = `# live runtime config
[fusion]
enabled = true
default_preset = "trio"
max_concurrent_panels = 2

[fusion.gate]
per_hour_budget = 20

[fusion.presets.trio]
panel = ["a", "b", "c"]
judge = "j"
min_answered = 2

[runtime]
default = "x.y"
`

describe('readFusionSettings', () => {
  it('reads [fusion] + the default preset min_answered (per_hour_budget not surfaced)', () => {
    expect(readFusionSettings(SAMPLE)).toEqual({
      enabled: true,
      defaultPreset: 'trio',
      maxConcurrentPanels: 2,
      minAnswered: 2,
    })
  })

  it('falls back to defaults when keys are absent (no fabricated permissive values)', () => {
    expect(readFusionSettings('[runtime]\ndefault = "x.y"\n')).toEqual(FUSION_SETTINGS_DEFAULTS)
  })

  it('malformed scalars fall back to the conservative default (read-side; backend validates on save)', () => {
    const src = '[fusion]\nenabled = maybe\nmax_concurrent_panels = abc\n'
    const s = readFusionSettings(src)
    expect(s.enabled).toBe(false) // any non-"true" token
    expect(s.maxConcurrentPanels).toBe(FUSION_SETTINGS_DEFAULTS.maxConcurrentPanels)
  })
})

describe('applyFusionSettings', () => {
  it('round-trips through read (apply then read returns the same values)', () => {
    const next = applyFusionSettings(SAMPLE, {
      enabled: false,
      defaultPreset: 'trio',
      maxConcurrentPanels: 4,
      minAnswered: 3,
    })
    expect(readFusionSettings(next)).toEqual({
      enabled: false,
      defaultPreset: 'trio',
      maxConcurrentPanels: 4,
      minAnswered: 3,
    })
  })

  it('writes min_answered into the default preset table, not [fusion]', () => {
    const next = applyFusionSettings(SAMPLE, { ...readFusionSettings(SAMPLE), minAnswered: 3 })
    expect(next).toContain('[fusion.presets.trio]')
    expect(next.split('[fusion.presets.trio]')[1]).toContain('min_answered = 3')
    expect(next.split('[fusion]')[1]?.split('[fusion.gate]')[0]).not.toContain('min_answered')
  })

  it('never touches the removed per_hour_budget key (RFC-0277)', () => {
    const next = applyFusionSettings(SAMPLE, { ...readFusionSettings(SAMPLE), maxConcurrentPanels: 5 })
    // unchanged verbatim — the editor neither reads nor writes it
    expect(next).toContain('per_hour_budget = 20')
  })

  it('preserves comments and untouched sections/keys', () => {
    const next = applyFusionSettings(SAMPLE, { ...readFusionSettings(SAMPLE), maxConcurrentPanels: 5 })
    expect(next).toContain('# live runtime config')
    expect(next).toContain('[runtime]')
    expect(next).toContain('default = "x.y"')
    expect(next).toContain('judge = "j"')
  })
})
