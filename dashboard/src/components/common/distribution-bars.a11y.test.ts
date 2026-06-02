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
  SegmentedBar,
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

// SegmentedBar a11y suite — enabled in this PR. The original violation
// noted in #11720 (aria-label on <div>/<span> without role) was fixed
// in this same commit:
//   - bar segments: now aria-hidden=true (purely decorative, info is
//     in the chip pills)
//   - chip pills: aria-label dropped (visible text content carries
//     the accessible name)
describe('SegmentedBar a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders accessibly with mixed tones', async () => {
    render(html`<${SegmentedBar} items=${items} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('with title + subtitle passes axe', async () => {
    render(
      html`<${SegmentedBar}
        title="Keeper status"
        subtitle="last 60 minutes"
        items=${items}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('with empty items shows the empty-state message accessibly', async () => {
    render(html`<${SegmentedBar} title="Empty" items=${[]} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('full 5-tone palette in a SegmentedBar passes axe', async () => {
    const allTones: DistributionItem[] = [
      { label: 'A', value: 1, tone: 'accent' },
      { label: 'O', value: 2, tone: 'ok' },
      { label: 'W', value: 3, tone: 'warn' },
      { label: 'B', value: 4, tone: 'bad' },
      { label: 'M', value: 5, tone: 'muted' },
    ]
    render(html`<${SegmentedBar} items=${allTones} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })
})
