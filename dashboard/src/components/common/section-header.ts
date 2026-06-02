// SectionHeader — consistent section labels across dashboard
// Replaces 34+ inline patterns: `text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)] font-medium`

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

export type HeaderSize = 'xs' | 'sm' | 'md'

export interface SectionHeaderSummary {
  readonly size: HeaderSize
  readonly hasRight: boolean
  readonly hasCustomClass: boolean
  readonly classNameLength: number
}

const SIZE_CLASSES: Record<HeaderSize, string> = {
  xs: 'text-3xs font-semibold tracking-wider',
  sm: 'text-2xs font-medium tracking-[var(--track-sub)]',
  md: 'text-sm font-medium tracking-[var(--track-sub)]',
}

export function sectionHeaderClasses(extra?: string): string {
  return ['flex items-center justify-between gap-2', extra].filter(Boolean).join(' ')
}

export function sectionHeaderHeadingClasses(size: HeaderSize = 'sm'): string {
  return `m-0 ${SIZE_CLASSES[size]} uppercase tracking-[var(--track-sub)] text-[var(--color-fg-muted)]`
}

export function summarizeSectionHeader({
  size = 'sm',
  className,
  right,
}: {
  size?: HeaderSize
  className?: string
  right?: ComponentChildren
}): SectionHeaderSummary {
  return {
    size,
    hasRight: right !== undefined && right !== null && right !== false,
    hasCustomClass: className !== undefined && className !== '',
    classNameLength: className?.length ?? 0,
  }
}

export interface SectionHeaderProps {
  size?: HeaderSize
  class?: string
  /** Right-side slot (counts, actions) */
  right?: ComponentChildren
  children?: ComponentChildren
}

/** Uppercase tracked section label — the dashboard's standard heading pattern */
export function SectionHeader({
  size = 'sm',
  class: cx,
  right,
  children,
}: SectionHeaderProps) {
  const summary = summarizeSectionHeader({ size, className: cx, right })
  return html`
    <div
      class=${sectionHeaderClasses(cx)}
      data-section-header
      data-section-header-size=${summary.size}
      data-section-header-has-right=${summary.hasRight}
      data-section-header-has-custom-class=${summary.hasCustomClass}
      data-section-header-class-length=${summary.classNameLength}
    >
      <h4 class=${sectionHeaderHeadingClasses(size)}>${children}</h4>
      ${right ?? null}
    </div>
  `
}
