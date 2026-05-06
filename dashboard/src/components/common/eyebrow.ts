import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

export type EyebrowTone = 'muted' | 'disabled'

export interface EyebrowSummary {
  readonly tone: EyebrowTone
  readonly hasCustomClass: boolean
  readonly classNameLength: number
}

const BASE = 'text-3xs uppercase tracking-wider'

const TONE_CLASSES: Record<EyebrowTone, string> = {
  muted: 'text-[var(--color-fg-muted)]',
  disabled: 'text-[var(--color-fg-disabled)]',
}

export function eyebrowClasses(tone: EyebrowTone = 'muted', extra?: string): string {
  return [BASE, TONE_CLASSES[tone], extra].filter(Boolean).join(' ')
}

export function summarizeEyebrow({
  tone = 'muted',
  className,
}: {
  tone?: EyebrowTone
  className?: string
}): EyebrowSummary {
  return {
    tone,
    hasCustomClass: className !== undefined && className !== '',
    classNameLength: className?.length ?? 0,
  }
}

export interface EyebrowProps {
  tone?: EyebrowTone
  class?: string
  children?: ComponentChildren
}

/** Inline eyebrow label — `text-3xs uppercase tracking-wider` used inside cards */
export function Eyebrow({ tone = 'muted', class: cx, children }: EyebrowProps) {
  const summary = summarizeEyebrow({ tone, className: cx })
  const cls = eyebrowClasses(tone, cx)
  return html`<span
    class=${cls}
    data-eyebrow
    data-eyebrow-tone=${summary.tone}
    data-eyebrow-has-custom-class=${summary.hasCustomClass}
    data-eyebrow-class-length=${summary.classNameLength}
  >${children}</span>`
}
