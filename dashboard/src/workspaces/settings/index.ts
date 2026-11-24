/**
 * Settings Workspace — Schema-Driven 2-Pane Tree + Property Inspector
 *
 * - Fetches GET /api/v1/config/schema?target=runtime (V2Envelope per #36).
 * - Renders TUI's 7 Categories (General & UI, Providers & Models, Routing & Failover,
 *   Keepers & Companies, Sandbox & SSH, Voice & Integrations, Board, Memory & Candle),
 *   provenance pills (default|global|project|keeper|env), secret redaction, inline descriptions.
 * - Embeds AppearancePanel under General & UI.
 * - Safe CAS Dry-Run Diff Flow:
 *   Local staging -> Preview Diff (POST /api/v1/config/patch dry_run:true + expected_sha256)
 *   -> Unified diff + reload_scope honesty notice -> explicit Apply Patch (dry_run:false)
 *   showing resulting snapshot_id + explicit 409 conflict_cas reload handling.
 * - Export World Config (GET /api/v1/world/configuration/export).
 */

import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import {
  apiGet,
  resourceCache,
} from '../../core'
import {
  fetchConfigSchemaApi,
  postConfigPatchApi,
  type ConfigFieldSpec as ConfigField,
  type ConfigPatchChange,
  type ConfigPatchResult,
  type ConfigSchemaData,
} from '../../api/config-schema'
import type { WorkspaceViewProps } from '../types'
import { AppearancePanel } from './appearance-panel'
import {
  CANONICAL_SETTINGS_CATEGORIES,
  organizeCategoriesIntoSeven,
  patchOpForField,
  reloadScopeNotice,
  type WorldConfigExportResponse,
} from './types'

export {
  CANONICAL_SETTINGS_CATEGORIES,
  organizeCategoriesIntoSeven,
  patchOpForField,
  reloadScopeNotice,
}
export type { WorkspaceInspectPayload } from '../types'
export type { ConfigSchemaData } from '../../api/config-schema'

type FieldDraft = ConfigPatchChange | { readonly op: 'invalid_number'; readonly value: string }

interface ConfigPreview {
  readonly target: string
  readonly sha256: string
  readonly changes: readonly ConfigPatchChange[]
  readonly result: ConfigPatchResult
}

function provenanceStyle(prov: string) {
  const p = prov.toLowerCase()
  if (p === 'env') return { background: 'var(--warn-soft)', border: '1px solid var(--warn-border)', color: 'var(--warn-fg)' }
  if (p === 'keeper') return { background: 'var(--brass-soft)', border: '1px solid var(--brass-border)', color: 'var(--brass-1)' }
  if (p === 'project' || p === 'global') return { background: 'var(--info-soft)', border: '1px solid var(--info-border)', color: 'var(--info-fg)' }
  return { background: 'var(--idle-soft)', border: '1px solid var(--idle-border)', color: 'var(--fg-3)' }
}

function formatFieldDisplayValue(field: ConfigField): string {
  if (field.secret) return field.current_value ? '••••••••' : '없음'
  if (field.current_value === null || field.current_value === undefined) return ''
  if (Array.isArray(field.current_value)) return field.current_value.join('\n')
  if (typeof field.current_value === 'object') return JSON.stringify(field.current_value)
  return String(field.current_value)
}

function renderUnifiedDiff(diffText: string) {
  const lines = diffText.split('\n')
  return html`
    <pre
      class="mono"
      data-testid="settings-unified-diff"
      style=${{
        margin: 0,
        padding: 'var(--sp-3)',
        background: 'var(--bg-0)',
        border: '1px solid var(--line-1)',
        borderRadius: 'var(--radius-sm)',
        fontSize: 'var(--fs-11)',
        overflowX: 'auto',
        lineHeight: 1.45,
      }}
    >
      ${lines.map((line, idx) => {
        const isAdd = line.startsWith('+') && !line.startsWith('+++')
        const isDel = line.startsWith('-') && !line.startsWith('---')
        const isHunk = line.startsWith('@@')
        const style = isAdd
          ? { display: 'block', background: 'var(--ok-soft)', color: 'var(--ok-fg)' }
          : isDel
            ? { display: 'block', background: 'var(--err-soft)', color: 'var(--err-fg)' }
            : isHunk
              ? { display: 'block', color: 'var(--info-fg)' }
              : { display: 'block', color: 'var(--fg-2)' }
        return html`<span key=${idx} style=${style}>${line}</span>`
      })}
    </pre>
  `
}

function resolveInitialSearchKey(): string {
  if (typeof window === 'undefined') return ''
  return new URLSearchParams(window.location.search).get('key') ?? ''
}

export function SettingsWorkspace(props: WorkspaceViewProps) {
  const target = props.entityId ? `keeper:${props.entityId}` : 'runtime'
  const schemaCacheKey = `settings:schema:${target}`
  const schemaObs = resourceCache.observe<ConfigSchemaData>(schemaCacheKey).value

  const [activeCategoryId, setActiveCategoryId] = useState<string>('general')
  const [searchQuery, setSearchQuery] = useState<string>(() => resolveInitialSearchKey())
  const [staged, setStaged] = useState<Readonly<Record<string, FieldDraft>>>({})
  const [preview, setPreview] = useState<ConfigPreview | null>(null)
  const [applyResult, setApplyResult] = useState<ConfigPatchResult | null>(null)
  const [casConflict, setCasConflict] = useState<string | null>(null)
  const [errorBanner, setErrorBanner] = useState<string | null>(null)
  const [busy, setBusy] = useState<'preview' | 'apply' | 'export' | null>(null)

  const loadSchema = (reason: 'mount' | 'manual' = 'mount') => {
    void resourceCache.fetch<ConfigSchemaData>(
      schemaCacheKey,
      (signal) => fetchConfigSchemaApi(target, signal),
      { ttlMs: 15_000, topics: ['config'], reason },
    )
  }

  useEffect(() => {
    loadSchema('mount')
  }, [target])

  const schemaData = schemaObs.kind === 'value' ? schemaObs.data : null

  const categories = useMemo(
    () => organizeCategoriesIntoSeven(schemaData?.categories ?? []),
    [schemaData],
  )

  const drafts = useMemo(() => Object.values(staged), [staged])
  const hasInvalidNumber = drafts.some((draft) => draft.op === 'invalid_number')
  const stagedList = useMemo(() => drafts.filter((draft) => draft.op !== 'invalid_number'), [drafts])
  const stagedCount = stagedList.length
  const dryRunResult = preview && !hasInvalidNumber && preview.changes === stagedList
    && preview.target === schemaData?.target && preview.sha256 === schemaData.file_sha256
    ? preview.result : null

  const activeCategory = categories.find((c) => c.id === activeCategoryId) ?? categories[0] ?? null

  const visibleFields = useMemo(() => {
    const q = searchQuery.trim().toLowerCase()
    if (q) {
      const matched: ConfigField[] = []
      for (const cat of categories) {
        for (const f of cat.fields) {
          const hay = `${f.full_key} ${f.label ?? ''} ${f.description}`.toLowerCase()
          if (hay.includes(q)) matched.push(f)
        }
      }
      return matched
    }
    return activeCategory?.fields ?? []
  }, [categories, activeCategory, searchQuery])

  const stageFieldChange = (field: ConfigField, nextValue: unknown, remove = false) => {
    const draft: FieldDraft = patchOpForField(field, nextValue, remove)
      ?? { op: 'invalid_number', value: String(nextValue ?? '') }
    setStaged((prev) => ({ ...prev, [field.full_key]: draft }))
    setPreview(null)
    setCasConflict(null)
    setErrorBanner(null)
  }

  const unstageField = (fullKey: string) => {
    setStaged((prev) => {
      const next = { ...prev }
      delete next[fullKey]
      return next
    })
    setPreview(null)
  }

  const handlePreviewDiff = async () => {
    if (!schemaData || hasInvalidNumber || stagedList.length === 0 || busy) return
    setBusy('preview')
    setPreview(null)
    setErrorBanner(null)
    setCasConflict(null)
    setApplyResult(null)

    const res = await postConfigPatchApi({
      target: schemaData.target,
      expectedSha256: schemaData.file_sha256,
      dryRun: true,
      changes: stagedList,
    })
    setBusy(null)

    if (!res.ok) {
      if (res.error.kind === 'conflict_cas') {
        setCasConflict(res.error.message || '설정 파일이 외부에서 변경되었습니다 (409 conflict_cas).')
      } else {
        setErrorBanner(`Dry-Run 미리보기 실패: ${res.error.message}`)
      }
      return
    }
    setPreview({
      target: schemaData.target,
      sha256: schemaData.file_sha256,
      changes: stagedList,
      result: res.value,
    })
  }

  const handleApplyPatch = async () => {
    if (!preview || !dryRunResult?.changed || busy) return
    setBusy('apply')
    setErrorBanner(null)
    setCasConflict(null)

    const res = await postConfigPatchApi({
      target: preview.target,
      expectedSha256: preview.sha256,
      dryRun: false,
      changes: preview.changes,
    })
    setBusy(null)

    if (!res.ok) {
      if (res.error.kind === 'conflict_cas') {
        setCasConflict(res.error.message || 'CAS 충돌 (409): 설정 파일 SHA-256이 변경되었습니다.')
      } else {
        setErrorBanner(`패치 적용 실패: ${res.error.message}`)
      }
      return
    }

    setApplyResult(res.value)
    setPreview(null)
    setStaged({})
    loadSchema('manual')
  }

  const handleReloadAfterConflict = () => {
    setCasConflict(null)
    setPreview(null)
    setErrorBanner(null)
    loadSchema('manual')
  }

  const handleExportWorldConfig = async () => {
    setBusy('export')
    setErrorBanner(null)
    const res = await apiGet<WorldConfigExportResponse>('/api/v1/world/configuration/export')
    setBusy(null)
    if (!res.ok) {
      setErrorBanner(`월드 설정 내보내기 실패: ${res.error.message}`)
      return
    }
    const payload = res.value
    const jsonText = JSON.stringify(payload, null, 2)
    props.onInspect({
      title: 'World Configuration Export',
      subtitle: `${payload.scope ?? 'authored_configuration_documents'} · 경고 ${payload.lock_warnings?.length ?? 0}건`,
      kind: 'world_config_export',
      data: payload,
      render: () => html`
        <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)' }}>
          <div style=${{ display: 'flex', gap: 'var(--sp-2)' }}>
            <button
              type="button"
              class="btn-primary"
              onClick=${() => {
                try {
                  const blob = new Blob([jsonText], { type: 'application/json' })
                  const url = URL.createObjectURL(blob)
                  const a = document.createElement('a')
                  a.href = url
                  a.download = `masc-world-config-${new Date().toISOString().slice(0, 10)}.json`
                  a.click()
                  URL.revokeObjectURL(url)
                } catch { /* non-browser test env */ }
              }}
            >
              JSON 다운로드
            </button>
          </div>
          <pre class="mono" style=${{ margin: 0, fontSize: 'var(--fs-11)', overflowX: 'auto', whiteSpace: 'pre-wrap', background: 'var(--bg-0)', padding: 'var(--sp-3)', borderRadius: 'var(--radius-sm)' }}>
            ${jsonText}
          </pre>
        </div>
      `,
    })
  }

  const renderFieldRow = (field: ConfigField) => {
    const stagedOp = staged[field.full_key]
    const isModified = stagedOp !== undefined
    const isRemoved = stagedOp?.op === 'remove'
    const invalidNumber = stagedOp?.op === 'invalid_number'
    const currentDisplay = isModified
      ? (isRemoved
          ? '(키 제거 예정)'
          : Array.isArray(stagedOp.value)
            ? stagedOp.value.join('\n')
            : String(stagedOp.value ?? ''))
      : formatFieldDisplayValue(field)

    const fieldType = field.type.toLowerCase()
    const isBool = fieldType === 'bool' || fieldType === 'boolean'
    const isInt = fieldType === 'int' || fieldType === 'integer'
    const isNum = isInt || fieldType === 'float' || fieldType === 'number'
    const isArray = fieldType === 'string_array' || fieldType === 'string_list'
    const hasEnum = Array.isArray(field.enum_values) && field.enum_values.length > 0

    return html`
      <article
        key=${field.full_key}
        data-field-key=${field.full_key}
        style=${{
          padding: 'var(--sp-3)',
          borderRadius: 'var(--radius-sm)',
          border: `1px solid ${isModified ? 'var(--brass-border)' : 'var(--line-1)'}`,
          background: isModified ? 'var(--brass-soft)' : 'var(--bg-2)',
          display: 'flex',
          flexDirection: 'column',
          gap: 'var(--sp-2)',
          minWidth: 0,
        }}
      >
        <div style=${{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', gap: 'var(--sp-2)', flexWrap: 'wrap' }}>
          <div style=${{ minWidth: 0 }}>
            <div style=${{ fontWeight: 600, fontSize: 'var(--fs-13)', color: 'var(--fg-1)' }}>
              ${field.label || field.key}
            </div>
            <div class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>${field.full_key}</div>
          </div>

          <div style=${{ display: 'flex', alignItems: 'center', gap: 'var(--sp-1)', flexWrap: 'wrap' }}>
            <span
              class="mono"
              style=${{ ...provenanceStyle(field.provenance), padding: 'var(--sp-0) var(--sp-1)', borderRadius: 'var(--radius-pill)', fontSize: 'var(--fs-10)' }}
            >
              ${field.provenance}
            </span>
            <span
              class="mono"
              style=${{
                padding: 'var(--sp-0) var(--sp-1)',
                borderRadius: 'var(--radius-pill)',
                fontSize: 'var(--fs-10)',
                background: 'var(--bg-3)',
                color: field.reload_scope === 'restart_required' ? 'var(--warn-fg)' : 'var(--fg-2)',
              }}
            >
              ${field.reload_scope}
            </span>
            ${field.secret && html`
              <span class="mono" style=${{ padding: 'var(--sp-0) var(--sp-1)', borderRadius: 'var(--radius-pill)', fontSize: 'var(--fs-10)', background: 'var(--err-soft)', color: 'var(--err-fg)' }}>
                secret
              </span>
            `}
            ${!field.writable && html`
              <span class="mono" style=${{ padding: 'var(--sp-0) var(--sp-1)', borderRadius: 'var(--radius-pill)', fontSize: 'var(--fs-10)', background: 'var(--idle-soft)', color: 'var(--fg-3)' }}>
                read-only
              </span>
            `}
          </div>
        </div>

        ${field.description && html`
          <p style=${{ margin: 0, fontSize: 'var(--fs-12)', color: 'var(--fg-2)' }}>${field.description}</p>
        `}

        <div style=${{ display: 'flex', alignItems: 'center', gap: 'var(--sp-2)', flexWrap: 'wrap' }}>
          ${isBool
            ? html`
                <label style=${{ display: 'inline-flex', alignItems: 'center', gap: 'var(--sp-1)', fontSize: 'var(--fs-12)' }}>
                  <input
                    type="checkbox"
                    aria-label=${field.full_key}
                    disabled=${!field.writable || busy === 'apply'}
                    checked=${isModified ? Boolean(stagedOp.value) : Boolean(field.current_value)}
                    onChange=${(e: Event) => stageFieldChange(field, (e.target as HTMLInputElement).checked)}
                  />
                  <span class="mono">${(isModified ? Boolean(stagedOp.value) : Boolean(field.current_value)) ? 'true' : 'false'}</span>
                </label>
              `
            : hasEnum
              ? html`
                  <select
                    aria-label=${field.full_key}
                    disabled=${!field.writable || busy === 'apply'}
                    value=${currentDisplay}
                    onChange=${(e: Event) => stageFieldChange(field, (e.target as HTMLSelectElement).value)}
                    style=${{ padding: 'var(--sp-1) var(--sp-2)', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
                  >
                    ${field.enum_values!.map((opt) => html`<option key=${opt} value=${opt}>${opt}</option>`)}
                  </select>
                `
              : isArray
                ? html`
                    <textarea
                      rows=${3}
                      aria-label=${field.full_key}
                      disabled=${!field.writable || busy === 'apply'}
                      value=${currentDisplay}
                      onInput=${(e: Event) => stageFieldChange(field, (e.target as HTMLTextAreaElement).value)}
                      class="mono"
                      style=${{ flex: 1, minWidth: '220px', padding: 'var(--sp-1) var(--sp-2)', fontSize: 'var(--fs-12)', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
                    />
                  `
                : html`
                    <input
                      type=${field.secret ? 'password' : isNum ? 'number' : 'text'}
                      aria-label=${field.full_key}
                      disabled=${!field.writable || busy === 'apply'}
                      aria-invalid=${invalidNumber}
                      step=${isNum ? (isInt ? 1 : 'any') : undefined}
                      placeholder=${field.secret ? '•••••••• (새 시크릿 입력 시 덮어씀)' : String(field.default_value ?? '없음')}
                      value=${field.secret && !isModified ? '' : currentDisplay}
                      onInput=${(e: Event) => stageFieldChange(field, (e.target as HTMLInputElement).value)}
                      class="mono tnum"
                      style=${{ flex: 1, minWidth: '200px', padding: 'var(--sp-1) var(--sp-2)', fontSize: 'var(--fs-12)', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
                    />
                  `}

          ${invalidNumber && html`<span class="ap-error" role="alert">${isInt ? '정수를 입력하세요.' : '숫자를 입력하세요.'}</span>`}
          ${field.writable && field.table && html`
            <button
              type="button"
              class="btn-ghost"
              style=${{ padding: 'var(--sp-1) var(--sp-2)', fontSize: 'var(--fs-11)' }}
              disabled=${busy === 'apply'}
              onClick=${() => stageFieldChange(field, null, true)}
            >
              기본값 복원
            </button>
          `}
          ${isModified && html`
            <button
              type="button"
              class="btn-ghost"
              style=${{ padding: 'var(--sp-1) var(--sp-2)', fontSize: 'var(--fs-11)', color: 'var(--err-fg)' }}
              disabled=${busy === 'apply'}
              onClick=${() => unstageField(field.full_key)}
            >
              변경 취소
            </button>
          `}
        </div>
      </article>
    `
  }

  return html`
    <div class="ov" data-testid="settings-workspace">
      <header class="ov-head">
        <div>
          <span class="ov-eyebrow">SYSTEM · SCHEMA-DRIVEN SETTINGS</span>
          <h1>설정 트리 & CAS Dry-Run Diff 인스펙터</h1>
          <p class="ov-sub">
            대상: <span class="mono">${target}</span> · SHA-256: <span class="mono">${schemaData?.file_sha256 ? schemaData.file_sha256.slice(0, 12) : '없음'}</span>
          </p>
        </div>
        <div style=${{ display: 'flex', alignItems: 'center', gap: 'var(--sp-2)', flexWrap: 'wrap' }}>
          <input
            type="search"
            aria-label="설정 키 검색"
            placeholder="설정 키 / 설명 검색…"
            value=${searchQuery}
            onInput=${(e: Event) => setSearchQuery((e.target as HTMLInputElement).value)}
            style=${{ padding: 'var(--sp-1) var(--sp-2)', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)', minWidth: '200px' }}
          />
          <button
            type="button"
            class="btn-ghost"
            disabled=${busy === 'export'}
            onClick=${() => void handleExportWorldConfig()}
          >
            ${busy === 'export' ? '내보내는 중…' : 'Export World Config'}
          </button>
          <button
            type="button"
            class="btn-primary"
            disabled=${stagedCount === 0 || hasInvalidNumber || busy !== null || !schemaData}
            onClick=${() => void handlePreviewDiff()}
          >
            ${busy === 'preview' ? 'Diff 생성 중…' : `Preview Diff (${stagedCount})`}
          </button>
        </div>
      </header>

      ${errorBanner && html`<div class="ap-error" role="alert">${errorBanner}</div>`}

      <!-- 409 CAS Conflict Alert -->
      ${casConflict && html`
        <section class="ap-error" data-testid="settings-cas-conflict" role="alert" style=${{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 'var(--sp-3)', flexWrap: 'wrap' }}>
          <div>
            <strong>⚠ 409 CAS 충돌 (conflict_cas):</strong> ${casConflict}
          </div>
          <button type="button" class="btn-primary" onClick=${handleReloadAfterConflict}>
            최신 스키마 다시 불러오기
          </button>
        </section>
      `}

      <!-- Applied Patch Receipt -->
      ${applyResult && html`
        <section
          class="wka-card"
          data-testid="settings-apply-receipt"
          role="status"
          style=${{ borderColor: 'var(--ok-border)', background: 'var(--ok-soft)', display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)' }}
        >
          <div style=${{ fontWeight: 600, color: 'var(--ok-fg)' }}>
            ✓ 설정 패치 적용 완료 (${reloadScopeNotice(applyResult.reload_scope).label})
          </div>
          <div class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-1)' }}>
            snapshot_id: ${applyResult.snapshot_id ?? '없음'} · new_sha256: ${applyResult.new_sha256.slice(0, 16)}
          </div>
          <div style=${{ fontSize: 'var(--fs-12)', color: 'var(--fg-2)' }}>
            ${reloadScopeNotice(applyResult.reload_scope).detail}
          </div>
        </section>
      `}

      <!-- Dry-Run Diff Preview & Explicit Apply Gate -->
      ${dryRunResult && html`
        <section
          class="wka-card"
          data-testid="settings-dry-run-panel"
          style=${{ borderColor: 'var(--brass-border)', display: 'flex', flexDirection: 'column', gap: 'var(--sp-3)' }}
        >
          <div class="wka-h">
            <h3>Dry-Run Unified Diff 미리보기 (${stagedCount}건 변경)</h3>
            <div style=${{ display: 'flex', gap: 'var(--sp-2)' }}>
              <button type="button" class="btn-ghost" onClick=${() => setPreview(null)}>닫기</button>
              <button
                type="button"
                class="btn-primary"
                disabled=${busy !== null || !dryRunResult.changed}
                onClick=${() => void handleApplyPatch()}
              >
                ${busy === 'apply' ? '적용 중…' : 'Apply Patch'}
              </button>
            </div>
          </div>

          ${(() => {
            const notice = reloadScopeNotice(dryRunResult.reload_scope)
            const toneStyle = notice.tone === 'warn'
              ? { borderColor: 'var(--warn-border)', background: 'var(--warn-soft)', color: 'var(--warn-fg)' }
              : notice.tone === 'info'
                ? { borderColor: 'var(--info-border)', background: 'var(--info-soft)', color: 'var(--info-fg)' }
                : { borderColor: 'var(--ok-border)', background: 'var(--ok-soft)', color: 'var(--ok-fg)' }
            return html`
              <div data-testid="settings-reload-scope-notice" style=${{ padding: 'var(--sp-2) var(--sp-3)', borderRadius: 'var(--radius-sm)', border: '1px solid', ...toneStyle, fontSize: 'var(--fs-12)' }}>
                <strong>${notice.label}:</strong> ${notice.detail}
              </div>
            `
          })()}

          ${dryRunResult.validation_warnings.length > 0 && html`
            <div class="ap-error sev-warn">
              ${dryRunResult.validation_warnings.map((w, i) => html`<div key=${i}>⚠ ${w}</div>`)}
            </div>
          `}

          ${dryRunResult.unified_diff
            ? renderUnifiedDiff(dryRunResult.unified_diff)
            : html`<div class="dtable-absent">변경된 Diff 라인이 없습니다.</div>`}
        </section>
      `}

      <!-- 2-Pane Category Tree + Property Inspector -->
      <div class="set-shell" style=${{ padding: 0 }}>
        <nav class="set-card-b" aria-label="설정 카테고리 (7개)" style=${{ padding: 'var(--sp-2)', display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)', alignSelf: 'start' }}>
          ${categories.map((cat) => {
            const isSel = !searchQuery.trim() && activeCategory?.id === cat.id
            const catStagedCount = cat.fields.filter((f) => f.full_key in staged).length
            return html`
              <button
                key=${cat.id}
                type="button"
                aria-current=${isSel ? 'page' : undefined}
                onClick=${() => {
                  setSearchQuery('')
                  setActiveCategoryId(cat.id)
                }}
                style=${{
                  display: 'flex',
                  justifyContent: 'space-between',
                  alignItems: 'center',
                  gap: 'var(--sp-2)',
                  padding: 'var(--sp-2) var(--sp-3)',
                  borderRadius: 'var(--radius-sm)',
                  border: 'none',
                  background: isSel ? 'var(--bg-4)' : 'transparent',
                  color: isSel ? 'var(--fg-1)' : 'var(--fg-2)',
                  fontWeight: isSel ? 600 : 400,
                  textAlign: 'left',
                  cursor: 'pointer',
                  fontSize: 'var(--fs-12)',
                }}
              >
                <span>${cat.title}</span>
                <span class="mono tnum" style=${{ fontSize: 'var(--fs-11)', color: catStagedCount > 0 ? 'var(--brass-1)' : 'var(--fg-3)' }}>
                  ${catStagedCount > 0 ? `*${catStagedCount} / ` : ''}${cat.field_count}
                </span>
              </button>
            `
          })}

          ${stagedCount > 0 && html`
            <button
              type="button"
              class="btn-ghost"
              style=${{ marginTop: 'var(--sp-2)', color: 'var(--err-fg)' }}
              onClick=${() => {
                setStaged({})
                setPreview(null)
              }}
            >
              스테이징 모두 취소 (${stagedCount})
            </button>
          `}
        </nav>

        <section class="set-card-b" aria-label="속성 인스펙터" style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-3)', minWidth: 0 }}>
          ${(activeCategory?.id === 'general' && !searchQuery.trim()) && html`<${AppearancePanel} />`}

          <div class="wka-h">
            <h3>
              ${searchQuery.trim()
                ? `검색 결과: "${searchQuery.trim()}" (${visibleFields.length})`
                : `${activeCategory?.title ?? 'Settings'} (${visibleFields.length})`}
            </h3>
            <button type="button" class="btn-ghost" onClick=${() => loadSchema('manual')}>스키마 새로고침</button>
          </div>

          ${schemaObs.kind === 'loading' && html`<div class="dtable-absent">설정 스키마 불러오는 중…</div>`}
          ${schemaObs.kind === 'failed' && html`
            <div class="ap-error" role="alert">
              ${schemaObs.error.kind === 'forbidden'
                ? '관리자(Admin) 권한이 필요한 설정 스키마입니다 (HTTP 403).'
                : `설정 스키마 조회 실패: ${schemaObs.error.message}`}
            </div>
          `}

          ${schemaObs.kind === 'value' && visibleFields.length === 0 && html`
            <div class="dtable-absent">이 카테고리에 표시할 설정 필드가 없습니다.</div>
          `}

          ${visibleFields.length > 0 && html`
            <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)' }}>
              ${visibleFields.map(renderFieldRow)}
            </div>
          `}
        </section>
      </div>
    </div>
  `
}

export default SettingsWorkspace
