// @vitest-environment happy-dom
//
// jest-axe coverage for Skeleton/SkeletonText/SkeletonCircle. Pattern:
// decorative skeletons set aria-hidden="true" (the wrapper guides AT to
// skip the visual placeholder); skeletons announced as "loading" set
// role="status" + aria-label. Both modes must axe-clean.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { Skeleton, SkeletonText, SkeletonCircle } from './skeleton'

describe('Skeleton a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('decorative Skeleton (no ariaLabel) passes axe', async () => {
    render(html`<${Skeleton} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('announced Skeleton (ariaLabel + role=status) passes axe', async () => {
    render(html`<${Skeleton} ariaLabel="Loading metrics" />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('blank ariaLabel Skeleton stays decorative and passes axe', async () => {
    render(html`<${Skeleton} ariaLabel="   " />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('SkeletonText 3-line passes axe', async () => {
    render(html`<${SkeletonText} lines=${3} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('SkeletonText with ariaLabel passes axe', async () => {
    render(
      html`<${SkeletonText} lines=${5} ariaLabel="Loading log preview" />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('SkeletonCircle (avatar placeholder) passes axe', async () => {
    render(html`<${SkeletonCircle} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('announced SkeletonCircle passes axe', async () => {
    render(html`<${SkeletonCircle} ariaLabel="Loading avatar" />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })
})
