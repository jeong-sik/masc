import { describe, it, expect } from 'vitest'
import {
  readFusionSettings,
  readFusionSettingsResult,
  applyFusionSettings,
  FUSION_SETTINGS_DEFAULTS,
} from './fusion-settings'

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

  it('surfaces malformed scalars instead of coercing them into plausible values', () => {
    const src = '[fusion]\nenabled = maybe\nmax_concurrent_panels = 1.5\n'
    const result = readFusionSettingsResult(src)
    expect(result.ok).toBe(false)
    if (!result.ok) {
      expect(result.issues.map(issue => issue.key)).toEqual([
        'fusion.enabled',
        'fusion.max_concurrent_panels',
      ])
    }
    expect(() => readFusionSettings(src)).toThrow(/Invalid fusion settings/)
  })

  it('parses single-quoted default_preset and rejects unknown preset sections only when enabled', () => {
    const singleQuoted = SAMPLE.replace('default_preset = "trio"', "default_preset = 'trio'")
    expect(readFusionSettings(singleQuoted).defaultPreset).toBe('trio')

    const unknownPreset = SAMPLE.replace('default_preset = "trio"', 'default_preset = "missing"')
    const result = readFusionSettingsResult(unknownPreset)
    expect(result.ok).toBe(false)
    if (!result.ok) {
      expect(result.issues[0]?.key).toBe('fusion.presets.missing.min_answered')
    }

    const disabledUnknownPreset = `[fusion]
enabled = false
default_preset = "old"
max_concurrent_panels = 1
`
    expect(readFusionSettings(disabledUnknownPreset)).toEqual({
      enabled: false,
      defaultPreset: 'old',
      maxConcurrentPanels: 1,
      minAnswered: 1,
    })
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

  it('removes stale min_answered from the previous default preset on preset switch or clear', () => {
    const withDuo = `${SAMPLE}
[fusion.presets.duo]
panel = ["a", "b"]
judge = "j"
min_answered = 1
`
    const switched = applyFusionSettings(withDuo, {
      enabled: true,
      defaultPreset: 'duo',
      maxConcurrentPanels: 2,
      minAnswered: 1,
    })
    expect(switched.split('[fusion.presets.trio]')[1]?.split('[runtime]')[0]).not.toContain('min_answered')
    expect(switched.split('[fusion.presets.duo]')[1]).toContain('min_answered = 1')

    const cleared = applyFusionSettings(SAMPLE, {
      enabled: true,
      defaultPreset: '',
      maxConcurrentPanels: 2,
      minAnswered: 1,
    })
    expect(cleared.split('[fusion.presets.trio]')[1]?.split('[runtime]')[0]).not.toContain('min_answered')
  })

  it('rejects invalid local editor values before writing', () => {
    expect(() => applyFusionSettings(SAMPLE, {
      enabled: true,
      defaultPreset: 'trio',
      maxConcurrentPanels: 0,
      minAnswered: 1,
    })).toThrow(/max_concurrent_panels/)
  })

  it('preserves comments and untouched sections/keys', () => {
    const next = applyFusionSettings(SAMPLE, { ...readFusionSettings(SAMPLE), maxConcurrentPanels: 5 })
    expect(next).toContain('# live runtime config')
    expect(next).toContain('[runtime]')
    expect(next).toContain('default = "x.y"')
    expect(next).toContain('judge = "j"')
  })
})
