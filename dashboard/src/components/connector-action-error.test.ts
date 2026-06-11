// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
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
    } finally {
      render(null, dialogHost)
      document.body.removeChild(dialogHost)
    }
  })
})
