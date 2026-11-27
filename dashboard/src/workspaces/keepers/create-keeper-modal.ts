import { html } from 'htm/preact'
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { useFocusScope } from '../../../design-system/headless-preact/use-focus-scope'
import { MarkdownContent } from '../../components/common/markdown-renderer'
import {
  fetchConfigSchemaApi,
  patchOpForField,
  postConfigPatchApi,
  type ConfigPatchChange,
  type ConfigPatchResult,
  type ConfigSchemaData,
} from '../../api/config-schema'

export interface CreateKeeperModalProps {
  readonly onClose: () => void
  readonly onCreated: (name: string) => void
}

export function CreateKeeperModal(props: CreateKeeperModalProps) {
  const [schema, setSchema] = useState<ConfigSchemaData | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [keeperName, setKeeperName] = useState('')
  const [draftValues, setDraftValues] = useState<Record<string, string>>({})
  const [preview, setPreview] = useState<ConfigPatchResult | null>(null)
  const [busy, setBusy] = useState(false)
  const busyRef = useRef(false)
  const mountedRef = useRef(true)
  const modalRef = useRef<HTMLDivElement>(null)
  const nameInputRef = useRef<HTMLInputElement>(null)
  const onCloseRef = useRef(props.onClose)
  onCloseRef.current = props.onClose

  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
    }
  }, [])

  useFocusScope({
    containerRef: modalRef,
    active: true,
    initialFocus: () => nameInputRef.current,
  })

  useEffect(() => {
    queueMicrotask(() => nameInputRef.current?.focus())
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.defaultPrevented || event.isComposing || event.keyCode === 229) return
      if (event.key === 'Escape') {
        if (typeof document !== 'undefined') {
          const otherModalOpen = Array.from(
            document.querySelectorAll('[role="dialog"][aria-modal="true"]'),
          ).some((el) => el !== modalRef.current)
          if (otherModalOpen) return
        }
        event.preventDefault()
        event.stopPropagation()
        onCloseRef.current()
      }
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [])

  useEffect(() => {
    let active = true
    void fetchConfigSchemaApi('keeper_create').then((res) => {
      if (!active) return
      setLoading(false)
      if (!res.ok) {
        setError(res.error.message)
        return
      }
      setSchema(res.value)
    })
    return () => { active = false }
  }, [])

  const editableFields = useMemo(() => {
    if (!schema) return []
    return schema.categories
      .flatMap((c) => c.fields)
      .filter((f) => f.writable && !f.secret)
      .slice(0, 12)
  }, [schema])

  const buildChanges = (): ConfigPatchChange[] => {
    const changes: ConfigPatchChange[] = []
    for (const field of editableFields) {
      const raw = draftValues[field.full_key]
      if (raw === undefined || raw.trim() === '') continue
      const change = patchOpForField(field, raw.trim(), false, ',')
      if (change) changes.push(change)
    }
    return changes
  }

  const runPatch = async (dryRun: boolean) => {
    if (busyRef.current) return
    const trimmed = keeperName.trim()
    if (!trimmed) {
      setError('Keeper 이름(소문자/숫자/하이픈)을 입력하세요.')
      return
    }
    busyRef.current = true
    setBusy(true)
    setError(null)
    try {
      const res = await postConfigPatchApi({
        target: 'keeper_create',
        keeperName: trimmed,
        dryRun,
        changes: buildChanges(),
      })
      if (!mountedRef.current) return
      if (!res.ok) {
        setError(res.error.message)
        return
      }
      setPreview(res.value)
      if (!dryRun && res.value.applied) {
        props.onCreated(trimmed)
      }
    } catch (err) {
      if (mountedRef.current) {
        setError(err instanceof Error ? err.message : String(err))
      }
    } finally {
      busyRef.current = false
      if (mountedRef.current) setBusy(false)
    }
  }

  return html`
    <div
      ref=${modalRef}
      class="kp-modal-backdrop"
      role="dialog"
      aria-modal="true"
      aria-label="새 Keeper 생성"
      onClick=${(e: MouseEvent) => {
        if (e.target === e.currentTarget) props.onClose()
      }}
    >
      <div class="kp-modal">
        <div class="kp-card-head">
          <h3>+ Create Keeper (target=keeper_create)</h3>
          <button type="button" class="btn-ghost" onClick=${props.onClose}>닫기</button>
        </div>

        ${error && html`<div class="ap-error" role="alert">${error}</div>`}

        <label class="kp-kv-box">
          <span class="kp-kv-k">Keeper Name (필수)</span>
          <input
            ref=${nameInputRef}
            type="text"
            class="kp-input"
            placeholder="e.g. code-reviewer-alpha"
            value=${keeperName}
            onInput=${(e: Event) => setKeeperName((e.currentTarget as HTMLInputElement).value)}
          />
        </label>

        ${loading
          ? html`<div class="kp-empty">keeper_create 스키마 불러오는 중…</div>`
          : html`
              <div>
                ${editableFields.map((field) => html`
                  <div key=${field.full_key} class="kp-field-row">
                    <div>
                      <div class="kp-roster-name">${field.label ?? field.full_key}</div>
                      ${field.description
                        ? html`<${MarkdownContent} class="kp-roster-sub" text=${field.description} />`
                        : html`<div class="kp-roster-sub">${field.type}</div>`}
                    </div>
                    ${field.enum_values && field.enum_values.length > 0
                      ? html`
                          <select
                            class="kp-input"
                            value=${draftValues[field.full_key] ?? ''}
                            onChange=${(e: Event) => setDraftValues({
                              ...draftValues,
                              [field.full_key]: (e.currentTarget as HTMLSelectElement).value,
                            })}
                          >
                            <option value="">(기본값: ${String(field.default_value ?? '없음')})</option>
                            ${field.enum_values.map((v) => html`<option key=${v} value=${v}>${v}</option>`)}
                          </select>
                        `
                      : html`
                          <input
                            type="text"
                            class="kp-input"
                            placeholder=${String(field.default_value ?? '')}
                            value=${draftValues[field.full_key] ?? ''}
                            onInput=${(e: Event) => setDraftValues({
                              ...draftValues,
                              [field.full_key]: (e.currentTarget as HTMLInputElement).value,
                            })}
                          />
                        `}
                  </div>
                `)}
              </div>
            `}

        ${preview && html`
          <div>
            <div class="kp-pill-row">
              <span class="kp-pill" data-tone="info">reload: ${preview.reload_scope}</span>
              ${preview.validation_warnings.map((w, i) => html`
                <span key=${i} class="kp-pill" data-tone="warn">⚠ ${w}</span>
              `)}
            </div>
            <pre class="kp-diff">${preview.unified_diff || '(변경 diff 없음)'}</pre>
          </div>
        `}

        <div class="kp-lifecycle-bar">
          <button type="button" class="btn-ghost" disabled=${busy} onClick=${() => void runPatch(true)}>
            Dry-Run Diff 미리보기
          </button>
          <button type="button" class="btn-primary" disabled=${busy} onClick=${() => void runPatch(false)}>
            Keeper 생성 적용
          </button>
        </div>
      </div>
    </div>
  `
}
