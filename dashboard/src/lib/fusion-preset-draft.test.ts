import { describe, expect, it } from 'vitest'
import type { FusionPresetConfigView } from '../api/dashboard'
import {
  emptyPresetDraft,
  parseDraftOptionalPositiveInt,
  parseDraftOptionalPositiveNumber,
  parseDraftPositiveInt,
  presetDraftFromView,
  presetFromDraft,
  settingsDraftFromView,
  settingsFromDraft,
} from './fusion-preset-draft'

const PRESET: FusionPresetConfigView = {
  name: 'quorum',
  panels: [
    { models: ['a', 'b'], label: 'wide', systemPrompt: 'panelist', webTools: true, maxOutputTokens: 2048, timeoutS: 240 },
    { models: ['c'], label: '', systemPrompt: 'careful', webTools: false, maxOutputTokens: null, timeoutS: null },
  ],
  judge: 'meta',
  judgeSystemPrompt: 'judge',
  judgeMaxOutputTokens: null,
  judgeTimeoutS: 90.5,
  judges: [
    { model: 'j0', label: 'evidence', systemPrompt: 'lens', webTools: false, maxOutputTokens: 512, timeoutS: null },
  ],
  minAnswered: 2,
}

describe('preset draft round trip', () => {
  it('renders an unset optional as an empty field and reads it back as null', () => {
    const draft = presetDraftFromView(PRESET)
    expect(draft.panels[1]).toMatchObject({ maxOutputTokens: '', timeoutS: '' })
    expect(draft.judgeMaxOutputTokens).toBe('')
    expect(draft.judgeTimeoutS).toBe('90.5')
    expect(draft.minAnswered).toBe('2')
    const back = presetFromDraft(draft, draft.name)
    expect(back).toEqual({ ok: true, value: PRESET })
  })

  it('writes the preset under the name the caller passes, not the field', () => {
    const draft = { ...presetDraftFromView(PRESET), name: 'copy' }
    const back = presetFromDraft(draft, 'copy')
    if (!back.ok) throw new Error(back.message)
    expect(back.value.name).toBe('copy')
    expect(back.value.panels).toEqual(PRESET.panels)
  })

  it('refuses a padded or empty name before anything is sent', () => {
    const draft = presetDraftFromView(PRESET)
    expect(presetFromDraft(draft, '')).toMatchObject({ ok: false })
    expect(presetFromDraft(draft, ' quorum')).toMatchObject({ ok: false })
  })

  it('names the field that could not become a number', () => {
    const draft = presetDraftFromView(PRESET)
    const firstGroup = draft.panels[0]
    const firstJudge = draft.judges[0]
    if (firstGroup === undefined || firstJudge === undefined) throw new Error('fixture has a group and a judge')
    const badGroup = presetFromDraft({
      ...draft,
      panels: [{ ...firstGroup, timeoutS: '-3' }],
    }, draft.name)
    expect(badGroup).toMatchObject({ ok: false, message: expect.stringContaining('패널 그룹 1 timeout_s') })
    const badJudge = presetFromDraft({
      ...draft,
      judges: [{ ...firstJudge, maxOutputTokens: '1.5' }],
    }, draft.name)
    expect(badJudge).toMatchObject({ ok: false, message: expect.stringContaining('1차 심판 1 max_output_tokens') })
    const badQuorum = presetFromDraft({ ...draft, minAnswered: '0' }, draft.name)
    expect(badQuorum).toMatchObject({ ok: false, message: expect.stringContaining('min_answered') })
  })

  it('starts an empty draft with one panel group and a quorum of one', () => {
    const draft = emptyPresetDraft()
    expect(draft.panels).toHaveLength(1)
    expect(draft.judges).toHaveLength(0)
    expect(draft.minAnswered).toBe('1')
  })
})

describe('settings draft', () => {
  it('round-trips enabled, default_preset and the staged group size', () => {
    const draft = settingsDraftFromView({ enabled: true, defaultPreset: 'quorum', stagedJudgeGroupSize: 3, presets: [] })
    expect(draft.stagedJudgeGroupSize).toBe('3')
    expect(settingsFromDraft(draft)).toEqual({
      ok: true,
      value: { enabled: true, defaultPreset: 'quorum', stagedJudgeGroupSize: 3 },
    })
  })

  it('refuses a padded default_preset and a non-positive group size', () => {
    expect(settingsFromDraft({ enabled: true, defaultPreset: ' x', stagedJudgeGroupSize: '3' }))
      .toMatchObject({ ok: false, message: expect.stringContaining('default_preset') })
    expect(settingsFromDraft({ enabled: true, defaultPreset: 'x', stagedJudgeGroupSize: '0' }))
      .toMatchObject({ ok: false, message: expect.stringContaining('staged_judge_group_size') })
  })
})

describe('numeric field parsers', () => {
  it('accepts positive integers only', () => {
    expect(parseDraftPositiveInt('n', ' 12 ')).toEqual({ ok: true, value: 12 })
    for (const raw of ['', '0', '-1', '1.5', 'abc', '1e3']) {
      expect(parseDraftPositiveInt('n', raw)).toMatchObject({ ok: false, message: 'n은 1 이상의 정수여야 합니다.' })
    }
  })

  it('treats an empty optional as null and rejects the rest like the required form', () => {
    expect(parseDraftOptionalPositiveInt('n', '')).toEqual({ ok: true, value: null })
    expect(parseDraftOptionalPositiveInt('n', '  ')).toEqual({ ok: true, value: null })
    expect(parseDraftOptionalPositiveInt('n', '7')).toEqual({ ok: true, value: 7 })
    expect(parseDraftOptionalPositiveInt('n', '0')).toMatchObject({ ok: false })
  })

  it('accepts positive decimals for a timeout', () => {
    expect(parseDraftOptionalPositiveNumber('t', '')).toEqual({ ok: true, value: null })
    expect(parseDraftOptionalPositiveNumber('t', '90.5')).toEqual({ ok: true, value: 90.5 })
    expect(parseDraftOptionalPositiveNumber('t', '240')).toEqual({ ok: true, value: 240 })
    for (const raw of ['0', '-2', '.5', '1e2', 'soon']) {
      expect(parseDraftOptionalPositiveNumber('t', raw)).toMatchObject({ ok: false, message: 't은 0보다 큰 숫자여야 합니다.' })
    }
  })
})
