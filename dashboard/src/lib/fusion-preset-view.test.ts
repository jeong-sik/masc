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
})
