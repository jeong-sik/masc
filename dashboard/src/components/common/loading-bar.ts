// LoadingBar — indeterminate progress strip.
//
// Reference UIs (GitHub PR checks "pending" bar, Vercel deployment log
// streaming bar, Linear sync bar): a sweeping gradient inside a muted
// track signals "work is happening but we don't know the %". Distinct
// from ProgressBar, which requires a known percentage value.

import { html } from 'htm/preact'

export interface LoadingBarSummary {
  readonly isIndeterminate: true
  readonly hasSemanticLabel: boolean
  readonly hasTestId: boolean
  readonly ariaLabelLength: number
  readonly testIdLength: number
}

export interface LoadingBarProps {
  /** Override the decorative default. When set, exposes role="status"
      + aria-label so screen-reader users hear the loading state. */
  ariaLabel?: string
  testId?: string
}

/** Pure: metadata snapshot used for tests and data attributes. */
export function summarizeLoadingBar({
  ariaLabel,
  testId,
}: LoadingBarProps): LoadingBarSummary {
  const normalizedAriaLabel = ariaLabel?.trim()
  const hasSemanticLabel =
    normalizedAriaLabel !== undefined && normalizedAriaLabel !== ''
  return {
    isIndeterminate: true,
    hasSemanticLabel,
    hasTestId: testId !== undefined && testId !== '',
    ariaLabelLength: normalizedAriaLabel?.length ?? 0,
    testIdLength: testId?.length ?? 0,
  }
}

/** Indeterminate loading bar — renders the .loading-bar primitive. */
export function LoadingBar({ ariaLabel, testId }: LoadingBarProps) {
  const summary = summarizeLoadingBar({ ariaLabel, testId })
  const normalizedAriaLabel = ariaLabel?.trim()
  return html`<div
    class="loading-bar"
    role=${summary.hasSemanticLabel ? 'status' : undefined}
    aria-label=${normalizedAriaLabel}
    aria-hidden=${summary.hasSemanticLabel ? undefined : 'true'}
    data-loading-bar
    data-loading-bar-indeterminate=${summary.isIndeterminate}
    data-loading-bar-has-semantic-label=${summary.hasSemanticLabel}
    data-loading-bar-has-test-id=${summary.hasTestId}
    data-loading-bar-aria-label-length=${summary.ariaLabelLength}
    data-loading-bar-test-id-length=${summary.testIdLength}
    data-testid=${testId}
  ></div>`
}
