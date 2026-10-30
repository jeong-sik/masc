// Form drafts for the Fusion settings editor.
//
// The editor holds every numeric field as the string in its input, so a
// half-typed value never becomes a fabricated number in state. Conversion to
// the typed view (the value the write API serialises) happens once, on save,
// and refuses malformed input with a Korean sentence before anything is sent.
// The backend stays the validation SSOT for everything a form cannot know
// (route resolution, prompt presence, quorum bounds); those refusals arrive
// as server sentences and are shown verbatim.

import type {
  FusionConfigView,
  FusionJudgeSpecView,
  FusionPanelGroupView,
  FusionPresetConfigView,
} from '../api/dashboard'

export interface FusionSettingsDraft {
  readonly enabled: boolean
  readonly defaultPreset: string
  readonly stagedJudgeGroupSize: string
}

export interface FusionPanelGroupDraft {
  readonly models: readonly string[]
  readonly label: string
  readonly systemPrompt: string
  readonly webTools: boolean
  readonly maxOutputTokens: string
  readonly timeoutS: string
}

export interface FusionJudgeDraft {
  readonly model: string
  readonly label: string
  readonly systemPrompt: string
  readonly webTools: boolean
  readonly maxOutputTokens: string
  readonly timeoutS: string
}

export interface FusionPresetDraft {
  readonly name: string
  readonly panels: readonly FusionPanelGroupDraft[]
  readonly judge: string
  readonly judgeSystemPrompt: string
  readonly judgeMaxOutputTokens: string
  readonly judgeTimeoutS: string
  readonly judges: readonly FusionJudgeDraft[]
  readonly minAnswered: string
}

export type DraftParse<T> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly message: string }

export interface FusionSettingsValue {
  readonly enabled: boolean
  readonly defaultPreset: string
  readonly stagedJudgeGroupSize: number
}

// An unset optional is the empty string in the form and null on the wire.
function optionalNumberField(value: number | null): string {
  return value === null ? '' : String(value)
}

export function settingsDraftFromView(config: FusionConfigView): FusionSettingsDraft {
  return {
    enabled: config.enabled,
    defaultPreset: config.defaultPreset,
    stagedJudgeGroupSize: String(config.stagedJudgeGroupSize),
  }
}

export function emptyPanelGroupDraft(): FusionPanelGroupDraft {
  return { models: [], label: '', systemPrompt: '', webTools: false, maxOutputTokens: '', timeoutS: '' }
}

export function emptyJudgeDraft(): FusionJudgeDraft {
  return { model: '', label: '', systemPrompt: '', webTools: false, maxOutputTokens: '', timeoutS: '' }
}

export function emptyPresetDraft(): FusionPresetDraft {
  return {
    name: '',
    panels: [emptyPanelGroupDraft()],
    judge: '',
    judgeSystemPrompt: '',
    judgeMaxOutputTokens: '',
    judgeTimeoutS: '',
    judges: [],
    minAnswered: '1',
  }
}

function panelGroupDraftFromView(group: FusionPanelGroupView): FusionPanelGroupDraft {
  return {
    models: [...group.models],
    label: group.label,
    systemPrompt: group.systemPrompt,
    webTools: group.webTools,
    maxOutputTokens: optionalNumberField(group.maxOutputTokens),
    timeoutS: optionalNumberField(group.timeoutS),
  }
}

function judgeDraftFromView(judge: FusionJudgeSpecView): FusionJudgeDraft {
  return {
    model: judge.model,
    label: judge.label,
    systemPrompt: judge.systemPrompt,
    webTools: judge.webTools,
    maxOutputTokens: optionalNumberField(judge.maxOutputTokens),
    timeoutS: optionalNumberField(judge.timeoutS),
  }
}

export function presetDraftFromView(preset: FusionPresetConfigView): FusionPresetDraft {
  return {
    name: preset.name,
    panels: preset.panels.map(panelGroupDraftFromView),
    judge: preset.judge,
    judgeSystemPrompt: preset.judgeSystemPrompt,
    judgeMaxOutputTokens: optionalNumberField(preset.judgeMaxOutputTokens),
    judgeTimeoutS: optionalNumberField(preset.judgeTimeoutS),
    judges: preset.judges.map(judgeDraftFromView),
    minAnswered: String(preset.minAnswered),
  }
}

const INTEGER_PATTERN = /^\d+$/
const DECIMAL_PATTERN = /^\d+(\.\d+)?$/

export function parseDraftPositiveInt(label: string, raw: string): DraftParse<number> {
  const trimmed = raw.trim()
  const parsed = Number.parseInt(trimmed, 10)
  if (!INTEGER_PATTERN.test(trimmed) || !Number.isSafeInteger(parsed) || parsed < 1) {
    return { ok: false, message: `${label}은 1 이상의 정수여야 합니다.` }
  }
  return { ok: true, value: parsed }
}

export function parseDraftOptionalPositiveInt(label: string, raw: string): DraftParse<number | null> {
  if (raw.trim() === '') return { ok: true, value: null }
  return parseDraftPositiveInt(label, raw)
}

export function parseDraftOptionalPositiveNumber(label: string, raw: string): DraftParse<number | null> {
  const trimmed = raw.trim()
  if (trimmed === '') return { ok: true, value: null }
  const parsed = Number(trimmed)
  if (!DECIMAL_PATTERN.test(trimmed) || !Number.isFinite(parsed) || parsed <= 0) {
    return { ok: false, message: `${label}은 0보다 큰 숫자여야 합니다.` }
  }
  return { ok: true, value: parsed }
}

function parsePresetName(raw: string): DraftParse<string> {
  if (raw === '' || raw !== raw.trim()) {
    return { ok: false, message: 'preset 이름은 비거나 앞뒤에 공백이 있을 수 없습니다.' }
  }
  return { ok: true, value: raw }
}

export function settingsFromDraft(draft: FusionSettingsDraft): DraftParse<FusionSettingsValue> {
  if (draft.defaultPreset !== draft.defaultPreset.trim()) {
    return { ok: false, message: 'default_preset은 앞뒤에 공백이 있을 수 없습니다.' }
  }
  const stagedJudgeGroupSize = parseDraftPositiveInt('staged_judge_group_size', draft.stagedJudgeGroupSize)
  if (!stagedJudgeGroupSize.ok) return stagedJudgeGroupSize
  return {
    ok: true,
    value: {
      enabled: draft.enabled,
      defaultPreset: draft.defaultPreset,
      stagedJudgeGroupSize: stagedJudgeGroupSize.value,
    },
  }
}

function panelGroupFromDraft(group: FusionPanelGroupDraft, index: number): DraftParse<FusionPanelGroupView> {
  const where = `패널 그룹 ${index + 1}`
  const maxOutputTokens = parseDraftOptionalPositiveInt(`${where} max_output_tokens`, group.maxOutputTokens)
  if (!maxOutputTokens.ok) return maxOutputTokens
  const timeoutS = parseDraftOptionalPositiveNumber(`${where} timeout_s`, group.timeoutS)
  if (!timeoutS.ok) return timeoutS
  return {
    ok: true,
    value: {
      models: [...group.models],
      label: group.label,
      systemPrompt: group.systemPrompt,
      webTools: group.webTools,
      maxOutputTokens: maxOutputTokens.value,
      timeoutS: timeoutS.value,
    },
  }
}

function judgeFromDraft(judge: FusionJudgeDraft, index: number): DraftParse<FusionJudgeSpecView> {
  const where = `1차 심판 ${index + 1}`
  const maxOutputTokens = parseDraftOptionalPositiveInt(`${where} max_output_tokens`, judge.maxOutputTokens)
  if (!maxOutputTokens.ok) return maxOutputTokens
  const timeoutS = parseDraftOptionalPositiveNumber(`${where} timeout_s`, judge.timeoutS)
  if (!timeoutS.ok) return timeoutS
  return {
    ok: true,
    value: {
      model: judge.model,
      label: judge.label,
      systemPrompt: judge.systemPrompt,
      webTools: judge.webTools,
      maxOutputTokens: maxOutputTokens.value,
      timeoutS: timeoutS.value,
    },
  }
}

function collect<T>(parses: readonly DraftParse<T>[]): DraftParse<T[]> {
  const values: T[] = []
  for (const parse of parses) {
    if (!parse.ok) return parse
    values.push(parse.value)
  }
  return { ok: true, value: values }
}

/** The preset the write API will serialise. `name` is passed separately from
    the draft because the caller decides whether the write targets the loaded
    preset (save) or a new one (copy under the name typed into the form). */
export function presetFromDraft(draft: FusionPresetDraft, name: string): DraftParse<FusionPresetConfigView> {
  const presetName = parsePresetName(name)
  if (!presetName.ok) return presetName
  const panels = collect(draft.panels.map(panelGroupFromDraft))
  if (!panels.ok) return panels
  const judgeMaxOutputTokens = parseDraftOptionalPositiveInt('judge_max_output_tokens', draft.judgeMaxOutputTokens)
  if (!judgeMaxOutputTokens.ok) return judgeMaxOutputTokens
  const judgeTimeoutS = parseDraftOptionalPositiveNumber('judge_timeout_s', draft.judgeTimeoutS)
  if (!judgeTimeoutS.ok) return judgeTimeoutS
  const judges = collect(draft.judges.map(judgeFromDraft))
  if (!judges.ok) return judges
  const minAnswered = parseDraftPositiveInt('min_answered', draft.minAnswered)
  if (!minAnswered.ok) return minAnswered
  return {
    ok: true,
    value: {
      name: presetName.value,
      panels: panels.value,
      judge: draft.judge,
      judgeSystemPrompt: draft.judgeSystemPrompt,
      judgeMaxOutputTokens: judgeMaxOutputTokens.value,
      judgeTimeoutS: judgeTimeoutS.value,
      judges: judges.value,
      minAnswered: minAnswered.value,
    },
  }
}
