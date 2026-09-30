// Expandable textarea — full-screen editing for long-form keeper prompts.
//
// Uses local state while typing so large texts do not re-render the parent
// panel on every keystroke. Changes are committed to the parent on blur and
// when the full-screen modal is confirmed.

import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'

export const EXPANDABLE_TEXTAREA_STYLE =
  'w-full bg-card/60 backdrop-blur-sm text-text-strong text-sm border border-card-border rounded-[var(--r-1)] py-2 px-3 font-mono focus:outline-none focus:border-accent-fg/50 focus:ring-1 focus:ring-accent-fg/50 transition-[border-color,box-shadow] duration-[var(--t-med)] shadow-inset resize-y custom-scrollbar'

function byteLength(s: string): number {
  return new TextEncoder().encode(s).length
}

export function ExpandableTextarea({
  value,
  onChange,
  label,
  rows = 6,
  placeholder = '',
  dirty = false,
  maxBytes,
  maxChars,
}: {
  value: string
  onChange: (value: string) => void
  label: string
  rows?: number
  placeholder?: string
  dirty?: boolean
  maxBytes?: number
  maxChars?: number
}) {
  const [local, setLocal] = useState(value)
  const [expanded, setExpanded] = useState(false)

  // Sync when the parent resets the draft (e.g. entering/exiting edit mode).
  useEffect(() => {
    setLocal(value)
  }, [value])

  function commit(next: string) {
    setLocal(next)
    onChange(next)
  }

  const borderClass = dirty
    ? 'border-l-4 border-l-[var(--color-accent-fg)]'
    : ''

  const charCount = local.length
  const byteCount = byteLength(local)
  const overLimit = (maxBytes !== undefined && byteCount > maxBytes)
    || (maxChars !== undefined && charCount > maxChars)
  const nearLimit = !overLimit
    && ((maxBytes !== undefined && byteCount > maxBytes * 0.9)
      || (maxChars !== undefined && charCount > maxChars * 0.9))

  let countLabel = ''
  if (maxBytes !== undefined) {
    countLabel = `${byteCount.toLocaleString()} / ${maxBytes.toLocaleString()} bytes`
  } else if (maxChars !== undefined) {
    countLabel = `${charCount.toLocaleString()} / ${maxChars.toLocaleString()} 글자`
  } else {
    countLabel = `${charCount.toLocaleString()} 글자`
  }

  const countColor = overLimit
    ? 'text-[var(--color-status-error)]'
    : nearLimit
      ? 'text-[var(--color-status-warn)]'
      : 'text-[var(--color-fg-muted)]'

  const CountHint = () => html`
    <span class="text-3xs ${countColor} font-medium">${countLabel}</span>
  `

  return html`
    <div class="relative">
      <textarea
        aria-label=${label}
        class="${EXPANDABLE_TEXTAREA_STYLE} ${borderClass} pr-10"
        rows=${rows}
        value=${local}
        placeholder=${placeholder}
        onInput=${(e: Event) =>
          setLocal((e.target as HTMLTextAreaElement).value)}
        onBlur=${(e: Event) =>
          commit((e.target as HTMLTextAreaElement).value)}
      />
      <div class="flex justify-end mt-1">
        <${CountHint} />
      </div>
      <button
        type="button"
        class="absolute top-2 right-2 rounded-[var(--r-0)] bg-[var(--color-bg-surface)] border border-card-border px-1.5 py-0.5 text-3xs text-[var(--color-fg-muted)] hover:text-text-strong hover:bg-[var(--color-bg-hover)] transition-colors"
        title="전체 화면으로 편집"
        onClick=${() => setExpanded(true)}
      >
        ⛶
      </button>
      ${expanded
        ? html`
            <div
              class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
              onClick=${() => setExpanded(false)}
            >
              <div
                class="flex flex-col w-full max-w-5xl h-[85vh] rounded-[var(--r-3)] border border-card-border bg-[var(--color-bg-elevated)] shadow-[var(--shadow-3)] p-4"
                onClick=${(e: Event) => e.stopPropagation()}
              >
                <div class="flex items-center justify-between mb-3">
                  <span class="text-sm font-semibold text-text-strong">
                    ${label}
                  </span>
                  <button
                    type="button"
                    class="text-2xs text-[var(--color-fg-muted)] hover:text-text-strong"
                    onClick=${() => setExpanded(false)}
                  >
                    닫기
                  </button>
                </div>
                <textarea
                  class="${EXPANDABLE_TEXTAREA_STYLE} flex-1"
                  value=${local}
                  placeholder=${placeholder}
                  onInput=${(e: Event) =>
                    setLocal((e.target as HTMLTextAreaElement).value)}
                />
                <div class="flex items-center justify-between gap-2 mt-3">
                  <${CountHint} />
                  <div class="flex gap-2">
                    <button
                      type="button"
                      class="px-3 py-1.5 rounded-[var(--r-1)] text-2xs bg-[var(--color-bg-hover)] text-[var(--color-fg-secondary)]"
                      onClick=${() => setExpanded(false)}
                    >
                      취소
                    </button>
                  <button
                    type="button"
                    class="px-3 py-1.5 rounded-[var(--r-1)] text-2xs bg-[var(--color-status-ok)] text-[var(--color-fg-on-ok)]"
                    onClick=${() => {
                      commit(local)
                      setExpanded(false)
                    }}
                  >
                    확인
                  </button>
                  </div>
                </div>
              </div>
            </div>
          `
        : null}
    </div>
  `
}
