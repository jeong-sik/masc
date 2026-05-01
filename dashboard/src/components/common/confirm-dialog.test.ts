// @ts-nocheck
import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { ConfirmDialogOverlay, requestConfirm } from './confirm-dialog'

describe('ConfirmDialogOverlay', () => {
  it('returns null when closed', () => {
    const container = document.createElement('div')
    render(h(ConfirmDialogOverlay, null), container)
    expect(container.querySelector('[role="dialog"]')).toBeNull()
  })
})

describe('requestConfirm', () => {
  it('resolves true on confirm', async () => {
    const container = document.createElement('div')
    render(h(ConfirmDialogOverlay, null), container)

    const promise = requestConfirm({ title: 'Q', message: 'Sure?' })
    render(h(ConfirmDialogOverlay, null), container)

    const buttons = container.querySelectorAll('button')
    const confirmBtn = Array.from(buttons).find((b) => b.textContent !== '취소') as HTMLElement
    confirmBtn?.dispatchEvent(new MouseEvent('click', { bubbles: true }))

    const result = await promise
    expect(result).toBe(true)
  })

  it('resolves false on cancel', async () => {
    const container = document.createElement('div')
    render(h(ConfirmDialogOverlay, null), container)

    const promise = requestConfirm({ title: 'Q', message: 'Sure?' })
    render(h(ConfirmDialogOverlay, null), container)

    const buttons = container.querySelectorAll('button')
    const cancelBtn = Array.from(buttons).find((b) => b.textContent === '취소') as HTMLElement
    cancelBtn?.dispatchEvent(new MouseEvent('click', { bubbles: true }))

    const result = await promise
    expect(result).toBe(false)
  })

  it('renders title and message', () => {
    const container = document.createElement('div')
    requestConfirm({ title: 'Delete?', message: 'Remove file' })
    render(h(ConfirmDialogOverlay, null), container)
    expect(container.textContent).toContain('Delete?')
    expect(container.textContent).toContain('Remove file')
  })

  it('renders custom confirm/cancel text', () => {
    const container = document.createElement('div')
    requestConfirm({ title: 'Q', message: 'M', confirmText: 'Yes', cancelText: 'No' })
    render(h(ConfirmDialogOverlay, null), container)
    expect(container.textContent).toContain('Yes')
    expect(container.textContent).toContain('No')
  })
})
