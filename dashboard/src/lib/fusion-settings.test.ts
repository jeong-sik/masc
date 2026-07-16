import { describe, it, expect } from 'vitest'
import {
  readFusionSettings,
  readFusionSettingsResult,
  applyFusionSettings,
  applyFusionPresetComposition,
  FUSION_SETTINGS_DEFAULTS,
} from './fusion-settings'

const SAMPLE = `# live runtime config
[fusion]
enabled = true
default_preset = "trio"

[fusion.presets.trio]
panel = ["a", "b", "c"]
judge = "j"

[runtime]
default = "x.y"
`

describe('readFusionSettings', () => {
  it('reads the writable [fusion] scalars', () => {
    expect(readFusionSettings(SAMPLE)).toEqual({
      enabled: true,
      defaultPreset: 'trio',
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

  it('parses single-quoted and opaque default_preset values', () => {
    const singleQuoted = SAMPLE.replace('default_preset = "trio"', "default_preset = 'trio'")
    expect(readFusionSettings(singleQuoted).defaultPreset).toBe('trio')
    expect(readFusionSettings('[fusion]\nenabled = false\ndefault_preset = \'tri#o\'\n').defaultPreset).toBe('tri#o')

    const unknownPreset = SAMPLE.replace('default_preset = "trio"', 'default_preset = "missing"')
    expect(readFusionSettings(unknownPreset).defaultPreset).toBe('missing')

    const disabledUnknownPreset = `[fusion]
enabled = false
default_preset = "old"
`
    expect(readFusionSettings(disabledUnknownPreset)).toEqual({
      enabled: false,
      defaultPreset: 'old',
    })
  })
})

describe('applyFusionSettings', () => {
  it('round-trips through read (apply then read returns the same values)', () => {
    const next = applyFusionSettings(SAMPLE, {
      enabled: false,
      defaultPreset: 'trio',
    })
    expect(readFusionSettings(next)).toEqual({
      enabled: false,
      defaultPreset: 'trio',
    })
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
