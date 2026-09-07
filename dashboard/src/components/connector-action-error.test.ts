// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { waitFor } from '@testing-library/preact'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  rawErrorText,
  showConnectorActionError,
} from './connector-action-error'
import { ToastContainer, _testGetToasts, _testResetToasts } from './common/toast'

const RAW_SERVER_ERROR =
  'POST /api/v1/sidecar/stop?name=discord: sidecar directory not found for discord; '
  + 'looked under /Users/op/me/sidecars/discord-bot. Set MASC_SIDECAR_ROOT=/path/to/masc.'

describe('rawErrorText', () => {
  it('unwraps Error message', () => {
    expect(rawErrorText(new Error('boom'))).toBe('boom')
  })

  it('stringifies non-Error throws', () => {
    expect(rawErrorText('plain string')).toBe('plain string')
    expect(rawErrorText(42)).toBe('42')
  })
})

describe('showConnectorActionError', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    _testResetToasts()
  })
  afterEach(() => {
    document.body.removeChild(container)
    vi.restoreAllMocks()
  })

  it('toast carries the headline only — server internals stay out', () => {
    showConnectorActionError('discord sidecar 중지 실패', new Error(RAW_SERVER_ERROR))
    const toasts = _testGetToasts()
    expect(toasts.length).toBe(1)
    expect(toasts[0]!.message).toBe('discord sidecar 중지 실패')
    expect(toasts[0]!.message).not.toContain('MASC_SIDECAR_ROOT')
    expect(toasts[0]!.message).not.toContain('/Users/')
    expect(toasts[0]!.type).toBe('error')
  })

  it('renders a 상세 action button on the toast', async () => {
    showConnectorActionError('바인딩 실패: 123 → luna', new Error(RAW_SERVER_ERROR))
    render(html`<${ToastContainer} />`, container)
    await Promise.resolve()
    const buttons = Array.from(container.querySelectorAll('button'))
    expect(buttons.some(b => b.textContent?.includes('상세'))).toBe(true)
  })

  it('상세 opens a dialog containing the raw server text', async () => {
    showConnectorActionError('바인딩 실패: 123 → luna', new Error(RAW_SERVER_ERROR))
    render(html`<${ToastContainer} />`, container)
    await Promise.resolve()
    const detailBtn = Array.from(container.querySelectorAll('button'))
      .find(b => b.textContent?.includes('상세'))!
    detailBtn.click()
    // The confirm-dialog overlay renders from its own module signal —
    // mount it and look for the raw text.
    const { ConfirmDialogOverlay } = await import('./common/confirm-dialog')
    const dialogHost = document.createElement('div')
    document.body.appendChild(dialogHost)
    try {
      render(html`<${ConfirmDialogOverlay} />`, dialogHost)
      await Promise.resolve()
      expect(dialogHost.textContent).toContain('MASC_SIDECAR_ROOT')
      expect(dialogHost.textContent).toContain('바인딩 실패: 123 → luna')
      // Resolve the dialog so its module-level open state does not leak
      // into the next test.
      Array.from(dialogHost.querySelectorAll('button'))
        .find(b => b.textContent?.includes('닫기') && !b.textContent.includes('복사'))!
        .click()
      await Promise.resolve()
    } finally {
      render(null, dialogHost)
      document.body.removeChild(dialogHost)
    }
  })
})

describe('openConnectorErrorDetail — copy sits on confirm, never on dismiss', () => {
  let dialogHost: HTMLElement
  let writeText: ReturnType<typeof vi.fn>

  beforeEach(async () => {
    dialogHost = document.createElement('div')
    document.body.appendChild(dialogHost)
    writeText = vi.fn().mockResolvedValue(undefined)
    Object.defineProperty(navigator, 'clipboard', {
      value: { writeText },
      configurable: true,
    })
    _testResetToasts()
    const { ConfirmDialogOverlay } = await import('./common/confirm-dialog')
    render(html`<${ConfirmDialogOverlay} />`, dialogHost)
  })
  afterEach(() => {
    render(null, dialogHost)
    document.body.removeChild(dialogHost)
    vi.restoreAllMocks()
  })

  // Exact-match on trimmed text: '복사 후 닫기' contains '닫기', so a
  // substring find could grab the wrong button.
  const dialogButton = (label: string) => {
    const found = Array.from(dialogHost.querySelectorAll('button'))
      .find(b => b.textContent?.trim() === label)
    // Throwing rather than asserting non-null is what lets waitFor retry, and
    // it names the missing label instead of failing on .click of undefined.
    if (!found) throw new Error(`no dialog button labelled ${label}`)
    return found
  }

  // DialogOverlay renders its body and attaches its document-level Escape
  // listener in the same effect, which preact schedules off the render.
  // Waiting a fixed 30ms for that guessed how long the scheduler would take,
  // and a parallel suite run makes the guess wrong: on 2026-09-06 this file
  // was the single failure in a 697-file parallel run — 5023ms against a 5s
  // limit — while passing every single-worker run. So wait for the thing.
  const dialogShown = () =>
    waitFor(() => expect(dialogHost.textContent).toContain('MASC_SIDECAR_ROOT'))
  const dialogGone = () =>
    waitFor(() =>
      expect(dialogHost.textContent ?? '').not.toContain('MASC_SIDECAR_ROOT'))

  it('Escape dismiss closes WITHOUT copying (ESC/backdrop map to cancel)', async () => {
    const { openConnectorErrorDetail } = await import('./connector-action-error')
    const pending = openConnectorErrorDetail('headline', RAW_SERVER_ERROR)
    await dialogShown()
    // One dispatch can still land ahead of the listener. Escape on a closed
    // dialog does nothing, so retrying until it closes removes the race.
    await waitFor(() => {
      document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
      expect(dialogHost.textContent ?? '').not.toContain('MASC_SIDECAR_ROOT')
    })
    await pending
    expect(writeText).not.toHaveBeenCalled()
  })

  it('복사 후 닫기 copies the raw text to the clipboard', async () => {
    const { openConnectorErrorDetail } = await import('./connector-action-error')
    const pending = openConnectorErrorDetail('headline', RAW_SERVER_ERROR)
    await dialogShown()
    ;(await waitFor(() => dialogButton('복사 후 닫기'))).click()
    await pending
    await dialogGone()
    expect(writeText).toHaveBeenCalledWith(RAW_SERVER_ERROR)
    expect(_testGetToasts().some(t => t.message.includes('복사했습니다'))).toBe(true)
  })

  it('닫기 button closes without copying', async () => {
    const { openConnectorErrorDetail } = await import('./connector-action-error')
    const pending = openConnectorErrorDetail('headline', RAW_SERVER_ERROR)
    await dialogShown()
    ;(await waitFor(() => dialogButton('닫기'))).click()
    await pending
    await dialogGone()
    expect(writeText).not.toHaveBeenCalled()
  })
})
