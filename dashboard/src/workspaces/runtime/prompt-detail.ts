/**
 * One prompt of the catalog: the text in force, how it differs from the file,
 * and an editor for its override.
 *
 * The draft and the request in flight are the parent's (`draft`, `write`),
 * keyed by prompt, because picking another prompt unmounts this component.
 * Coming back keeps what was typed, keeps the editor read-only while that
 * prompt's request is in flight, and shows the reason the server refused it.
 * Saving sends the draft as the override and, once the server applies it, the
 * parent drops the draft. Clearing drops the override so the file text is in
 * force again; a draft the operator has not saved stays. The server checks
 * the template variables and answers with the text now in force, or with the
 * reason it refused.
 */

import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import { createTwoFilesPatch } from 'diff'
import { UnifiedDiffView } from '../../components/common/unified-diff'
import { Chip, SourceChip } from './prompt-chip'
import type { PromptEntry, PromptOverrideRequest } from './prompts-wire'

type DetailView = 'text' | 'compare' | 'edit'

/** A request for one prompt: in flight, or refused with the server's reason. */
export type PromptWrite =
  | { readonly kind: 'sending' }
  | { readonly kind: 'refused'; readonly why: string }

export interface PromptDetailProps {
  readonly entry: PromptEntry
  readonly canEdit: boolean
  /** What was typed for this key and not saved, `undefined` for nothing. */
  readonly draft: string | undefined
  readonly onDraft: (key: string, text: string | undefined) => void
  /** This prompt's request in flight or last refusal, `undefined` for neither. */
  readonly write: PromptWrite | undefined
  /** Sends the request; resolves to `true` when the server applied it. */
  readonly onSend: (request: PromptOverrideRequest) => Promise<boolean>
}

const preStyle = {
  margin: 0,
  padding: 'var(--sp-3)',
  background: 'var(--bg-0)',
  border: '1px solid var(--line-1)',
  borderRadius: 'var(--radius-sm)',
  fontSize: 'var(--fs-12)',
  lineHeight: 1.5,
  whiteSpace: 'pre-wrap',
  overflowWrap: 'anywhere',
  maxHeight: '60vh',
  overflowY: 'auto',
} as const

function overridePatch(entry: PromptEntry): string | null {
  if (entry.override_value === null) return null
  return createTwoFilesPatch(
    `file · ${entry.key}`,
    `override · ${entry.key}`,
    entry.file_value ?? '',
    entry.override_value,
    undefined,
    undefined,
    { context: 3 },
  )
}

export function PromptDetail({ entry, canEdit, draft, onDraft, write, onSend }: PromptDetailProps) {
  const [chosenView, setView] = useState<DetailView>(
    (draft !== undefined || write !== undefined) && canEdit ? 'edit' : 'text',
  )
  const busy = write?.kind === 'sending'
  const refusal = write?.kind === 'refused' ? write.why : null
  const patch = overridePatch(entry)
  // A view the entry can no longer show (the override is gone, or the session
  // lost admin) falls back to the text in force.
  const view: DetailView =
    (chosenView === 'compare' && patch === null) || (chosenView === 'edit' && !canEdit) ? 'text' : chosenView
  const text = draft ?? entry.effective
  const dirty = draft !== undefined && draft !== entry.effective

  const send = async (request: PromptOverrideRequest) => {
    if (!(await onSend(request))) return
    switch (request.action) {
      case 'set':
        setView('text')
        return
      case 'clear':
        if (draft === undefined) setView('text')
        return
    }
  }

  const views: readonly (readonly [DetailView, string])[] = [
    ['text', '지금 쓰는 텍스트'],
    ...(patch !== null ? [['compare', '파일과 비교'] as const] : []),
    ...(canEdit ? [['edit', dirty ? '편집 · 저장 안 함' : '편집'] as const] : []),
  ]

  return html`
    <div class="wka-card" data-testid="prompt-detail" style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)', minWidth: 0 }}>
      <div class="wka-h">
        <h3 class="mono" style=${{ overflowWrap: 'anywhere' }}>${entry.key}</h3>
      </div>
      <div style=${{ fontSize: 'var(--fs-13)', color: 'var(--fg-2)' }}>${entry.description}</div>
      <div style=${{ display: 'flex', gap: 'var(--sp-1)', flexWrap: 'wrap', alignItems: 'center' }}>
        <${SourceChip} source=${entry.source} />
        <${Chip} tone="neutral">${entry.category}</${Chip}>
        <${Chip} tone="neutral" title=${entry.operator_surface === 'primary' ? '운영자가 통째로 쓰는 프롬프트' : '서버가 더 큰 텍스트에 끼워 넣는 조각'}>
          ${entry.operator_surface === 'primary' ? '운영자용' : '조각'}
        </${Chip}>
        <${Chip} tone="neutral">${entry.char_count} bytes</${Chip}>
        ${entry.template_variables.map(name => html`<${Chip} key=${name} tone="info" title="서버가 채우는 자리">{{${name}}}</${Chip}>`)}
      </div>
      ${entry.file_path !== null && html`
        <div class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)', overflowWrap: 'anywhere' }}>${entry.file_path}</div>
      `}
      ${entry.override_default_moved && html`
        <div role="status" class="wka-card" style=${{ borderColor: 'var(--warn-border)', background: 'var(--warn-soft)', color: 'var(--warn-fg)', fontSize: 'var(--fs-12)' }}>
          이 override 를 저장한 뒤 파일의 기본 텍스트나 자리 이름이 바뀌었어요. override 는 그대로 쓰이고 있어요. 「파일과 비교」에서 확인하세요.
        </div>
      `}
      ${entry.authoring_issues.map(issue => html`
        <div key=${`${issue.source_file}:${issue.value}`} role="alert" class="ap-error">
          ${issue.source_file} 의 ${issue.field} 값 「${issue.value}」을 읽지 못했어요.
        </div>
      `)}

      <div class="ap-viewseg" role="group" aria-label="프롬프트 보기 선택" style=${{ alignSelf: 'flex-start', flexWrap: 'wrap' }}>
        ${views.map(([id, label]) => html`
          <button key=${id} type="button" data-view=${id} aria-pressed=${view === id} class=${`ap-viewbtn ${view === id ? 'on' : ''}`} onClick=${() => setView(id)}>
            ${label}
          </button>
        `)}
      </div>

      ${view === 'text' && html`<pre class="mono" data-testid="prompt-effective" style=${preStyle}>${entry.effective}</pre>`}
      ${view === 'compare' && patch !== null && html`<${UnifiedDiffView} diffText=${patch} testId="prompt-override-diff" />`}
      ${view === 'edit' && html`
        <textarea
          aria-label=${`${entry.key} override 편집`}
          aria-busy=${busy}
          class="mono"
          rows=${18}
          value=${text}
          readOnly=${busy}
          spellcheck=${false}
          onInput=${(e: Event) => onDraft(entry.key, (e.currentTarget as HTMLTextAreaElement).value)}
          style=${{ ...preStyle, width: '100%', resize: 'vertical', maxHeight: undefined, minHeight: '16rem' }}
        />
        ${refusal !== null && html`<div role="alert" class="ap-error" data-testid="prompt-refusal">저장하지 못했어요: ${refusal}</div>`}
        <div style=${{ display: 'flex', gap: 'var(--sp-1)', flexWrap: 'wrap' }}>
          <button type="button" class="btn-primary" data-testid="prompt-save" disabled=${busy || !dirty} onClick=${() => void send({ action: 'set', key: entry.key, value: text })}>
            override 저장
          </button>
          <button type="button" class="btn-ghost" data-testid="prompt-discard" disabled=${busy || draft === undefined} onClick=${() => onDraft(entry.key, undefined)}>
            고친 것 버리기
          </button>
          ${entry.source === 'override' && html`
            <button type="button" class="btn-ghost" data-testid="prompt-clear" disabled=${busy} onClick=${() => void send({ action: 'clear', key: entry.key })}>
              override 지우고 파일 텍스트 쓰기
            </button>
          `}
        </div>
      `}
    </div>
  `
}
