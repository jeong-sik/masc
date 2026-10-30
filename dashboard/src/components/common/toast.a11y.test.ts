// @vitest-environment happy-dom
//
// jest-axe coverage for ToastContainer. Toasts are signal-driven; each
// test seeds the toast queue via showToast(), renders the container,
// runs axe, then drains via _testResetToasts() so state doesn't leak.
//
// Critical a11y surface: toasts are live announcements; the container
// must use aria-live so AT users hear them without focus moving. axe
// checks role + aria-live presence on the wrapper.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import {
  ToastContainer,
  showToast,
  showActionToast,
  _testResetToasts,
} from './toast'

describe('ToastContainer a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    _testResetToasts()
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
    _testResetToasts()
  })

  it('empty container renders accessibly', async () => {
    render(html`<${ToastContainer} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('single success toast passes axe', async () => {
    showToast('Saved', 'success', 5000)
    render(html`<${ToastContainer} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('warning + error toasts together pass axe (tone palette sweep)', async () => {
    showToast('Slow connection', 'warning', 5000)
    showToast('Network error', 'error', 5000)
    render(html`<${ToastContainer} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('action toast (with button) passes axe', async () => {
    showActionToast('Saved', { label: 'Undo', onClick: () => {} }, 'success', 5000)
    render(html`<${ToastContainer} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })
})
