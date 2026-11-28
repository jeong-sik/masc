/**
 * One preset, named rather than counted (`GET /api/v1/presets/show`).
 *
 * - Each prompt override the preset holds is compared with the text in force
 *   now (the prompt catalog the Prompts view already read). A restore sets
 *   the overrides exactly, so an override in force now that the preset does
 *   not hold is listed as one the restore clears. Until the catalog is read
 *   it says it cannot tell what the restore clears.
 * - Keeper instructions, runtime assignments and exact-output lanes are listed
 *   as the preset would write them. A lane setting the preset did not record
 *   keeps its current value on restore; a recorded `null` removes it.
 * - Restore and delete ask once more inline before sending. Restore names the
 *   `_autosave` preset it overwrites, and says what restoring `_autosave`
 *   does not undo (`Prompt_preset.restore`): keeper instructions and lanes
 *   are written only for what that preset holds. It also names the Prompts
 *   view's unsaved drafts, which outlast the restore and would overwrite what
 *   it set if saved. Delete says it cannot be undone.
 * - A restore sets the runtime assignments to the preset's list exactly
 *   (`runtime_text_with`), so the assignments section says a keeper missing
 *   from it loses its assignment.
 */

import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { createTwoFilesPatch } from 'diff'
import { apiGet, resourceCache, sessionEpoch } from '../../core'
import { UnifiedDiffView } from '../../components/common/unified-diff'
import { Chip } from './prompt-chip'
import { DefaultPromptsLine } from './preset-restore-report'
import { noteStyle } from './prompt-styles'
import { AUTOSAVE_PRESET, decodePresetShow, type PresetShow, type PresetSnapshot } from './presets-wire'
import type { PromptCatalog } from './prompts-wire'

export const presetShowCacheKey = (name: string) => `runtime:preset:${name}`

export function loadPresetShow(name: string, reason: 'mount' | 'manual') {
  return resourceCache.fetch<PresetShow>(
    presetShowCacheKey(name),
    (signal) => apiGet<PresetShow>(`/api/v1/presets/show?name=${encodeURIComponent(name)}`, { signal, decode: decodePresetShow }),
    { ttlMs: 30_000, topics: ['presets'], reason },
  )
}

export interface PresetDetailProps {
  readonly name: string
  readonly catalog: PromptCatalog | null
  /** Prompts with a draft the Prompts view has not saved. */
  readonly promptDrafts: readonly string[]
  readonly canEdit: boolean
  readonly busy: boolean
  readonly onRestore: (name: string) => Promise<void>
  readonly onDelete: (name: string) => Promise<void>
}

type Pending = 'restore' | 'delete'

const preStyle = {
  margin: 0,
  padding: 'var(--sp-2)',
  background: 'var(--bg-0)',
  border: '1px solid var(--line-1)',
  borderRadius: 'var(--radius-sm)',
  fontSize: 'var(--fs-12)',
  whiteSpace: 'pre-wrap',
  overflowWrap: 'anywhere',
  maxHeight: '40vh',
  overflowY: 'auto',
} as const

function Section({ title, count, children }: { title: string; count: number; children: unknown }) {
  return html`
    <section class="wka-card" style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)' }}>
      <h4 style=${{ margin: 0, fontSize: 'var(--fs-13)' }}>${title} (${count})</h4>
      ${count === 0 ? html`<div class="dtable-absent">없어요.</div>` : children}
    </section>
  `
}

function Overrides({ preset, catalog }: { preset: PresetSnapshot; catalog: PromptCatalog | null }) {
  const held = new Set(preset.prompt_overrides.map(o => o.key))
  const cleared = catalog === null ? [] : catalog.prompts.filter(p => p.source === 'override' && !held.has(p.key))
  return html`
    <${Section} title="프롬프트 override" count=${preset.prompt_overrides.length}>
      ${preset.prompt_overrides.map(o => {
        const now = catalog?.prompts.find(p => p.key === o.key)
        const status = catalog === null
          ? html`<${Chip} tone="neutral">지금 텍스트를 아직 못 읽음</${Chip}>`
          : now === undefined
            ? html`<${Chip} tone="warn">지금 카탈로그에 없는 키</${Chip}>`
            : now.effective === o.value
              ? html`<${Chip} tone="ok">지금과 같음</${Chip}>`
              : html`<${Chip} tone="warn">지금과 다름</${Chip}>`
        return html`
          <details key=${o.key} data-testid="preset-override">
            <summary style=${{ cursor: 'pointer', display: 'flex', gap: 'var(--sp-1)', alignItems: 'center', flexWrap: 'wrap' }}>
              <span class="mono" style=${{ fontSize: 'var(--fs-12)' }}>${o.key}</span>
              <${Chip} tone="neutral">${o.bytes} bytes</${Chip}>
              ${status}
            </summary>
            ${now !== undefined && now.effective !== o.value
              ? html`<${UnifiedDiffView}
                  diffText=${createTwoFilesPatch(`지금 · ${o.key}`, `프리셋 · ${o.key}`, now.effective, o.value, undefined, undefined, { context: 3 })}
                  testId="preset-override-diff"
                />`
              : html`<pre class="mono" style=${preStyle}>${o.value}</pre>`}
          </details>
        `
      })}
    </${Section}>
    ${catalog === null && html`
      <div role="status" data-testid="preset-clears-unknown" style=${{ ...noteStyle, color: 'var(--warn-fg)' }}>
        지금 쓰는 override 를 아직 읽지 못해서, 복원하면 어떤 override 가 지워지는지 알 수 없어요.
      </div>
    `}
    ${cleared.length > 0 && html`
      <div role="status" data-testid="preset-clears" style=${{ ...noteStyle, color: 'var(--warn-fg)' }}>
        복원하면 지금 쓰는 override ${cleared.length}개를 지우고 파일 텍스트로 돌아가요: <span class="mono">${cleared.map(p => p.key).join(', ')}</span>
      </div>
    `}
  `
}

function laneSetting(value: number | boolean | null | undefined): string {
  if (value === undefined) return '지금 값 유지'
  if (value === null) return '지움'
  return String(value)
}

function Body({ show, catalog }: { show: PresetShow; catalog: PromptCatalog | null }) {
  const { preset } = show
  return html`
    <${Overrides} preset=${preset} catalog=${catalog} />
    <${Section} title="Keeper instructions · 다시 올릴 때 적용" count=${preset.instructions.length}>
      ${preset.instructions.map(i => html`
        <details key=${i.keeper_file}>
          <summary style=${{ cursor: 'pointer' }}><span class="mono" style=${{ fontSize: 'var(--fs-12)' }}>${i.keeper_file}</span> <span style=${noteStyle}>${i.bytes} bytes</span></summary>
          <pre class="mono" style=${preStyle}>${i.text}</pre>
        </details>
      `)}
    </${Section}>
    <${Section} title="Runtime 배정" count=${preset.assignments.length}>
      <div style=${noteStyle}>복원하면 runtime.toml 의 배정을 이 목록으로 맞춰요. 여기 없는 Keeper 의 배정은 지워요.</div>
      <div style=${{ display: 'grid', gridTemplateColumns: 'minmax(8rem, max-content) 1fr', gap: 'var(--sp-0) var(--sp-3)', fontSize: 'var(--fs-12)' }}>
        ${preset.assignments.map(a => html`<span key=${`k:${a.keeper}`} class="mono">${a.keeper}</span><span key=${`r:${a.keeper}`} class="mono" style=${{ overflowWrap: 'anywhere' }}>${a.runtime}</span>`)}
      </div>
    </${Section}>
    <${Section} title="Exact-output lane" count=${preset.lanes.length}>
      ${preset.lanes.map(l => html`
        <div key=${l.id} style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-0)', fontSize: 'var(--fs-12)' }}>
          <div style=${{ display: 'flex', gap: 'var(--sp-1)', alignItems: 'center', flexWrap: 'wrap' }}>
            <span class="mono">${l.id}</span>
            <${Chip} tone=${l.enabled ? 'ok' : 'neutral'}>${l.enabled ? '켜짐' : '꺼짐'}</${Chip}>
            ${!l.available && html`<${Chip} tone="warn" title="이 runtime 에 없는 lane 이라 복원해도 바꾸지 않아요">없는 lane</${Chip}>`}
          </div>
          <div class="mono" style=${{ ...noteStyle, overflowWrap: 'anywhere' }}>slots: ${l.slots.join(', ') || '—'} · cli: ${l.cli_slots.join(', ') || '—'}</div>
          <div style=${noteStyle}>max_output_tokens: ${laneSetting(l.max_output_tokens)} · thinking: ${laneSetting(l.thinking)}</div>
        </div>
      `)}
    </${Section}>
  `
}

function savedSettingsChip(show: PresetShow) {
  switch (show.saved_settings.status) {
    case 'matches':
      return html`<${Chip} tone="ok">지금 설정과 같음</${Chip}>`
    case 'differs':
      return html`<${Chip} tone="warn">지금 설정과 다름</${Chip}>`
    case 'unavailable':
      return html`<${Chip} tone="bad" title=${show.saved_settings.reason}>비교 못 함</${Chip}>`
  }
}

export function PresetDetail({ name, catalog, promptDrafts, canEdit, busy, onRestore, onDelete }: PresetDetailProps) {
  const epoch = sessionEpoch.value
  const obs = resourceCache.observe<PresetShow>(presetShowCacheKey(name)).value
  const [pending, setPending] = useState<Pending | null>(null)

  useEffect(() => {
    void loadPresetShow(name, 'mount')
  }, [name, epoch])

  const run = (action: Pending) => {
    if (busy) return
    setPending(null)
    void (action === 'restore' ? onRestore(name) : onDelete(name))
  }

  const show = obs.kind === 'value' ? obs.data : null
  const isAutosave = name === AUTOSAVE_PRESET
  return html`
    <div data-testid="preset-detail" style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)', minWidth: 0 }}>
      <div class="wka-card" style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)' }}>
        <div class="wka-h"><h3 class="mono" style=${{ overflowWrap: 'anywhere' }}>${name}</h3></div>
        ${show !== null && html`
          <div style=${{ fontSize: 'var(--fs-13)', color: 'var(--fg-2)' }}>${show.preset.description || '설명 없음'}</div>
          <div style=${{ display: 'flex', gap: 'var(--sp-1)', flexWrap: 'wrap', alignItems: 'center' }}>
            ${savedSettingsChip(show)}
            <${DefaultPromptsLine} defaults=${show.default_prompts} />
            <span style=${noteStyle}>${show.preset.created_at}</span>
          </div>
          <div class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)', overflowWrap: 'anywhere' }}>${show.directory}</div>
        `}
        ${obs.kind === 'failed' && html`<div role="alert" class="ap-error">프리셋을 읽지 못했어요: ${obs.error.message}</div>`}
        ${obs.kind === 'loading' && html`<div class="dtable-absent">프리셋 불러오는 중…</div>`}
        ${obs.kind === 'absent' && html`<div role="alert" class="ap-error" data-testid="preset-absent">이 프리셋을 읽지 못했어요${obs.reason === undefined ? '.' : `: ${obs.reason}`}</div>`}
        ${obs.kind === 'unreported' && html`<div role="alert" class="ap-error">서버가 이 프리셋을 알려 주지 않았어요${obs.reason === undefined ? '.' : `: ${obs.reason}`}</div>`}
        ${canEdit && html`
          <div style=${{ display: 'flex', gap: 'var(--sp-1)', flexWrap: 'wrap' }}>
            <button type="button" class="btn-primary" data-testid="preset-restore" disabled=${busy || show === null} onClick=${() => setPending('restore')}>
              이 프리셋으로 복원
            </button>
            <button type="button" class="btn-ghost ap-danger-btn" data-testid="preset-delete" disabled=${busy} onClick=${() => setPending('delete')}>
              삭제
            </button>
          </div>
        `}
        ${pending === 'restore' && html`
          <div class="ap-inline-panel" data-testid="preset-restore-confirm" role="alert">
            <span style=${noteStyle}>
              지금 상태를 <span class="mono">${AUTOSAVE_PRESET}</span> 에 저장하고(이전 <span class="mono">${AUTOSAVE_PRESET}</span> 는 덮어써요) <span class="mono">${name}</span> 을 적용해요.
              프롬프트 override 와 Runtime 배정은 이 프리셋대로 맞추고, Keeper instructions 는 각 Keeper 를 다시 올릴 때 적용돼요.
              ${isAutosave && html`<br />Keeper instructions 와 lane 은 이 프리셋에 있는 것만 다시 써요. 마지막 복원이 새로 준 instructions 와 새로 더한 lane 은 남아요.`}
              ${promptDrafts.length > 0 && html`
                <br /><span data-testid="preset-restore-drafts">「프롬프트」 화면에서 저장하지 않은 초안 ${promptDrafts.length}개는 그대로 남아요(<span class="mono">${promptDrafts.join(', ')}</span>). 복원한 뒤 그 초안을 저장하면 복원한 override 를 덮어써요.</span>
              `}
            </span>
            <div style=${{ display: 'flex', gap: 'var(--sp-1)' }}>
              <button type="button" class="btn-primary" data-testid="preset-restore-go" disabled=${busy} onClick=${() => void run('restore')}>복원</button>
              <button type="button" class="btn-ghost" disabled=${busy} onClick=${() => setPending(null)}>취소</button>
            </div>
          </div>
        `}
        ${pending === 'delete' && html`
          <div class="ap-inline-panel ap-inline-panel--err" data-testid="preset-delete-confirm" role="alert">
            <span style=${{ ...noteStyle, color: 'var(--err-fg)' }}><span class="mono">${name}</span> 프리셋 디렉터리를 지워요. 되돌릴 수 없어요.</span>
            <div style=${{ display: 'flex', gap: 'var(--sp-1)' }}>
              <button type="button" class="btn-primary ap-danger-solid" data-testid="preset-delete-go" disabled=${busy} onClick=${() => void run('delete')}>삭제</button>
              <button type="button" class="btn-ghost" disabled=${busy} onClick=${() => setPending(null)}>취소</button>
            </div>
          </div>
        `}
      </div>
      ${show !== null && html`<${Body} show=${show} catalog=${catalog} />`}
    </div>
  `
}
