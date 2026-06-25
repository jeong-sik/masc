// Writable Fusion settings editor (RFC-0273 §3.2 deferred Settings editor).
//
// Self-contained so it does NOT touch the read-only prototype widgets in
// settings-surface (their steppers are hardcoded `disabled`). Loads the live
// runtime.toml via fetchRuntimeTomlConfig, edits the [fusion] settings through
// the pure fusion-settings helpers, and writes back via saveRuntimeTomlConfig
// (POST /api/v1/runtime/config/raw → Runtime.save_config_text validates +
// atomically persists + reloads). The backend is the validation SSOT: an
// out-of-range min_answered is rejected on save and surfaced as an error here,
// never silently coerced.
import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { fetchRuntimeTomlConfig, saveRuntimeTomlConfig } from '../api/dashboard'
import { errorToString } from '../lib/format-string'
import { applyFusionSettings, readFusionSettings, type FusionSettings } from '../lib/fusion-settings'

type EditorState = 'loading' | 'idle' | 'saving' | 'saved' | 'error'

export function FusionSettingsPanel() {
  const [source, setSource] = useState<string | null>(null)
  const [values, setValues] = useState<FusionSettings | null>(null)
  const [state, setState] = useState<EditorState>('loading')
  const [error, setError] = useState('')

  useEffect(() => {
    let active = true
    const load = async () => {
      try {
        const cfg = await fetchRuntimeTomlConfig()
        if (!active) return
        setSource(cfg.source_text)
        setValues(readFusionSettings(cfg.source_text))
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

  if (state === 'loading' || values === null || source === null) {
    return html`<div class="set-hint" data-testid="fusion-settings-loading">설정을 불러오는 중…</div>`
  }

  const patch = (next: Partial<FusionSettings>) => setValues({ ...values, ...next })

  const onSave = async () => {
    if (source === null) return
    setState('saving')
    setError('')
    try {
      const cfg = await saveRuntimeTomlConfig(applyFusionSettings(source, values))
      if (!cfg.ok) {
        // Backend validation rejected the write (e.g. min_answered out of range).
        setError('백엔드 검증 거부 (예: min_answered 범위). 변경이 저장되지 않았습니다.')
        setState('error')
        return
      }
      setSource(cfg.source_text)
      setValues(readFusionSettings(cfg.source_text))
      setState('saved')
    } catch (err) {
      setError(errorToString(err))
      setState('error')
    }
  }

  const num = (e: Event) => Number((e.target as HTMLInputElement).value)
  const str = (e: Event) => (e.target as HTMLInputElement).value
  const checked = (e: Event) => (e.target as HTMLInputElement).checked

  return html`
    <div class="set-fusion-editor" data-testid="fusion-settings-editor">
      <label class="set-line">
        <span>Fusion 심의 활성 (enabled)</span>
        <input type="checkbox" checked=${values.enabled} onChange=${(e: Event) => patch({ enabled: checked(e) })} />
      </label>
      <label class="set-line">
        <span>기본 프리셋 (default_preset)</span>
        <input type="text" value=${values.defaultPreset} onInput=${(e: Event) => patch({ defaultPreset: str(e) })} />
      </label>
      <label class="set-line">
        <span>동시 패널 수 (max_concurrent_panels)</span>
        <input type="number" min="1" max="8" value=${values.maxConcurrentPanels}
          onInput=${(e: Event) => patch({ maxConcurrentPanels: num(e) })} />
      </label>
      <label class="set-line">
        <span>시간당 budget (per_hour_budget)</span>
        <input type="number" min="1" max="100" value=${values.perHourBudget}
          onInput=${(e: Event) => patch({ perHourBudget: num(e) })} />
      </label>
      <label class="set-line">
        <span>최소 응답 패널 (${values.defaultPreset || '프리셋'} min_answered)</span>
        <input type="number" min="1" value=${values.minAnswered}
          onInput=${(e: Event) => patch({ minAnswered: num(e) })} />
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
