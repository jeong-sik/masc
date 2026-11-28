/**
 * Prompt presets: list, read, save, restore and delete (#32777).
 *
 * - The list counts what each preset holds; picking one reads it whole
 *   (`preset-detail.ts`). Directories the server could not read are listed
 *   with its reason and can be deleted; the server's delete does not load a
 *   preset first.
 * - Saving snapshots the live state under a new name (`/create`). When the
 *   name is taken the server answers 409, and the operator chooses to
 *   replace that preset (`POST /api/v1/presets`) or not.
 * - A restore changes prompt overrides and the `_autosave` preset, so both
 *   the preset list and the prompt catalog are read again afterwards.
 * - Transport decodes only a 2xx answer, so an answer that fails to decode is
 *   a change the server made: the lists are read again and the operator is
 *   told the answer was unreadable, not that the change failed. When no
 *   answer came back (network, timeout, a 5xx), the outcome is unknown: the
 *   lists are read again and the operator is told so.
 * - After any write the preset on screen is read again, so the detail never
 *   shows what a save or restore just replaced.
 */

import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import { apiGet, apiMutate, resourceCache, sessionEpoch, type ApiError, type ApiErrorKind } from '../../core'
import type { Result } from '../../lib/result'
import { MasterDetail } from '../../components/primitives/master-detail'
import { RefreshButton } from '../../components/primitives'
import { pushShellToast } from '../../shell/shell-state'
import { Chip } from './prompt-chip'
import { loadPresetShow, PresetDetail } from './preset-detail'
import { RestoreReportView } from './preset-restore-report'
import {
  AUTOSAVE_PRESET,
  decodePresetDeleted,
  decodePresetListing,
  decodePresetRestored,
  decodePresetSaved,
  isValidPresetName,
  type PresetDeleted,
  type PresetListing,
  type PresetRestored,
  type PresetSaved,
  type RestoreReport,
} from './presets-wire'
import type { PromptCatalog } from './prompts-wire'

export const PRESET_LISTING_CACHE_KEY = 'runtime:presets'

function loadPresetListing(reason: 'mount' | 'manual') {
  return resourceCache.fetch<PresetListing>(
    PRESET_LISTING_CACHE_KEY,
    (signal) => apiGet<PresetListing>('/api/v1/presets', { signal, decode: decodePresetListing }),
    { ttlMs: 30_000, topics: ['presets'], reason },
  )
}

/** How a write ended: done with its answer, done with an answer that did not decode, refused, or not known. */
type Settled<T> =
  | { readonly kind: 'done'; readonly value: T }
  | { readonly kind: 'unreadable' }
  | { readonly kind: 'refused'; readonly why: string }
  | { readonly kind: 'unknown'; readonly why: string }

/** What a failed write says about the server's state. */
function failureOutcome(kind: ApiErrorKind): 'applied' | 'refused' | 'unknown' {
  switch (kind) {
    // Transport decodes only a 2xx answer.
    case 'decode':
      return 'applied'
    // The server answered that it did not do it.
    case 'unauthorized':
    case 'forbidden':
    case 'csrf_rejected':
    case 'not_found':
    case 'conflict_cas':
    case 'validation':
      return 'refused'
    // No answer, or a 5xx that a proxy may have written: the server may have done it.
    case 'server':
    case 'network':
    case 'timeout':
    case 'aborted':
    case 'epoch_stale':
      return 'unknown'
  }
}

export interface PresetsPanelProps {
  readonly canEdit: boolean
  readonly catalog: PromptCatalog | null
  /** Reads the prompt catalog again after a restore changed overrides. */
  readonly onPromptsChanged: () => void
}

const fieldStyle = {
  padding: 'var(--sp-1) var(--sp-2)',
  background: 'var(--input-bg)',
  border: '1px solid var(--input-border)',
  borderRadius: 'var(--radius-sm)',
  minWidth: 0,
} as const

export function PresetsPanel({ canEdit, catalog, onPromptsChanged }: PresetsPanelProps) {
  const epoch = sessionEpoch.value
  const obs = resourceCache.observe<PresetListing>(PRESET_LISTING_CACHE_KEY).value
  const [selected, setSelected] = useState<string | null>(null)
  const [name, setName] = useState('')
  const [description, setDescription] = useState('')
  const [saving, setSaving] = useState(false)
  const [taken, setTaken] = useState<string | null>(null)
  const [saveRefusal, setSaveRefusal] = useState<string | null>(null)
  const [report, setReport] = useState<RestoreReport | null>(null)
  const [unreadableDelete, setUnreadableDelete] = useState<string | null>(null)
  const [unreadableBusy, setUnreadableBusy] = useState(false)
  // The selection when an answer arrives, not when the request left.
  const selectedRef = useRef<string | null>(selected)
  selectedRef.current = selected

  useEffect(() => {
    void loadPresetListing('mount')
  }, [epoch])

  const listing = obs.kind === 'value' ? obs.data : null
  const trimmed = name.trim()
  const nameOk = isValidPresetName(trimmed)

  const reread = (alsoPrompts: boolean) => {
    resourceCache.invalidateTopic('presets')
    void loadPresetListing('manual')
    const shown = selectedRef.current
    if (shown !== null) void loadPresetShow(shown, 'manual')
    if (alsoPrompts) onPromptsChanged()
  }

  const settle = <T,>(res: Result<T, ApiError>, what: string, alsoPrompts: boolean): Settled<T> => {
    if (res.ok) {
      reread(alsoPrompts)
      return { kind: 'done', value: res.value }
    }
    switch (failureOutcome(res.error.kind)) {
      case 'refused':
        return { kind: 'refused', why: `하지 못했어요: ${res.error.message}` }
      case 'applied':
        reread(alsoPrompts)
        pushShellToast(`${what}: 서버가 요청을 받았지만 답을 읽지 못했어요 (${res.error.message}). 목록을 다시 읽어요.`, 'warning')
        return { kind: 'unreadable' }
      case 'unknown':
        reread(alsoPrompts)
        return { kind: 'unknown', why: `결과를 알 수 없어요 (${res.error.message}). 목록을 다시 읽었어요.` }
    }
  }

  const save = async (replace: boolean) => {
    setSaving(true)
    setSaveRefusal(null)
    const body = { name: trimmed, description }
    const res = await apiMutate<PresetSaved>('POST', replace ? '/api/v1/presets' : '/api/v1/presets/create', body, { decode: decodePresetSaved })
    setSaving(false)
    if (!res.ok && res.error.kind === 'conflict_cas') {
      setTaken(trimmed)
      return
    }
    const out = settle(res, `${trimmed} 저장`, false)
    if (out.kind === 'refused' || out.kind === 'unknown') {
      setSaveRefusal(out.why)
      return
    }
    if (out.kind === 'done') pushShellToast(`${out.value.preset.name} 프리셋에 지금 상태를 ${replace ? '덮어썼어요' : '저장했어요'}.`, 'success')
    setTaken(null)
    setName('')
    setDescription('')
    setSelected(trimmed)
    void loadPresetShow(trimmed, 'manual')
  }

  const restore = async (target: string): Promise<string | null> => {
    const res = await apiMutate<PresetRestored>('POST', '/api/v1/presets/restore', { name: target }, { decode: decodePresetRestored })
    const out = settle(res, `${target} 복원`, true)
    switch (out.kind) {
      case 'refused':
      case 'unknown':
        return out.why
      case 'unreadable':
        return null
      case 'done':
        setReport(out.value.report)
        pushShellToast(`${target} 을 복원했어요. 이전 상태는 ${out.value.report.autosave} 에 있어요.`, 'success')
        return null
    }
  }

  const remove = async (target: string): Promise<string | null> => {
    const res = await apiMutate<PresetDeleted>('POST', '/api/v1/presets/delete', { name: target }, { decode: decodePresetDeleted })
    const out = settle(res, `${target} 삭제`, false)
    if (out.kind === 'refused' || out.kind === 'unknown') return out.why
    if (out.kind === 'done') pushShellToast(`${out.value.deleted} 프리셋을 지웠어요.`, 'success')
    setSelected(current => (current === target ? null : current))
    return null
  }

  const removeUnreadable = async (target: string) => {
    setUnreadableBusy(true)
    const why = await remove(target)
    setUnreadableBusy(false)
    setUnreadableDelete(null)
    if (why !== null) pushShellToast(`${target}: ${why}`, 'error')
  }

  const master = html`
    <div class="wka-card" style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)', height: '100%', minHeight: 0 }}>
      <div class="wka-h">
        <h3>프리셋 (${listing === null ? '—' : listing.presets.length})</h3>
        <${RefreshButton} onRefresh=${() => loadPresetListing('manual')} />
      </div>
      <div style=${{ fontSize: 'var(--fs-12)', color: 'var(--fg-2)' }}>
        프롬프트 override, Keeper instructions, Runtime 배정과 exact-output lane 을 한 이름으로 저장하고 되돌려요.
      </div>
      ${canEdit && html`
        <form
          data-testid="preset-save-form"
          style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)' }}
          onSubmit=${(e: Event) => { e.preventDefault(); if (nameOk) void save(false) }}
        >
          <div style=${{ display: 'flex', gap: 'var(--sp-1)', flexWrap: 'wrap' }}>
            <input aria-label="새 프리셋 이름" placeholder="이름 (A-Z a-z 0-9 . _ -)" value=${name} disabled=${saving}
              onInput=${(e: Event) => { setName((e.currentTarget as HTMLInputElement).value); setTaken(null) }}
              style=${{ ...fieldStyle, flex: '1 1 8rem' }} />
            <input aria-label="새 프리셋 설명" placeholder="설명 (선택)" value=${description} disabled=${saving}
              onInput=${(e: Event) => setDescription((e.currentTarget as HTMLInputElement).value)}
              style=${{ ...fieldStyle, flex: '2 1 12rem' }} />
            <button type="submit" class="btn-primary" data-testid="preset-save" disabled=${saving || !nameOk}>지금 상태 저장</button>
          </div>
          ${trimmed !== '' && !nameOk && html`<div style=${{ fontSize: 'var(--fs-11)', color: 'var(--warn-fg)' }}>이름에는 영문, 숫자, 점, 밑줄, 하이픈만 쓸 수 있어요.</div>`}
          ${taken !== null && html`
            <div class="ap-inline-panel ap-inline-panel--err" role="alert" data-testid="preset-taken">
              <span style=${{ fontSize: 'var(--fs-12)', color: 'var(--err-fg)' }}><span class="mono">${taken}</span> 프리셋이 이미 있어요. 지금 상태로 덮어쓸까요?</span>
              <div style=${{ display: 'flex', gap: 'var(--sp-1)' }}>
                <button type="button" class="btn-primary ap-danger-solid" data-testid="preset-replace" disabled=${saving} onClick=${() => void save(true)}>덮어쓰기</button>
                <button type="button" class="btn-ghost" disabled=${saving} onClick=${() => setTaken(null)}>취소</button>
              </div>
            </div>
          `}
          ${saveRefusal !== null && html`<div role="alert" class="ap-error" data-testid="preset-save-refusal">${saveRefusal}</div>`}
        </form>
      `}
      ${obs.kind === 'failed' && html`<div role="alert" class="ap-error">프리셋 목록을 읽지 못했어요: ${obs.error.message}</div>`}
      ${listing !== null && listing.unreadable.length > 0 && html`
        <div role="alert" class="ap-error" data-testid="presets-unreadable">
          <div>읽지 못한 프리셋 ${listing.unreadable.length}개</div>
          ${listing.unreadable.map(u => html`
            <div key=${u.name} style=${{ display: 'flex', gap: 'var(--sp-2)', alignItems: 'center', flexWrap: 'wrap' }}>
              <span class="mono" style=${{ fontSize: 'var(--fs-11)', overflowWrap: 'anywhere' }}>${u.name}: ${u.reason}</span>
              ${canEdit && isValidPresetName(u.name) && (unreadableDelete === u.name
                ? html`
                  <button type="button" class="btn-primary btn-compact ap-danger-solid" data-testid="preset-unreadable-delete-go" disabled=${unreadableBusy} onClick=${() => void removeUnreadable(u.name)}>정말 삭제</button>
                  <button type="button" class="btn-ghost btn-compact" disabled=${unreadableBusy} onClick=${() => setUnreadableDelete(null)}>취소</button>
                `
                : html`<button type="button" class="btn-ghost btn-compact" data-testid="preset-unreadable-delete" disabled=${unreadableBusy} onClick=${() => setUnreadableDelete(u.name)}>삭제</button>`)}
            </div>
          `)}
        </div>
      `}
      <div role="list" aria-label="프리셋 목록" style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)', overflowY: 'auto', minHeight: 0 }}>
        ${listing === null
          ? html`<div class="dtable-absent">${obs.kind === 'loading' ? '프리셋 불러오는 중…' : '프리셋 목록이 없어요.'}</div>`
          : listing.presets.length === 0
            ? html`<div class="dtable-absent">저장한 프리셋이 없어요.</div>`
            : listing.presets.map(p => html`
              <div key=${p.name} role="listitem">
                <button type="button" class="btn-ghost" aria-current=${p.name === selected ? 'true' : undefined}
                  onClick=${() => { setSelected(p.name); setReport(null) }}
                  style=${{ display: 'flex', flexDirection: 'column', alignItems: 'stretch', gap: 'var(--sp-0)', width: '100%', textAlign: 'left', background: p.name === selected ? 'var(--bg-4)' : undefined }}>
                  <span style=${{ display: 'flex', gap: 'var(--sp-1)', alignItems: 'center', flexWrap: 'wrap' }}>
                    <span class="mono" style=${{ fontSize: 'var(--fs-12)', overflowWrap: 'anywhere' }}>${p.name}</span>
                    ${p.name === AUTOSAVE_PRESET && html`<${Chip} tone="info" title="복원은 그 직전 상태를 이 이름으로 저장해요">복원할 때마다 덮어씀</${Chip}>`}
                  </span>
                  <span style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)', overflowWrap: 'anywhere' }}>${p.description}</span>
                  <span style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>
                    override ${p.override_count} · Keeper ${p.keepers.length} · 배정 ${p.assignment_count} · lane ${p.lane_count} · ${p.created_at}
                  </span>
                </button>
              </div>
            `)}
      </div>
    </div>
  `

  const detail = selected === null
    ? null
    : html`
      <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)', minWidth: 0 }}>
        ${report !== null && report.restored === selected && html`<${RestoreReportView} report=${report} onDismiss=${() => setReport(null)} />`}
        <${PresetDetail} key=${selected} name=${selected} catalog=${catalog} canEdit=${canEdit} onRestore=${restore} onDelete=${remove} />
      </div>
    `

  return html`
    <${MasterDetail}
      masterLabel="프리셋 목록"
      detailLabel="프리셋"
      master=${master}
      detail=${detail}
      hasSelection=${selected !== null}
      selectionKey=${selected}
      emptyDetail=${html`<div class="wka-card dtable-absent">목록에서 프리셋을 고르면 그 프리셋이 바꿀 것을 모두 보여 줘요.</div>`}
    />
  `
}
