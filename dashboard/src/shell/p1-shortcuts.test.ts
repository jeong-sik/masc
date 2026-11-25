// @vitest-environment jsdom
import { html } from 'htm/preact'
import { act, cleanup, render } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { QuickPeekDrawer } from '../components/primitives/quick-peek-drawer'
import { activeWorkspaceId } from '../core/auth'
import {
  closeCommandPalette,
  commandPaletteOpen,
  mobileMoreOpen,
  openCommandPalette,
  pendingApprovals,
} from './shell-state'
import { CommandPalette } from './command-palette'
import { FastApprovalStrip } from './fast-approval-strip'

const submitMock = vi.fn().mockResolvedValue(true)

vi.mock('./shell-state', async (importOriginal) => {
  const actual = await importOriginal<typeof import('./shell-state')>()
  return {
    ...actual,
    submitFastToolApproval: (...args: unknown[]) => submitMock(...args),
  }
})

describe('P1 Dashboard shortcut & modal layering regressions', () => {
  beforeEach(() => {
    submitMock.mockClear()
    pendingApprovals.value = []
    closeCommandPalette()
    mobileMoreOpen.value = false
  })

  afterEach(() => {
    cleanup()
    pendingApprovals.value = []
    closeCommandPalette()
    mobileMoreOpen.value = false
  })

  it('FastApprovalStrip accepts Shift+Y/N and macOS Option+Y/N via event.code while typing', async () => {
    const ws = activeWorkspaceId.peek()
    pendingApprovals.value = [
      {
        approvalId: 'appr-1',
        keeper: 'alpha',
        toolCallId: 'tc-1',
        tool: 'bash',
        args: '{}',
        question: 'run command?',
        because: 'verify',
        askedAt: 1_700_000_000,
        workspaceId: ws,
        revision: 'r1',
      },
    ]

    const view = render(html`
      <div>
        <input data-testid="composer" />
        <${FastApprovalStrip} />
      </div>
    `)
    await act(async () => {
      await Promise.resolve()
    })

    // Shift+Y works when not typing (matches uppercase <kbd>Y</kbd> and TUI).
    await act(async () => {
      window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Y', code: 'KeyY', shiftKey: true, bubbles: true }))
      await Promise.resolve()
    })
    expect(submitMock).toHaveBeenCalledTimes(1)
    expect(submitMock).toHaveBeenLastCalledWith(expect.objectContaining({ approvalId: 'appr-1' }), 'approve')

    // macOS Option+N emits key='Dead' with code='KeyN' while typing in an input.
    const input = view.getByTestId('composer')
    input.focus()
    await act(async () => {
      input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Dead', code: 'KeyN', altKey: true, bubbles: true }))
      await Promise.resolve()
    })
    expect(submitMock).toHaveBeenCalledTimes(2)
    expect(submitMock).toHaveBeenLastCalledWith(expect.objectContaining({ approvalId: 'appr-1' }), 'deny')

    // macOS Option+Y emits key='¥' with code='KeyY' while typing in an input.
    await act(async () => {
      input.dispatchEvent(new KeyboardEvent('keydown', { key: '¥', code: 'KeyY', altKey: true, bubbles: true }))
      await Promise.resolve()
    })
    expect(submitMock).toHaveBeenCalledTimes(3)
    expect(submitMock).toHaveBeenLastCalledWith(expect.objectContaining({ approvalId: 'appr-1' }), 'approve')
  })

  it('QuickPeekDrawer yields Escape to foreground aria-modal dialogs and CommandPalette closes via window Escape', async () => {
    const onDrawerClose = vi.fn()
    render(html`
      <div>
        <${QuickPeekDrawer} open=${true} mode="push" title="Inspector" onClose=${onDrawerClose}>
          <div>details</div>
        <//>
        <${CommandPalette} />
      </div>
    `)

    await act(async () => {
      openCommandPalette()
      await Promise.resolve()
    })
    expect(commandPaletteOpen.peek()).toBe(true)

    // Simulate focus escaping outside .ap-cmdk-dialog (e.g. via Tab).
    document.body.focus()
    await act(async () => {
      window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
      await Promise.resolve()
    })

    // Foreground CommandPalette closes first; background QuickPeekDrawer remains open.
    expect(commandPaletteOpen.peek()).toBe(false)
    expect(onDrawerClose).not.toHaveBeenCalled()

    // Second Escape closes the now-topmost QuickPeekDrawer.
    await act(async () => {
      window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
      await Promise.resolve()
    })
    expect(onDrawerClose).toHaveBeenCalledTimes(1)
  })
})
