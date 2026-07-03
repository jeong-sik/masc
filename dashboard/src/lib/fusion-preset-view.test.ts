import { describe, expect, it } from 'vitest'
import { readFusionPresetView } from './fusion-preset-view'

// Mirrors the real runtime.toml shape: a multi-line panel array, a scalar judge,
// multi-line prompt strings between judge and the timeout scalars, then the
// numeric scalars — so the reader must find scalars that follow triple-quoted
// values, and a sibling preset must not bleed into the requested one.
const MULTILINE = `[fusion]
enabled = true
default_preset = "trio"

[fusion.presets.trio]
panel = [
  "ollama_cloud.devstral-2-123b",
  "ollama_cloud.devstral-small-2-24b",
  "ollama_cloud.ministral-3-14b",
]
judge = "ollama_cloud.devstral-2-123b"
panel_system_prompt = """
You are an expert panelist. Answer directly.
"""
panel_timeout_s = 300.0
judge_timeout_s = 250.0
max_tool_calls_per_panel = 0

[fusion.presets.quorum]
panel = ["lens_a", "lens_b"]
judge = "meta"
`

describe('readFusionPresetView', () => {
  it('returns null for an empty preset name', () => {
    expect(readFusionPresetView(MULTILINE, '')).toBeNull()
    expect(readFusionPresetView(MULTILINE, '   ')).toBeNull()
  })

  it('returns null when the preset section is absent', () => {
    expect(readFusionPresetView(MULTILINE, 'nonexistent')).toBeNull()
  })

  it('parses a multi-line panel array plus scalar judge/timeouts/max_tool_calls', () => {
    const view = readFusionPresetView(MULTILINE, 'trio')
    expect(view).not.toBeNull()
    expect(view!.preset).toBe('trio')
    expect(view!.panel).toEqual([
      'ollama_cloud.devstral-2-123b',
      'ollama_cloud.devstral-small-2-24b',
      'ollama_cloud.ministral-3-14b',
    ])
    expect(view!.judge).toBe('ollama_cloud.devstral-2-123b')
    // Scalars are found even though a multi-line prompt string precedes them.
    expect(view!.panelTimeoutS).toBe(300)
    expect(view!.judgeTimeoutS).toBe(250)
    expect(view!.maxToolCallsPerPanel).toBe(0)
  })

  it('scopes to the requested preset and does not inherit a sibling preset', () => {
    const view = readFusionPresetView(MULTILINE, 'quorum')
    expect(view!.panel).toEqual(['lens_a', 'lens_b'])
    expect(view!.judge).toBe('meta')
    // quorum declares no timeouts → null, not the trio values.
    expect(view!.panelTimeoutS).toBeNull()
    expect(view!.judgeTimeoutS).toBeNull()
    expect(view!.maxToolCallsPerPanel).toBeNull()
  })

  it('handles a single-line panel array', () => {
    const src = '[fusion.presets.solo]\npanel = ["only-model"]\njudge = "j"\n'
    const view = readFusionPresetView(src, 'solo')
    expect(view!.panel).toEqual(['only-model'])
    expect(view!.judge).toBe('j')
  })

  it('returns an empty panel and null scalars when keys are absent', () => {
    const src = '[fusion.presets.bare]\n# no keys declared\n'
    const view = readFusionPresetView(src, 'bare')
    expect(view).not.toBeNull()
    expect(view!.panel).toEqual([])
    expect(view!.judge).toBeNull()
    expect(view!.panelTimeoutS).toBeNull()
    expect(view!.maxToolCallsPerPanel).toBeNull()
  })

  it('flags a flat preset as not grouped', () => {
    const view = readFusionPresetView(MULTILINE, 'trio')
    expect(view!.grouped).toBe(false)
    expect(view!.groupCount).toBe(0)
  })
})

// Array-of-tables grammar (fusion_config.ml parse_preset). Shape mirrors
// test/fusion_core/test_fusion.ml `multi_group_toml`: a preset table with a flat
// judge plus two [[fusion.presets.NAME.panels]] groups (2 + 1 models).
const MULTI_GROUP = `
[fusion]
enabled = true
default_preset = "mixed"
[fusion.presets.mixed]
judge = "j"
judge_system_prompt = "synthesize"
[[fusion.presets.mixed.panels]]
panel = ["fast1", "fast2"]
panel_system_prompt = "quick"
web_tools = false
max_tool_calls_per_panel = 0
[[fusion.presets.mixed.panels]]
panel = ["careful1"]
panel_system_prompt = "deliberate"
web_tools = true
max_tool_calls_per_panel = 4
panel_timeout_s = 180.0
`

describe('readFusionPresetView — grouped panels', () => {
  it('reports a grouped preset instead of parsing one group as the whole preset', () => {
    const view = readFusionPresetView(MULTI_GROUP, 'mixed')
    expect(view).not.toBeNull()
    expect(view!.grouped).toBe(true)
    expect(view!.groupCount).toBe(2)
    // Must NOT surface the first group's panel (["fast1","fast2"]) as the preset
    // panel — the silent-partial regression this guards against.
    expect(view!.panel).toEqual([])
    expect(view!.judge).toBeNull()
    expect(view!.panelTimeoutS).toBeNull()
  })

  it('treats a conflicting grouped+flat preset as grouped (never trusts the flat panel)', () => {
    const conflicting = `[fusion.presets.mixed]
panel = ["flat_a", "flat_b"]
judge = "j"
[[fusion.presets.mixed.panels]]
panel = ["group_a"]
`
    const view = readFusionPresetView(conflicting, 'mixed')
    expect(view!.grouped).toBe(true)
    expect(view!.groupCount).toBe(1)
    expect(view!.panel).toEqual([])
  })

  it('does not mistake a sibling preset\'s panel groups for the requested flat preset', () => {
    // `trio` is flat; a separate grouped `mixed` preset in the same document must
    // not make `trio` look grouped, nor bleed its groups into trio.
    const mixedSource = `${MULTILINE}${MULTI_GROUP}`
    const trio = readFusionPresetView(mixedSource, 'trio')
    expect(trio!.grouped).toBe(false)
    expect(trio!.panel).toEqual([
      'ollama_cloud.devstral-2-123b',
      'ollama_cloud.devstral-small-2-24b',
      'ollama_cloud.ministral-3-14b',
    ])
    const mixed = readFusionPresetView(mixedSource, 'mixed')
    expect(mixed!.grouped).toBe(true)
    expect(mixed!.groupCount).toBe(2)
  })

  it('keeps a flat-panel preset flat but counts its first-pass judge tables (JoJ)', () => {
    // Mirrors the real `quorum`: flat panel + flat meta judge + two
    // [[...judges]] first-pass judge tables. Panels stay flat (correctly shown);
    // judgeGroupCount surfaces the meta/first-pass split honestly.
    const quorumLike = `[fusion.presets.quorum]
panel = ["p1", "p2"]
judge = "meta_model"
[[fusion.presets.quorum.judges]]
model = "evidence_model"
label = "evidence"
[[fusion.presets.quorum.judges]]
model = "coverage_model"
label = "coverage"
`
    const view = readFusionPresetView(quorumLike, 'quorum')
    expect(view!.grouped).toBe(false)
    expect(view!.panel).toEqual(['p1', 'p2'])
    // The flat meta judge is shown; group tables use `model=` so they never bleed
    // into the `judge` scalar.
    expect(view!.judge).toBe('meta_model')
    expect(view!.judgeGroupCount).toBe(2)
  })
})
