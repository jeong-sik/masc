import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import type { PromptSource } from './prompts-wire'

export type ChipTone = 'neutral' | 'info' | 'ok' | 'warn' | 'bad' | 'brass'

function toneStyle(tone: ChipTone): Record<string, string> {
  switch (tone) {
    case 'neutral':
      return { background: 'var(--bg-2)', borderColor: 'var(--line-2)', color: 'var(--fg-2)' }
    case 'info':
      return { background: 'var(--info-soft)', borderColor: 'var(--info-border)', color: 'var(--info-fg)' }
    case 'ok':
      return { background: 'var(--ok-soft)', borderColor: 'var(--ok-border)', color: 'var(--ok-fg)' }
    case 'warn':
      return { background: 'var(--warn-soft)', borderColor: 'var(--warn-border)', color: 'var(--warn-fg)' }
    case 'bad':
      return { background: 'var(--err-soft)', borderColor: 'var(--err-border)', color: 'var(--err-fg)' }
    case 'brass':
      return { background: 'var(--brass-soft)', borderColor: 'var(--brass-border)', color: 'var(--brass-fg)' }
  }
}

export function Chip(props: { readonly tone: ChipTone; readonly children: ComponentChildren; readonly title?: string }) {
  return html`
    <span
      class="mono"
      title=${props.title}
      style=${{
        ...toneStyle(props.tone),
        display: 'inline-flex',
        alignItems: 'center',
        padding: '0 var(--sp-2)',
        border: '1px solid',
        borderRadius: 'var(--radius-pill)',
        fontSize: 'var(--fs-11)',
        whiteSpace: 'nowrap',
      }}
    >${props.children}</span>
  `
}

/** Where the text in force came from, in the words an operator reads. */
export function SourceChip(props: { readonly source: PromptSource }) {
  switch (props.source) {
    case 'override':
      return html`<${Chip} tone="brass" title="운영자가 저장한 텍스트가 파일 텍스트 대신 쓰여요">override</${Chip}>`
    case 'file':
      return html`<${Chip} tone="neutral" title="config/prompts 파일의 텍스트를 그대로 써요">file</${Chip}>`
    case 'missing':
      return html`<${Chip} tone="bad" title="파일에도 override 에도 텍스트가 없어요">missing</${Chip}>`
  }
}
