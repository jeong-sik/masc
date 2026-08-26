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
  applyFusionPresetComposition,
  applyFusionSettings,
  readFusionPresetMinAnswered,
  readFusionSettingsResult,
  type FusionSettings,
} from '../lib/fusion-settings'
import { readFusionPresetView } from '../lib/fusion-preset-view'
import { fetchFusionConfig } from '../api/dashboard'
import type { FusionConfigView } from '../api/dashboard'
import { FusionPresetCard } from './fusion/fusion-preset-card'
import { refreshRuntimeConfigConsumers } from '../lib/runtime-config-refresh'
import { parseRuntimeTomlEnvironment } from '../lib/runtime-toml-config'
import { runtimeConfigCommitReceiptNotice } from '../lib/runtime-config-receipt'

type EditorState = 'loading' | 'idle' | 'saving' | 'saved' | 'error'
type FusionSettingsDraft = {
  readonly enabled: boolean
  readonly defaultPreset: string
  readonly minAnswered: string
  readonly panel: readonly string[]
  readonly judge: string
}

function draftFromSettings(sourceText: string, s: FusionSettings): FusionSettingsDraft {
  const presetView = readFusionPresetView(sourceText, s.defaultPreset)
  const flatPreset = presetView !== null && !presetView.grouped ? presetView : null
  return {
    enabled: s.enabled,
    defaultPreset: s.defaultPreset,
    minAnswered: String(s.minAnswered),
    panel: flatPreset?.panel ?? [],
    judge: flatPreset?.judge ?? '',
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
  const minAnswered = parseDraftPositiveInt('min_answered', draft.minAnswered)
  if (typeof minAnswered === 'string') return minAnswered
  return {
    enabled: draft.enabled,
    defaultPreset,
    minAnswered,
  }
}

function parseIssueMessage(issues: readonly { key: string; message: string; token: string | undefined }[]): string {
  return issues.map(issue => `${issue.key}: ${issue.message}${issue.token === undefined ? '' : ` (${issue.token})`}`).join('; ')
}

function uniqueRuntimeIds(ids: readonly string[]): string[] {
  const seen = new Set<string>()
  const result: string[] = []
  for (const id of ids) {
    const trimmed = id.trim()
    if (trimmed === '' || seen.has(trimmed)) continue
    seen.add(trimmed)
    result.push(trimmed)
  }
  return result
}

function sameRuntimeIds(left: readonly string[], right: readonly string[]): boolean {
  return left.length === right.length && left.every((id, index) => id === right[index])
}

function runtimeOptionsFromSource(sourceText: string, draft: FusionSettingsDraft): string[] {
  const environment = parseRuntimeTomlEnvironment(sourceText)
  return uniqueRuntimeIds([
    ...environment.bindings.map(binding => binding.id),
    ...draft.panel,
    draft.judge,
  ]).sort((a, b) => a.localeCompare(b))
}

function RuntimePanelEditor({
  panel,
  options,
  onChange,
}: {
  panel: readonly string[]
  options: readonly string[]
  onChange: (panel: readonly string[]) => void
}) {
  const addable = options.filter(option => !panel.includes(option))
  return html`
    <div class="set-fusion-runtime-list" data-testid="fusion-panel-runtime-editor">
      <div class="set-fusion-runtime-chips">
        ${panel.length === 0
          ? html`<span class="set-hint" data-testid="fusion-panel-runtime-empty">패널 런타임 없음</span>`
          : panel.map(runtimeId => html`
            <span key=${runtimeId} class="set-fusion-runtime-chip mono">
              ${runtimeId}
              <button
                type="button"
                aria-label=${`${runtimeId} 제거`}
                data-testid="fusion-panel-runtime-remove"
                onClick=${() => onChange(panel.filter(id => id !== runtimeId))}
              >
                ×
              </button>
            </span>
          `)}
      </div>
      <select
        class="set-fusion-runtime-add mono"
        data-testid="fusion-panel-runtime-add"
        value=""
        disabled=${addable.length === 0}
        onChange=${(event: Event) => {
          const value = (event.target as HTMLSelectElement).value
          if (value) onChange([...panel, value])
          ;(event.target as HTMLSelectElement).value = ''
        }}
      >
        <option value="">패널 런타임 추가</option>
        ${addable.map(option => html`<option key=${option} value=${option}>${option}</option>`)}
      </select>
    </div>
  `
}

export function FusionSettingsPanel() {
  const [source, setSource] = useState<string | null>(null)
  // Typed projection of the *parsed* policy — the value the tool executes
  // against. Fetched alongside the raw text because the two answer different
  // questions: the text is what the editor writes into, this is what the
  // backend made of it (deadlines, budgets, first-pass judges, groups).
  const [config, setConfig] = useState<FusionConfigView | null>(null)
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
        // A failed projection must not blank the editor: the raw text still
        // loads and stays writable, the composition card just does not render.
        void fetchFusionConfig()
          .then(loaded => {
            if (active) setConfig(loaded)
          })
          .catch(() => {
            if (active) setConfig(null)
          })
        const parsed = readFusionSettingsResult(cfg.source_text)
        if (!parsed.ok) {
          setSource(cfg.source_text)
          setDraft(null)
          setError(parseIssueMessage(parsed.issues))
          setState('error')
          return
        }
        setSource(cfg.source_text)
        setDraft(draftFromSettings(cfg.source_text, parsed.settings))
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
    const next: {
      defaultPreset: string
      minAnswered?: string
      panel?: readonly string[]
      judge?: string
    } = { defaultPreset }
    if (source !== null) {
      const minAnswered = readFusionPresetMinAnswered(source, defaultPreset)
      if (typeof minAnswered === 'number') {
        next.minAnswered = String(minAnswered)
      } else {
        setError(parseIssueMessage([minAnswered]))
        setState('error')
      }
      const nextPresetView = readFusionPresetView(source, defaultPreset)
      if (nextPresetView !== null && !nextPresetView.grouped) {
        next.panel = nextPresetView.panel
        next.judge = nextPresetView.judge ?? ''
      } else {
        next.panel = []
        next.judge = ''
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
      let nextSourceText = applyFusionSettings(source, settings)
      const activePresetView = readFusionPresetView(source, settings.defaultPreset)
      if (activePresetView !== null && !activePresetView.grouped) {
        const panel = uniqueRuntimeIds(draft.panel)
        const judge = draft.judge.trim()
        const compositionChanged =
          !sameRuntimeIds(activePresetView.panel, panel)
          || (activePresetView.judge ?? '') !== judge
        if (compositionChanged) {
          nextSourceText = applyFusionPresetComposition(nextSourceText, {
            preset: settings.defaultPreset,
            panel,
            judge,
          })
        }
      }
      const cfg = await saveRuntimeTomlConfig(nextSourceText)
      if (!mountedRef.current) return
      const parsed = readFusionSettingsResult(cfg.source_text)
      if (!parsed.ok) {
        setError(parseIssueMessage(parsed.issues))
        setState('error')
        return
      }
      setSource(cfg.source_text)
      setDraft(draftFromSettings(cfg.source_text, parsed.settings))
      const receiptNotice = runtimeConfigCommitReceiptNotice(cfg)
      try {
        await refreshRuntimeConfigConsumers()
        setSavedMessage(`저장됨 · ${receiptNotice}`)
      } catch (err) {
        setError(`저장됨 · ${receiptNotice} · 대시보드 런타임 갱신 실패: ${errorToString(err)}`)
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

  // Read-only view of the active preset's composition (panel models · judge),
  // parsed from the same runtime.toml source the
  // editor already loaded. Shown only when the default_preset resolves to a real
  // [fusion.presets.<preset>] table that actually declares panel models — a
  // preset with no panel has no composition worth displaying. The editor scalars
  // above stay writable.
  const presetView = readFusionPresetView(source, draft.defaultPreset)
  // Flat preset with panel models → full read-only card. Grouped preset
  // ([[...panels]] array-of-tables) → fail-visible note (a single flat card
  // cannot represent N groups without silently dropping some).
  // Grouped presets render fine here (the card walks every group), so the
  // typed card is not gated on the flat-shape check the editor needs.
  const typedPreset =
    config?.presets.find(entry => entry.name === draft.defaultPreset) ?? null
  const showPresetEditor = presetView !== null && !presetView.grouped
  const showGroupedNote = presetView !== null && presetView.grouped
  const runtimeOptions = runtimeOptionsFromSource(source, draft)
  const judgeLabel = presetView?.judgeGroupCount ? 'Judge-of-judges runtime' : 'Judge runtime'

  return html`
    <div class="set-fusion-editor" data-testid="fusion-settings-editor">
      <label class="set-line v2-mobile-operator-target">
        <span>Fusion 심의 활성 (enabled)</span>
        <input type="checkbox" checked=${draft.enabled} onChange=${(e: Event) => patch({ enabled: checked(e) })} />
      </label>
      <label class="set-line">
        <span>기본 프리셋 (default_preset)</span>
        <input type="text" value=${draft.defaultPreset} onInput=${(e: Event) => patchDefaultPreset(str(e))} />
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
      ${showPresetEditor && presetView
        ? html`
            <div class="set-sub-h">${presetView.preset} 런타임 구성</div>
            <div class="set-fusion-composition" data-testid="fusion-preset-composition-editor">
              <label class="set-line set-line-stack">
                <span>Panel runtimes</span>
                <${RuntimePanelEditor}
                  panel=${draft.panel}
                  options=${runtimeOptions}
                  onChange=${(panel: readonly string[]) => patch({ panel })}
                />
              </label>
              <label class="set-line">
                <span>${judgeLabel}</span>
                <select
                  class="set-fusion-runtime-add mono"
                  data-testid="fusion-judge-runtime"
                  value=${draft.judge}
                  onChange=${(event: Event) => patch({ judge: (event.target as HTMLSelectElement).value })}
                >
                  <option value="">미지정</option>
                  ${runtimeOptions.map(option => html`<option key=${option} value=${option}>${option}</option>`)}
                </select>
              </label>
            </div>
          `
        : null}
      ${typedPreset
        ? html`
            <div class="set-sub-h">${typedPreset.name} 프리셋</div>
            <${FusionPresetCard}
              preset=${typedPreset}
              stagedGroupSize=${config?.stagedJudgeGroupSize ?? 3}
            />
          `
        : null}
    </div>
  `
}
