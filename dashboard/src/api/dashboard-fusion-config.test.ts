// Typed fusion config projection + topology capability gating.
//
// The gating is the part worth pinning: the tool advertises five topologies,
// but judge-of-judges needs >= 2 first-pass judges and the staged form needs
// the roster to divide into at least two full groups. Before the config API was
// consumed, the UI could only offer all five and let the backend refuse — which
// is exactly how the operational config sat for a long time with presets that
// could never run the topologies they appeared to support.

import { describe, expect, it } from 'vitest'
import { parseFusionConfigResponse, runnableTopologies } from './dashboard-fusion'
import type { FusionPresetConfigView } from './dashboard-fusion'

function preset(name: string, judges: number): FusionPresetConfigView {
  return {
    name,
    panels: [
      {
        models: ['p.one', 'p.two'],
        label: '',
        systemPrompt: 'panelist',
        webTools: false,
        maxOutputTokens: null,
        timeoutS: null,
      },
    ],
    judge: 'p.meta',
    judgeSystemPrompt: 'meta',
    judgeMaxOutputTokens: null,
    judgeTimeoutS: null,
    judges: Array.from({ length: judges }, (_, i) => ({
      model: `p.j${i}`,
      label: `lens${i}`,
      systemPrompt: 'lens',
      webTools: false,
      maxOutputTokens: null,
      timeoutS: null,
    })),
    minAnswered: 1,
  }
}

describe('parseFusionConfigResponse', () => {
  it('reads the deadline and budget axes the raw-TOML reader could not see', () => {
    const parsed = parseFusionConfigResponse({
      config: {
        enabled: true,
        default_preset: 'trio',
        staged_judge_group_size: 3,
        presets: [
          {
            name: 'trio',
            panels: [
              {
                models: ['a', 'b'],
                label: 'lens',
                system_prompt: 'panelist',
                web_tools: true,
                max_output_tokens: 2048,
                timeout_s: 240,
              },
            ],
            judge: 'j',
            judge_system_prompt: 'judge',
            judge_max_output_tokens: 4096,
            judge_timeout_s: 180,
            judges: [
              {
                model: 'j1',
                label: 'evidence',
                system_prompt: 'lens',
                web_tools: false,
                max_output_tokens: null,
                timeout_s: 90.5,
              },
            ],
            min_answered: 2,
          },
        ],
      },
    })
    expect(parsed.enabled).toBe(true)
    expect(parsed.stagedJudgeGroupSize).toBe(3)
    const only = parsed.presets.at(0)
    if (!only) throw new Error('expected exactly one preset')
    expect(only.panels.at(0)?.timeoutS).toBe(240)
    expect(only.panels.at(0)?.maxOutputTokens).toBe(2048)
    expect(only.panels.at(0)?.models).toEqual(['a', 'b'])
    expect(only.judgeTimeoutS).toBe(180)
    expect(only.judges.at(0)?.timeoutS).toBe(90.5)
    expect(only.minAnswered).toBe(2)
  })

  it('keeps an unset optional as null instead of inventing a number', () => {
    const parsed = parseFusionConfigResponse({
      config: {
        enabled: true,
        default_preset: 'p',
        staged_judge_group_size: 3,
        presets: [
          {
            name: 'p',
            panels: [{ models: ['a'], label: '', system_prompt: 's', web_tools: false }],
            judge: 'j',
            judge_system_prompt: 'j',
            judge_timeout_s: null,
            judges: [],
            min_answered: 1,
          },
        ],
      },
    })
    const first = parsed.presets.at(0)
    if (!first) throw new Error('expected exactly one preset')
    expect(first.judgeTimeoutS).toBeNull()
    expect(first.panels.at(0)?.timeoutS).toBeNull()
  })
})

describe('runnableTopologies', () => {
  it('offers only the single-judge topologies when a preset has no first-pass judges', () => {
    expect(runnableTopologies(preset('trio', 0), 3)).toEqual([
      'simple',
      'refine',
      'conditional',
    ])
  })

  it('adds judge-of-judges at two judges but not the staged form', () => {
    expect(runnableTopologies(preset('quorum', 2), 3)).toEqual([
      'simple',
      'refine',
      'conditional',
      'judge_of_judges',
    ])
  })

  it('adds the staged form once the roster fills two whole groups', () => {
    expect(runnableTopologies(preset('council', 6), 3)).toContain('staged_judge_of_judges')
  })

  it('rejects a ragged roster the backend would refuse at run time', () => {
    // 8 judges with group size 3 leaves a partial final group; the backend
    // rejects it (Staged_ragged_judges), so the UI must not offer it.
    expect(runnableTopologies(preset('ragged', 8), 3)).not.toContain(
      'staged_judge_of_judges',
    )
  })
})
