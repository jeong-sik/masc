// Writable Fusion settings editor (RFC-0273 §3.2 deferred Settings editor).
//
// Self-contained so it does NOT touch the read-only prototype widgets in
// settings-surface (their steppers are hardcoded `disabled`). Loads the live
// runtime.toml via fetchRuntimeTomlConfig, edits the [fusion] settings through
// the pure fusion-settings helpers, and writes back via saveRuntimeTomlConfig
// (POST /api/v1/runtime/config/raw → Runtime.save_config_text validates +
// atomically persists + reloads). The backend is the validation SSOT: an
// out-of-range min_answered is rejected on save and surfaced as an error here.
// The panel also blocks malformed local form state before POST so invalid UI
// input is not sent as a fabricated numeric value.
import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { fetchRuntimeTomlConfig, saveRuntimeTomlConfig } from '../api/dashboard'
import { errorToString } from '../lib/format-string'
import { applyFusionSettings, readFusionSettingsResult, type FusionSettings } from '../lib/fusion-settings'

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
  const maxConcurrentPanels = parseDraftPositiveInt('max_concurrent_panels', draft.maxConcurrentPanels)
  if (typeof maxConcurrentPanels === 'string') return maxConcurrentPanels
  const minAnswered = parseDraftPositiveInt('min_answered', draft.minAnswered)
  if (typeof minAnswered === 'string') return minAnswered
  return {
    enabled: draft.enabled,
    defaultPreset: draft.defaultPreset,
    maxConcurrentPanels,
    minAnswered,
  }
}

function parseIssueMessage(issues: readonly { key: string; message: string; token: string | undefined }[]): string {
  return issues.map(issue => `${issue.key}: ${issue.message}${issue.token === undefined ? '' : ` (${issue.token})`}`).join('; ')
}

export function FusionSettingsPanel() {
  const [source, setSource] = useState<string | null>(null)
  const [draft, setDraft] = useState<FusionSettingsDraft | null>(null)
  const [state, setState] = useState<EditorState>('loading')
  const [error, setError] = useState('')

  useEffect(() => {
    let active = true
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
    if (state === 'saved' || state === 'error') setState('idle')
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
      if (!cfg.ok) {
        // Backend validation rejected the write (e.g. min_answered out of range).
        setError('백엔드 검증 거부 (예: min_answered 범위). 변경이 저장되지 않았습니다.')
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
      setState('saved')
    } catch (err) {
      setError(errorToString(err))
      setState('error')
    }
  }

  const str = (e: Event) => (e.target as HTMLInputElement).value
  const checked = (e: Event) => (e.target as HTMLInputElement).checked

  return html`
    <div class="set-fusion-editor" data-testid="fusion-settings-editor">
      <label class="set-line">
        <span>Fusion 심의 활성 (enabled)</span>
        <input type="checkbox" checked=${draft.enabled} onChange=${(e: Event) => patch({ enabled: checked(e) })} />
      </label>
      <label class="set-line">
        <span>기본 프리셋 (default_preset)</span>
        <input type="text" value=${draft.defaultPreset} onInput=${(e: Event) => patch({ defaultPreset: str(e) })} />
      </label>
      <label class="set-line">
        <span>동시 패널 수 (max_concurrent_panels)</span>
        <input type="number" min="1" step="1" data-testid="fusion-max-concurrent-panels" value=${draft.maxConcurrentPanels}
          onInput=${(e: Event) => patch({ maxConcurrentPanels: str(e) })} />
      </label>
      <label class="set-line">
        <span>최소 응답 패널 (${draft.defaultPreset || '프리셋'} min_answered)</span>
        <input type="number" min="1" step="1" data-testid="fusion-min-answered" value=${draft.minAnswered}
          onInput=${(e: Event) => patch({ minAnswered: str(e) })} />
      </label>
      <div class="set-line">
        <button type="button" data-testid="fusion-settings-save" onClick=${onSave} disabled=${state === 'saving'}>
          ${state === 'saving' ? '저장 중…' : '저장'}
        </button>
        ${state === 'saved' && html`<span class="set-ok" data-testid="fusion-settings-saved">저장됨 (reload 완료)</span>`}
        ${state === 'error' && html`<span class="set-err" data-testid="fusion-settings-error">${error}</span>`}
      </div>
    </div>
  `
}
