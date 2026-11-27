import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import { TextArea } from './input'
import { RichContent } from './rich-content'

type ComposerMode = 'write' | 'preview'

export function RichComposer({
  value,
  onValueChange,
  placeholder,
  rows = 6,
  disabled,
  helpText,
  previewLimit = 2,
  ariaLabel,
}: {
  value: string
  onValueChange: (next: string) => void
  placeholder?: string
  rows?: number
  disabled?: boolean
  helpText?: string
  previewLimit?: number
  /** Accessible name for the underlying TextArea. Required for AT —
      without it the editor reads as an unlabeled form control. */
  ariaLabel?: string
}) {
  const [mode, setMode] = useState<ComposerMode>('write')

  return html`
    <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]">
      <div class="flex items-center justify-between gap-3 border-b border-[var(--color-border-default)] px-3 py-2">
        <div class="flex items-center gap-1.5">
          ${(['write', 'preview'] as ComposerMode[]).map(tab => html`
            <button
              key=${tab}
              type="button"
              class=${`rich-composer-tab rounded-[var(--r-1)] border px-2.5 py-1 text-2xs font-medium transition-colors ${
                mode === tab
                  ? 'border-[var(--info-border)] bg-[var(--accent-12)] text-[var(--color-accent-fg)]'
                  : 'border-transparent bg-transparent text-[var(--color-fg-muted)] hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-primary)]'
              }`}
              onClick=${() => setMode(tab)}
              disabled=${disabled}
            >
              ${tab === 'write' ? 'Write' : 'Preview'}
            </button>
          `)}
        </div>
        <div class="text-3xs text-[var(--color-fg-muted)]">
          Markdown, code fence, URL, image link
        </div>
      </div>

      <div class="p-3">
        ${mode === 'write'
          ? html`
              <${TextArea}
                value=${value}
                placeholder=${placeholder}
                rows=${rows}
                disabled=${disabled}
                ariaLabel=${ariaLabel}
                class="min-h-35"
                onInput=${(event: Event) => onValueChange((event.target as HTMLTextAreaElement).value)}
              />
            `
          : value.trim()
            ? html`
                <div class="max-h-80 overflow-auto rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] p-3 custom-scrollbar">
                  <${RichContent} text=${value} previewLimit=${previewLimit} />
                </div>
              `
            : html`
                <div class="rounded-[var(--r-1)] border border-dashed border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-6 text-center text-xs text-[var(--color-fg-muted)]">
                  미리볼 내용이 아직 없습니다.
                </div>
              `}
        ${helpText
          ? html`<div class="mt-2 text-2xs leading-relaxed text-[var(--color-fg-muted)]">${helpText}</div>`
          : null}
      </div>
    </div>
  `
}
