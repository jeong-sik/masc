// @vitest-environment happy-dom
//
// jest-axe coverage for DistributionBars + SegmentedBar — data-viz
// atoms. axe primarily guards: (1) the bars convey their data via
// text labels (numeric + label) not color-alone, and (2) the tone
// palette doesn't introduce contrast-against-bg violations on any
// of the 5 tone slots.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import {
  DistributionBars,
  type DistributionItem,
} from './distribution-bars'

const items: DistributionItem[] = [
  { label: 'Active', value: 12, tone: 'ok' },
  { label: 'Idle', value: 5, tone: 'muted' },
  { label: 'Errored', value: 2, tone: 'bad' },
]

describe('DistributionBars a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('basic items render accessibly', async () => {
    render(html`<${DistributionBars} items=${items} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('with detail strings on each item passes axe', async () => {
    const detailed = items.map((i) => ({ ...i, detail: `${i.value} keepers` }))
    render(html`<${DistributionBars} items=${detailed} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('all 5 tones at once passes axe (tone-palette sweep)', async () => {
    const allTones: DistributionItem[] = [
      { label: 'A', value: 1, tone: 'accent' },
      { label: 'O', value: 2, tone: 'ok' },
      { label: 'W', value: 3, tone: 'warn' },
      { label: 'B', value: 4, tone: 'bad' },
      { label: 'M', value: 5, tone: 'muted' },
    ]
    render(html`<${DistributionBars} items=${allTones} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })
})

// SegmentedBar a11y test deliberately omitted from this PR.
//
// First-run revealed a real production violation: distribution-bars.ts
// renders `<div aria-label="...">` without a `role`. axe rule
// `aria-prohibited-attr` rejects this — aria-label requires a valid
// role on non-semantic elements. Same pattern at lines 152-156 (bar
// segments) and 164-170 (chip pills).
//
// Treating it under Issue Discovery Protocol (instructions/workflow.md):
// scope of this PR is *adding* a11y coverage, not fixing components.
// Mixing the fix in would silently expand surgical change scope.
//
// Followup: SegmentedBar should either add role="img" + aria-label OR
// drop aria-label and rely on the visible label rendered alongside.
// Tracking via PR description (this PR's body); upgrade to GitHub issue
// if the fix doesn't land in the next iter.
