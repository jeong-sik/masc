import { describe, it, expect } from 'vitest'
import {
  readFusionSettings,
  readFusionSettingsResult,
  readFusionPresetMinAnswered,
  applyFusionSettings,
  applyFusionPresetComposition,
  FUSION_SETTINGS_DEFAULTS,
} from './fusion-settings'

// SAMPLE still carries a [fusion.gate] per_hour_budget line: RFC-0277 removed the
// key from the backend, so the editor must IGNORE it (never read/write it) while
// leaving it untouched in the file. The preservation test below pins that.
const SAMPLE = `# live runtime config
[fusion]
enabled = true
default_preset = "trio"

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
      minAnswered: 2,
    })
  })

  it('falls back to defaults when keys are absent (no fabricated permissive values)', () => {
    expect(readFusionSettings('[runtime]\ndefault = "x.y"\n')).toEqual(FUSION_SETTINGS_DEFAULTS)
  })

  it('surfaces malformed scalars instead of coercing them into plausible values', () => {
    const src = '[fusion]\nenabled = maybe\n'
    const result = readFusionSettingsResult(src)
    expect(result.ok).toBe(false)
    if (!result.ok) {
      expect(result.issues.map(issue => issue.key)).toEqual(['fusion.enabled'])
    }
    expect(() => readFusionSettings(src)).toThrow(/Invalid fusion settings/)
  })

  it('parses TOML string escapes and rejects JSON-only escapes', () => {
    expect(readFusionSettings(SAMPLE.replace('default_preset = "trio"', 'default_preset = "tri\\u006F"')).defaultPreset)
      .toBe('trio')

    const rocket = String.fromCodePoint(0x1f680)
    expect(readFusionSettings(`[fusion]
enabled = false
default_preset = "rocket\\U0001F680"
`).defaultPreset).toBe(`rocket${rocket}`)

    const invalid = readFusionSettingsResult(SAMPLE.replace('default_preset = "trio"', 'default_preset = "tri\\/o"'))
    expect(invalid.ok).toBe(false)
    if (!invalid.ok) {
      expect(invalid.issues[0]).toMatchObject({
        key: 'fusion.default_preset',
        message: 'unsupported TOML string escape',
      })
    }
  })

  it('parses single-quoted default_preset and rejects unknown preset sections only when enabled', () => {
    const singleQuoted = SAMPLE.replace('default_preset = "trio"', "default_preset = 'trio'")
    expect(readFusionSettings(singleQuoted).defaultPreset).toBe('trio')
    expect(readFusionSettings('[fusion]\nenabled = false\ndefault_preset = \'tri#o\'\n').defaultPreset).toBe('tri#o')

    const unknownPreset = SAMPLE.replace('default_preset = "trio"', 'default_preset = "missing"')
    const result = readFusionSettingsResult(unknownPreset)
    expect(result.ok).toBe(false)
    if (!result.ok) {
      expect(result.issues[0]?.key).toBe('fusion.presets.missing.min_answered')
    }

    const disabledUnknownPreset = `[fusion]
enabled = false
default_preset = "old"
`
    expect(readFusionSettings(disabledUnknownPreset)).toEqual({
      enabled: false,
      defaultPreset: 'old',
      minAnswered: 1,
    })
  })

  it('reads min_answered for a specific preset without changing default_preset', () => {
    const withDuo = `${SAMPLE}
[fusion.presets.duo]
panel = ["a", "b"]
judge = "j"
min_answered = 1
`
    expect(readFusionSettings(withDuo).defaultPreset).toBe('trio')
    expect(readFusionPresetMinAnswered(withDuo, 'duo')).toBe(1)
    expect(readFusionPresetMinAnswered(withDuo, 'missing')).toBe(1)
  })
})

describe('applyFusionSettings', () => {
  it('round-trips through read (apply then read returns the same values)', () => {
    const next = applyFusionSettings(SAMPLE, {
      enabled: false,
      defaultPreset: 'trio',
      minAnswered: 3,
    })
    expect(readFusionSettings(next)).toEqual({
      enabled: false,
      defaultPreset: 'trio',
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
    const next = applyFusionSettings(SAMPLE, readFusionSettings(SAMPLE))
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
      minAnswered: 1,
    })
    expect(switched.split('[fusion.presets.trio]')[1]?.split('[runtime]')[0]).not.toContain('min_answered')
    expect(switched.split('[fusion.presets.duo]')[1]).toContain('min_answered = 1')

    const cleared = applyFusionSettings(SAMPLE, {
      enabled: true,
      defaultPreset: '',
      minAnswered: 1,
    })
    expect(cleared.split('[fusion.presets.trio]')[1]?.split('[runtime]')[0]).not.toContain('min_answered')
  })

  it('preserves comments and untouched sections/keys', () => {
    const next = applyFusionSettings(SAMPLE, readFusionSettings(SAMPLE))
    expect(next).toContain('# live runtime config')
    expect(next).toContain('[runtime]')
    expect(next).toContain('default = "x.y"')
    expect(next).toContain('judge = "j"')
  })

  it('writes active flat preset panel runtimes and judge runtime', () => {
    const next = applyFusionPresetComposition(SAMPLE, {
      preset: 'trio',
      panel: ['a', 'b', 'd', 'd', ' '],
      judge: 'meta.judge',
    })

    const trio = next.split('[fusion.presets.trio]')[1]?.split('[runtime]')[0] ?? ''
    expect(trio).toContain('panel = ["a", "b", "d"]')
    expect(trio).toContain('judge = "meta.judge"')
    expect(trio).toContain('min_answered = 2')
  })

  it('refuses to flatten grouped panel presets', () => {
    const grouped = `${SAMPLE}
[[fusion.presets.trio.panels]]
panel = ["a", "b"]
`
    expect(() => applyFusionPresetComposition(grouped, {
      preset: 'trio',
      panel: ['x'],
      judge: 'j',
    })).toThrow(/grouped fusion panel presets/)
  })
})
