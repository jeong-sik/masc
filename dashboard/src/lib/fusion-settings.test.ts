import { describe, it, expect } from 'vitest'
import { readFusionSettings, applyFusionSettings, FUSION_SETTINGS_DEFAULTS } from './fusion-settings'

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
  it('reads [fusion], [fusion.gate], and the default preset min_answered', () => {
    expect(readFusionSettings(SAMPLE)).toEqual({
      enabled: true,
      defaultPreset: 'trio',
      maxConcurrentPanels: 2,
      perHourBudget: 20,
      minAnswered: 2,
    })
  })

  it('falls back to defaults when keys are absent (no fabricated permissive values)', () => {
    expect(readFusionSettings('[runtime]\ndefault = "x.y"\n')).toEqual(FUSION_SETTINGS_DEFAULTS)
  })
})

describe('applyFusionSettings', () => {
  it('round-trips through read (apply then read returns the same values)', () => {
    const next = applyFusionSettings(SAMPLE, {
      enabled: false,
      defaultPreset: 'trio',
      maxConcurrentPanels: 4,
      perHourBudget: 30,
      minAnswered: 3,
    })
    expect(readFusionSettings(next)).toEqual({
      enabled: false,
      defaultPreset: 'trio',
      maxConcurrentPanels: 4,
      perHourBudget: 30,
      minAnswered: 3,
    })
  })

  it('writes min_answered into the default preset table, not [fusion]', () => {
    const next = applyFusionSettings(SAMPLE, { ...readFusionSettings(SAMPLE), minAnswered: 3 })
    // the [fusion.presets.trio] line changed to 3; [fusion] has no min_answered
    expect(next).toContain('[fusion.presets.trio]')
    expect(next.split('[fusion.presets.trio]')[1]).toContain('min_answered = 3')
    expect(next.split('[fusion]')[1]?.split('[fusion.gate]')[0]).not.toContain('min_answered')
  })

  it('preserves comments and untouched sections/keys', () => {
    const next = applyFusionSettings(SAMPLE, { ...readFusionSettings(SAMPLE), maxConcurrentPanels: 5 })
    expect(next).toContain('# live runtime config')
    expect(next).toContain('[runtime]')
    expect(next).toContain('default = "x.y"')
    expect(next).toContain('judge = "j"')
  })
})
