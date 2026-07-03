// Writable Fusion settings editor (RFC-0273 §3.2 deferred Settings editor).
//
// Self-contained so it does NOT depend on the read-only defaults preview in
// settings-surface. Loads the live runtime.toml via fetchRuntimeTomlConfig,
// edits the [fusion] settings through
// the pure fusion-settings helpers, and writes back via saveRuntimeTomlConfig
// (POST /api/v1/runtime/config/raw → Runtime.save_config_text validates +
// atomically persists + reloads). The backend is the validation SSOT: an
// out-of-range min_answered is rejected on save and surfaced as an error here.
// The panel also blocks malformed local form state before POST so invalid UI
// input is not sent as a fabricated numeric value.
import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import { fetchRuntimeTomlConfig, saveRuntimeTomlConfig } from '../api/dashboard'
import { errorToString } from '../lib/format-string'
import {
  applyFusionSettings,
  readFusionPresetMinAnswered,
  readFusionSettingsResult,
  type FusionSettings,
  type FusionSettingsParseIssue,
} from '../lib/fusion-settings'
import { readFusionPresetView } from '../lib/fusion-preset-view'
import { refreshRuntimeConfigConsumers } from '../lib/runtime-config-refresh'

type EditorState = 'loading' | 'idle' | 'saving' | 'saved' | 'error'
type FusionSettingsDraft = {
  readonly enabled: boolean
  readonly defaultPreset: string
  readonly maxConcurrentPanels: string
  readonly minAnswered: string
}

function draftFromSettings(s: FusionSettings): FusionSettingsDraft {
  return {
    enabled: s.enabled,
    defaultPreset: s.defaultPreset,
    maxConcurrentPanels: String(s.maxConcurrentPanels),
    minAnswered: String(s.minAnswered),
  }
}

function parseDraftPositiveInt(label: string, raw: string): number | string {
  const trimmed = raw.trim()
  if (!/^\d+$/.test(trimmed)) return `${label}은 1 이상의 정수여야 합니다.`
  const parsed = Number.parseInt(trimmed, 10)
  return Number.isSafeInteger(parsed) && parsed >= 1 ? parsed : `${label}은 1 이상의 정수여야 합니다.`
}

function settingsFromDraft(draft: FusionSettingsDraft): FusionSettings | string {
  const defaultPreset = draft.defaultPreset
  if (defaultPreset !== '' && defaultPreset.trim() === '') return 'default_preset은 공백만 입력할 수 없습니다.'
  const maxConcurrentPanels = parseDraftPositiveInt('max_concurrent_panels', draft.maxConcurrentPanels)
  if (typeof maxConcurrentPanels === 'string') return maxConcurrentPanels
  const minAnswered = parseDraftPositiveInt('min_answered', draft.minAnswered)
  if (typeof minAnswered === 'string') return minAnswered
  return {
    enabled: draft.enabled,
    defaultPreset,
    maxConcurrentPanels,
    minAnswered,
  }
}

function parseIssueMessage(issues: readonly { key: string; message: string; token: string | undefined }[]): string {
  return issues.map(issue => `${issue.key}: ${issue.message}${issue.token === undefined ? '' : ` (${issue.token})`}`).join('; ')
}

function isFusionSettingsParseIssue(value: unknown): value is FusionSettingsParseIssue {
  return typeof value === 'object' && value !== null && 'key' in value && 'message' in value
}

function issueArrayMessage(value: unknown): string {
  if (!Array.isArray(value)) return ''
  const rendered = value
    .map(issue => {
      if (isFusionSettingsParseIssue(issue)) {
        return `${issue.key}: ${issue.message}${issue.token === undefined ? '' : ` (${issue.token})`}`
      }
      if (typeof issue === 'string') return issue
      if (typeof issue === 'object' && issue !== null) {
        const record = issue as Record<string, unknown>
        const key = typeof record.key === 'string' ? record.key : undefined
        const message = typeof record.message === 'string' ? record.message : undefined
        const reason = typeof record.reason === 'string' ? record.reason : undefined
        return [key, message ?? reason].filter(Boolean).join(': ')
      }
      return ''
    })
    .filter(Boolean)
  return rendered.join('; ')
}

function backendValidationMessage(cfg: { message?: string | null; reason?: string | null; issues?: unknown }): string {
  return (
    issueArrayMessage(cfg.issues)
    || cfg.message?.trim()
    || cfg.reason?.trim()
    || '백엔드 검증 거부. 변경이 저장되지 않았습니다.'
  )
}

export function FusionSettingsPanel() {
  const [source, setSource] = useState<string | null>(null)
  const [draft, setDraft] = useState<FusionSettingsDraft | null>(null)
  const [state, setState] = useState<EditorState>('loading')
  const [error, setError] = useState('')
  const [savedMessage, setSavedMessage] = useState('')
  const mountedRef = useRef(true)

  useEffect(() => {
    let active = true
    mountedRef.current = true
    const load = async () => {
      try {
        const cfg = await fetchRuntimeTomlConfig()
        if (!active) return
        const parsed = readFusionSettingsResult(cfg.source_text)
        if (!parsed.ok) {
          setSource(cfg.source_text)
          setDraft(null)
          setError(parseIssueMessage(parsed.issues))
          setState('error')
          return
        }
        setSource(cfg.source_text)
        setDraft(draftFromSettings(parsed.settings))
        setState('idle')
      } catch (err) {
        if (!active) return
        setError(errorToString(err))
        setState('error')
      }
    }
    void load()
    return () => {
      active = false
      mountedRef.current = false
    }
  }, [])

  if (state === 'loading') {
    return html`<div class="set-hint" data-testid="fusion-settings-loading">설정을 불러오는 중…</div>`
  }
  if (draft === null || source === null) {
    return html`<div class="set-err" data-testid="fusion-settings-error">${error || '설정을 읽을 수 없습니다.'}</div>`
  }

  const patch = (next: Partial<FusionSettingsDraft>) => {
    setDraft({ ...draft, ...next })
    // Editing after a save dismisses the stale saved/error banner.
    if (state === 'saved' || state === 'error') {
      setSavedMessage('')
      setState('idle')
    }
  }

  const patchDefaultPreset = (defaultPreset: string) => {
    const next: { defaultPreset: string; minAnswered?: string } = { defaultPreset }
    if (source !== null) {
      const minAnswered = readFusionPresetMinAnswered(source, defaultPreset)
      if (typeof minAnswered === 'number') {
        next.minAnswered = String(minAnswered)
      } else {
        setError(parseIssueMessage([minAnswered]))
        setState('error')
      }
    }
    patch(next)
  }

  const onSave = async () => {
    if (source === null) return
    const settings = settingsFromDraft(draft)
    if (typeof settings === 'string') {
      setError(settings)
      setState('error')
      return
    }
    setState('saving')
    setError('')
    try {
      const cfg = await saveRuntimeTomlConfig(applyFusionSettings(source, settings))
      if (!mountedRef.current) return
      if (!cfg.ok) {
        setError(backendValidationMessage(cfg))
        setState('error')
        return
      }
      const parsed = readFusionSettingsResult(cfg.source_text)
      if (!parsed.ok) {
        setError(parseIssueMessage(parsed.issues))
        setState('error')
        return
      }
      setSource(cfg.source_text)
      setDraft(draftFromSettings(parsed.settings))
      try {
        await refreshRuntimeConfigConsumers()
        setSavedMessage(cfg.reloaded ? '저장됨 (reload 완료)' : '저장됨')
      } catch (err) {
        setError(`저장됨, 대시보드 런타임 갱신 실패: ${errorToString(err)}`)
        setState('error')
        return
      }
      setState('saved')
    } catch (err) {
      if (!mountedRef.current) return
      setError(errorToString(err))
      setState('error')
    }
  }

  const str = (e: Event) => (e.target as HTMLInputElement).value
  const checked = (e: Event) => (e.target as HTMLInputElement).checked

  // Read-only view of the active preset's composition (panel models · judge ·
  // timeouts · max_tool_calls), parsed from the same runtime.toml source the
  // editor already loaded. Shown only when the default_preset resolves to a real
  // [fusion.presets.<preset>] table that actually declares panel models — a
  // preset with no panel has no composition worth displaying. The editor scalars
  // above stay writable.
  const presetView = readFusionPresetView(source, draft.defaultPreset)
  // Flat preset with panel models → full read-only card. Grouped preset
  // ([[...panels]] array-of-tables) → fail-visible note (a single flat card
  // cannot represent N groups without silently dropping some).
  const showPresetView = presetView !== null && !presetView.grouped && presetView.panel.length > 0
  const showGroupedNote = presetView !== null && presetView.grouped
  const timeoutLabel = (value: number | null): string => (value === null ? '—' : `${value}s`)

  return html`
    <div class="set-fusion-editor" data-testid="fusion-settings-editor">
      <label class="set-line">
        <span>Fusion 심의 활성 (enabled)</span>
        <input type="checkbox" checked=${draft.enabled} onChange=${(e: Event) => patch({ enabled: checked(e) })} />
      </label>
      <label class="set-line">
        <span>기본 프리셋 (default_preset)</span>
        <input type="text" value=${draft.defaultPreset} onInput=${(e: Event) => patchDefaultPreset(str(e))} />
      </label>
      <label class="set-line">
        <span>동시 패널 수 (max_concurrent_panels)</span>
        <input type="number" step="1" data-testid="fusion-max-concurrent-panels" value=${draft.maxConcurrentPanels}
          onInput=${(e: Event) => patch({ maxConcurrentPanels: str(e) })} />
      </label>
      <label class="set-line">
        <span>최소 응답 패널 (${draft.defaultPreset || '프리셋'} min_answered)</span>
        <input type="number" step="1" data-testid="fusion-min-answered" value=${draft.minAnswered}
          onInput=${(e: Event) => patch({ minAnswered: str(e) })} />
      </label>
      <div class="set-line">
        <button type="button" data-testid="fusion-settings-save" onClick=${onSave} disabled=${state === 'saving'}>
          ${state === 'saving' ? '저장 중…' : '저장'}
        </button>
        ${state === 'saved' && html`<span class="set-ok" data-testid="fusion-settings-saved">${savedMessage}</span>`}
        ${state === 'error' && html`<span class="set-err" data-testid="fusion-settings-error">${error}</span>`}
      </div>
      ${showGroupedNote && presetView
        ? html`
            <div class="set-sub-h">${presetView.preset} 프리셋</div>
            <div class="set-hint" data-testid="fusion-preset-grouped">
              그룹형 패널 구성 · ${presetView.groupCount}개 그룹 (<span class="mono">[[fusion.presets.${presetView.preset}.panels]]</span>) · 미리보기 미지원
            </div>
          `
        : null}
      ${showPresetView && presetView
        ? html`
            <div class="set-sub-h">${presetView.preset} 프리셋</div>
            <div class="set-fus-preset" data-testid="fusion-preset-view">
              <div class="set-fus-lane">
                <div class="set-fus-lane-h">panel · ${presetView.panel.length}</div>
                ${presetView.panel.map(id => html`<div key=${id} class="set-fus-model mono" data-testid="fusion-preset-panel-model">${id}</div>`)}
              </div>
              <div class="set-fus-lane">
                <div class="set-fus-lane-h" data-testid="fusion-preset-judge-lane-h">judge${presetView.judgeGroupCount > 0 ? ` · 메타 (1차 심판 ${presetView.judgeGroupCount} · judge-of-judges)` : ''}</div>
                ${presetView.judge
                  ? html`<div class="set-fus-model judge mono" data-testid="fusion-preset-judge">${presetView.judge}</div>`
                  : html`<div class="set-fus-model judge mono" data-testid="fusion-preset-judge">미지정</div>`}
              </div>
            </div>
            <div class="set-mcp-detail mono" data-testid="fusion-preset-timing" style=${{ marginTop: 10 }}>
              panel_timeout ${timeoutLabel(presetView.panelTimeoutS)} · judge_timeout ${timeoutLabel(presetView.judgeTimeoutS)} · max_tool_calls_per_panel ${presetView.maxToolCallsPerPanel ?? '—'} (0 = 무제한)
            </div>
          `
        : null}
    </div>
  `
}
