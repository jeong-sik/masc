/**
 * Runtime L1 Tab: Prompts
 *
 * - Lists the prompt catalog (`GET /api/v1/prompts`). The prompts an operator
 *   writes whole (`primary`) are shown; the pieces the server fills into a
 *   larger text (`fragment`) join the list behind a switch. The Keeper world's
 *   value system (`keeper.worldview`) is one of the primary prompts, and the
 *   per-turn world frame is the `keeper.world.*` fragments.
 * - An override replaces the file text of one key (`POST /api/v1/prompts`
 *   `set`); clearing it puts the file text back (`clear`). Both are admin
 *   tools on the server, so the editor is shown only to an admin session.
 * - Overrides the server saved but does not apply (`held_back`) are listed
 *   with the server's reason above the list. Clearing one removes it from
 *   disk; the server's clear takes held-back entries too.
 * - A failed answer is read by `failureOutcome`. Transport decodes only a 2xx
 *   answer, so one that fails to decode is a change the server made: the
 *   operator is told the answer was unreadable, not that the change failed.
 *   With no answer, or a 5xx, the outcome is unknown and the operator is told
 *   so. Either way the catalog is read again; a refusal changed nothing.
 * - A write ends when the catalog read after it does, so the detail never
 *   shows the text a save just replaced. A later write's read replaces an
 *   earlier one in the cache; the earlier write then waits for the later
 *   read. What the operator is told says whether that read succeeded.
 * - Drafts and requests live in `prompt-edits.ts`, so they outlast the detail
 *   and the tab. An outcome is also told in a toast unless the detail of
 *   that prompt shows it: open in the edit view, with the catalog read.
 * - The second view lists prompt presets (`presets-panel.ts`), which snapshot
 *   the overrides together with keeper instructions and runtime routing. It
 *   reads the same catalog to compare a preset's overrides with the text in
 *   force.
 */

import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import { apiGet, apiMutate, authSession, resourceCache, sessionEpoch, type Observed } from '../../core'
import { MasterDetail } from '../../components/primitives/master-detail'
import { RefreshButton } from '../../components/primitives'
import { isAdminLockedForSession } from '../../routes/router'
import { pushShellToast } from '../../shell/shell-state'
import { Chip, SourceChip } from './prompt-chip'
import { PromptDetail } from './prompt-detail'
import {
  beginPromptWrite,
  finishPromptWrite,
  isPromptShown,
  promptEditsFor,
  setPromptDraft,
  writeEndText,
  type PromptWriteEnd,
} from './prompt-edits'
import { PresetFeedback, PresetsPanel } from './presets-panel'
import {
  decodeOverrideApplied,
  decodePromptCatalog,
  type CuratorRefresh,
  type OverrideApplied,
  type PromptCatalog,
  type PromptEntry,
  type PromptOverrideRequest,
} from './prompts-wire'
import type { WorkspaceViewProps } from './types'
import { failureOutcome } from './write-outcome'

export const PROMPT_CATALOG_CACHE_KEY = 'runtime:prompts'

type FetchReason = 'mount' | 'manual'

type Section = 'prompts' | 'presets'

const SECTIONS: readonly (readonly [Section, string])[] = [
  ['prompts', '프롬프트'],
  ['presets', '프리셋'],
]

function loadPromptCatalog(reason: FetchReason) {
  return resourceCache.fetch<PromptCatalog>(
    PROMPT_CATALOG_CACHE_KEY,
    (signal) => apiGet<PromptCatalog>('/api/v1/prompts', { signal, decode: decodePromptCatalog }),
    { ttlMs: 30_000, topics: ['prompts'], reason },
  )
}

function curatorRefreshNote(refresh: CuratorRefresh | null): string | null {
  if (refresh === null) return null
  switch (refresh.status) {
    case 'queued':
      return 'Workspace Memory 큐레이터가 새 텍스트로 다시 읽도록 대기열에 넣었어요.'
    case 'no_owner':
      return 'Workspace Memory 큐레이터를 맡은 Keeper 가 없어서 다시 읽기를 넣지 않았어요.'
    case 'unavailable':
      return `Workspace Memory 큐레이터 다시 읽기를 넣지 못했어요: ${refresh.detail}`
  }
}

function appliedToast(request: PromptOverrideRequest, applied: OverrideApplied): string {
  const head = request.action === 'set'
    ? `${applied.key} override 를 저장했어요.`
    : `${applied.key} override 를 지웠어요. 지금은 ${applied.source} 텍스트를 써요.`
  const curator = curatorRefreshNote(applied.curator_refresh)
  return curator === null ? head : `${head} ${curator}`
}

function matchesSearch(entry: PromptEntry, needle: string): boolean {
  if (needle === '') return true
  return entry.key.toLowerCase().includes(needle) || entry.description.toLowerCase().includes(needle)
}

const fieldStyle = {
  padding: 'var(--sp-1) var(--sp-2)',
  background: 'var(--input-bg)',
  border: '1px solid var(--input-border)',
  borderRadius: 'var(--radius-sm)',
} as const

export function PromptsTab(_props: WorkspaceViewProps) {
  const session = authSession.value
  const epoch = sessionEpoch.value
  const canEdit = !isAdminLockedForSession('admin', session)
  const catalogObs = resourceCache.observe<PromptCatalog>(PROMPT_CATALOG_CACHE_KEY).value
  const [search, setSearch] = useState('')
  const [category, setCategory] = useState('')
  const [withFragments, setWithFragments] = useState(false)
  const [onlyOverrides, setOnlyOverrides] = useState(false)
  const [selectedKey, setSelectedKey] = useState<string | null>(null)
  const { drafts, writes } = promptEditsFor(epoch)
  const [section, setSection] = useState<Section>('prompts')

  useEffect(() => {
    void loadPromptCatalog('mount')
  }, [epoch])


  const catalog = catalogObs.kind === 'value' ? catalogObs.data : null
  const categories = useMemo(
    () => (catalog === null ? [] : [...new Set(catalog.prompts.map(p => p.category))].sort()),
    [catalog],
  )
  const rows = useMemo(() => {
    if (catalog === null) return []
    const needle = search.trim().toLowerCase()
    return catalog.prompts.filter(p =>
      (withFragments || p.operator_surface === 'primary')
      && (category === '' || p.category === category)
      && (!onlyOverrides || p.source === 'override')
      && matchesSearch(p, needle))
  }, [catalog, search, category, withFragments, onlyOverrides])
  const selected = catalog?.prompts.find(p => p.key === selectedKey) ?? null

  const setDraft = (key: string, text: string | undefined) => setPromptDraft(epoch, key, text)

  const reread = async (): Promise<Observed<PromptCatalog>> => {
    resourceCache.invalidateTopic('prompts')
    const read = await loadPromptCatalog('manual')
    // A read that a later one replaced answers with the cached value at once;
    // `mount` joins the later read instead of starting another.
    return read.kind === 'value' && read.stale ? loadPromptCatalog('mount') : read
  }

  /** Resolves to `true` once the server applied the request and the catalog read after it ended. */
  const send = async (request: PromptOverrideRequest): Promise<boolean> => {
    const { key } = request
    if (!beginPromptWrite(epoch, key)) return false
    const res = await apiMutate<OverrideApplied>('POST', '/api/v1/prompts', request, { decode: decodeOverrideApplied })
    if (epoch !== sessionEpoch.peek()) return false
    const failure = res.ok ? null : failureOutcome(res.error.kind)
    // A refusal changed nothing; any other answer may have changed the text.
    const read = failure === 'refused' ? null : await reread()
    if (epoch !== sessionEpoch.peek()) return false
    const readNote = read === null ? '' : read.kind === 'value' ? ' 목록을 다시 읽었어요.' : ' 목록도 다시 읽지 못했어요.'
    if (res.ok) {
      finishPromptWrite(epoch, key, undefined, request.action === 'set')
      pushShellToast(`${appliedToast(request, res.value)}${read?.kind === 'value' ? '' : readNote}`, 'success')
      return true
    }
    const end: PromptWriteEnd | undefined = (() => {
      switch (failureOutcome(res.error.kind)) {
        case 'applied':
          return undefined
        case 'refused':
          return { kind: 'refused', action: request.action, why: res.error.message }
        case 'unknown':
          return { kind: 'unknown', why: res.error.message }
      }
    })()
    finishPromptWrite(epoch, key, end, end === undefined && request.action === 'set')
    if (end === undefined) {
      pushShellToast(`${key}: 서버가 요청을 받았지만 답을 읽지 못했어요 (${res.error.message}).${readNote}`, 'warning')
      return true
    }
    // Without the catalog there is no detail to show the note.
    if (!isPromptShown(key) || (read !== null && read.kind !== 'value')) {
      pushShellToast(`${key}: ${writeEndText(end)}${readNote}`, end.kind === 'refused' ? 'error' : 'warning')
    }
    return false
  }

  const master = html`
    <div class="wka-card" style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)', height: '100%', minHeight: 0 }}>
      <div class="wka-h">
        <h3>프롬프트 (${catalog === null ? '—' : `${rows.length} / ${catalog.prompts.length}`})</h3>
        <${RefreshButton} onRefresh=${() => loadPromptCatalog('manual')} />
      </div>
      <div style=${{ display: 'flex', gap: 'var(--sp-2)', flexWrap: 'wrap', alignItems: 'center' }}>
        <input
          type="search"
          aria-label="프롬프트 검색"
          placeholder="키 / 설명 검색…"
          value=${search}
          onInput=${(e: Event) => setSearch((e.currentTarget as HTMLInputElement).value)}
          style=${{ ...fieldStyle, flex: '1 1 12rem', minWidth: 0 }}
        />
        <select aria-label="카테고리" value=${category} onChange=${(e: Event) => setCategory((e.currentTarget as HTMLSelectElement).value)} style=${fieldStyle}>
          <option value="">모든 카테고리</option>
          ${categories.map(c => html`<option key=${c} value=${c}>${c}</option>`)}
        </select>
      </div>
      <div style=${{ display: 'flex', gap: 'var(--sp-3)', flexWrap: 'wrap', fontSize: 'var(--fs-12)', color: 'var(--fg-2)' }}>
        <label><input type="checkbox" checked=${withFragments} onChange=${() => setWithFragments(v => !v)} /> 조각까지 보기</label>
        <label><input type="checkbox" checked=${onlyOverrides} onChange=${() => setOnlyOverrides(v => !v)} /> override 만</label>
      </div>
      ${catalogObs.kind === 'failed' && html`<div role="alert" class="ap-error">프롬프트 목록을 읽지 못했어요: ${catalogObs.error.message}</div>`}
      ${catalog !== null && catalog.held_back.length > 0 && html`
        <div role="alert" class="ap-error" data-testid="prompts-held-back">
          <div>저장했지만 서버가 쓰지 않는 override ${catalog.held_back.length}건</div>
          ${catalog.held_back.map(h => html`
            <div key=${h.key} style=${{ display: 'flex', gap: 'var(--sp-2)', alignItems: 'center', flexWrap: 'wrap' }}>
              <span class="mono" style=${{ fontSize: 'var(--fs-11)', overflowWrap: 'anywhere' }}>${h.key} (${h.bytes} bytes): ${h.reason}</span>
              ${canEdit && html`
                <button type="button" class="btn-ghost btn-compact" data-testid="prompts-held-back-clear" disabled=${writes.get(h.key)?.kind === 'sending'} onClick=${() => void send({ action: 'clear', key: h.key })}>
                  지우기
                </button>
              `}
            </div>
          `)}
        </div>
      `}
      <div role="list" aria-label="프롬프트 목록" style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)', overflowY: 'auto', minHeight: 0 }}>
        ${catalog === null
          ? html`<div class="dtable-absent">${catalogObs.kind === 'loading' ? '프롬프트 불러오는 중…' : '프롬프트 목록이 없어요.'}</div>`
          : rows.length === 0
            ? html`<div class="dtable-absent">조건에 맞는 프롬프트가 없어요.</div>`
            : rows.map(p => html`
              <div key=${p.key} role="listitem">
                <button
                  type="button"
                  class="btn-ghost"
                  aria-current=${p.key === selectedKey ? 'true' : undefined}
                  onClick=${() => setSelectedKey(p.key)}
                  style=${{
                    display: 'flex',
                    flexDirection: 'column',
                    alignItems: 'stretch',
                    gap: 'var(--sp-0)',
                    width: '100%',
                    textAlign: 'left',
                    background: p.key === selectedKey ? 'var(--bg-4)' : undefined,
                  }}
                >
                  <span style=${{ display: 'flex', gap: 'var(--sp-1)', alignItems: 'center', flexWrap: 'wrap' }}>
                    <span class="mono" style=${{ fontSize: 'var(--fs-12)', overflowWrap: 'anywhere' }}>${p.key}</span>
                    ${p.source !== 'file' && html`<${SourceChip} source=${p.source} />`}
                    ${p.override_default_moved && html`<${Chip} tone="warn">기본 텍스트 바뀜</${Chip}>`}
                    ${p.authoring_issues.length > 0 && html`<${Chip} tone="bad">작성 오류</${Chip}>`}
                    ${drafts.has(p.key) && html`<${Chip} tone="info">저장 안 함</${Chip}>`}
                  </span>
                  <span style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)', overflowWrap: 'anywhere' }}>${p.description}</span>
                </button>
              </div>
            `)}
      </div>
    </div>
  `

  const detail = selected === null
    ? null
    : html`<${PromptDetail}
        key=${selected.key}
        entry=${selected}
        canEdit=${canEdit}
        draft=${drafts.get(selected.key)}
        onDraft=${setDraft}
        write=${writes.get(selected.key)}
        onSend=${send}
      />`

  return html`
    <div class="ov ov--split" data-testid="runtime-prompts-tab">
      <header class="ov-head" style=${{ flexShrink: 0 }}>
        <div>
          <span class="ov-eyebrow">5 RUNTIME · PROMPTS</span>
          <h1>공유 프롬프트 · World · 프리셋</h1>
        </div>
        <div class="ap-viewseg" role="group" aria-label="프롬프트 화면 선택">
          ${SECTIONS.map(([id, label]) => html`
            <button key=${id} type="button" data-section=${id} aria-pressed=${section === id} class=${`ap-viewbtn ${section === id ? 'on' : ''}`} onClick=${() => setSection(id)}>
              ${label}
            </button>
          `)}
        </div>
      </header>
      ${!canEdit && html`
        <div class="wka-card" role="status" data-testid="prompts-admin-locked" style=${{ flexShrink: 0, fontSize: 'var(--fs-13)', color: 'var(--fg-2)' }}>
          프롬프트와 프리셋은 읽을 수만 있어요. override 저장·지우기와 프리셋 저장·복원·삭제는 관리자 세션에서 할 수 있어요.
        </div>
      `}
      <${PresetFeedback} />
      <div style=${{ flex: '1 1 0%', minHeight: 0 }}>
        ${section === 'presets'
          ? html`<${PresetsPanel}
              canEdit=${canEdit}
              catalog=${catalog}
              onPromptsChanged=${() => { resourceCache.invalidateTopic('prompts'); void loadPromptCatalog('manual') }}
            />`
          : html`<${MasterDetail}
              masterLabel="프롬프트 목록"
              detailLabel="프롬프트"
              master=${master}
              detail=${detail}
              hasSelection=${selected !== null}
              selectionKey=${selectedKey}
              emptyDetail=${html`<div class="wka-card dtable-absent">목록에서 프롬프트를 고르면 지금 쓰는 텍스트와 편집기가 열려요.</div>`}
            />`}
      </div>
    </div>
  `
}
