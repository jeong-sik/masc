import { h } from 'preact'
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ComposerV2, buildComposerV2Request } from './composer-v2'
import {
  operatorActionBusy,
  operatorSnapshot,
} from '../../operator-store'
import type { OperatorSnapshot } from '../../types'

import '@testing-library/jest-dom'

const currentDashboardActorMock = vi.hoisted(() => vi.fn(() => 'dashboard-test'))
const sendBroadcastMock = vi.hoisted(() => vi.fn())
const dispatchOperatorActionMock = vi.hoisted(() => vi.fn())
const showToastMock = vi.hoisted(() => vi.fn())

vi.mock('../../api', () => ({
  currentDashboardActor: currentDashboardActorMock,
  sendBroadcast: sendBroadcastMock,
}))

vi.mock('../../operator-store', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../operator-store')>()
  return {
    ...actual,
    dispatchOperatorAction: dispatchOperatorActionMock,
  }
})

vi.mock('../common/toast', () => ({
  showToast: showToastMock,
}))

function snapshotWithKeepers(keepers: Array<{ name: string; status: string }>): OperatorSnapshot {
  return {
    root: { paused: false, namespace: 'default' },
    sessions: [],
    keepers,
    recent_messages: [],
    pending_confirms: [],
    available_actions: [],
  } as unknown as OperatorSnapshot
}

describe('buildComposerV2Request', () => {
  it('keeps the compose shape required by the C3 contract', () => {
    expect(buildComposerV2Request({
      mode: 'state-block',
      roomId: '#ops',
      body: '[STATE]\nGoal: ship\nNEXT: verify\n[/STATE]',
    })).toEqual({
      compose: {
        mode: 'state-block',
        target: { room_id: 'ops' },
        body: {
          kind: 'state-block',
          raw: '[STATE]\nGoal: ship\nNEXT: verify\n[/STATE]',
          keys: ['Goal', 'NEXT'],
        },
        attachments: [],
      },
    })
  })
})

describe('ComposerV2', () => {
  beforeEach(() => {
    currentDashboardActorMock.mockReturnValue('dashboard-test')
    sendBroadcastMock.mockReset()
    sendBroadcastMock.mockResolvedValue(undefined)
    dispatchOperatorActionMock.mockReset()
    dispatchOperatorActionMock.mockResolvedValue({
      status: 'ok',
      confirm_required: false,
      result: 'sent',
    })
    showToastMock.mockReset()
    operatorActionBusy.value = false
    operatorSnapshot.value = snapshotWithKeepers([
      { name: 'keeper-a', status: 'online' },
      { name: 'nick0cave', status: 'busy' },
      { name: 'offline-one', status: 'offline' },
    ])
  })

  afterEach(() => {
    cleanup()
    operatorSnapshot.value = null
    operatorActionBusy.value = false
    vi.clearAllMocks()
  })

  it('sends broadcast drafts through the room broadcast transport', async () => {
    render(h(ComposerV2, { roomId: 'ops' }))

    expect(screen.getByLabelText('Target room: ops')).toBeInTheDocument()

    fireEvent.input(screen.getByLabelText('Composer v2 message'), {
      target: { value: 'room update' },
    })
    fireEvent.click(screen.getByRole('button', { name: 'Send' }))

    await waitFor(() => {
      expect(sendBroadcastMock).toHaveBeenCalledWith('dashboard-test', 'room update')
    })
    expect(dispatchOperatorActionMock).not.toHaveBeenCalled()
    expect((screen.getByLabelText('Composer v2 message') as HTMLTextAreaElement).value).toBe('')
  })

  it('sends keeper DMs through the operator keeper-message action', async () => {
    render(h(ComposerV2, { roomId: 'ops' }))

    fireEvent.click(screen.getByRole('button', { name: 'DM mode' }))
    fireEvent.input(screen.getByLabelText('Composer v2 message'), {
      target: { value: 'please check @nick' },
    })
    fireEvent.click(within(screen.getByRole('listbox')).getByRole('option', { name: /nick0cave/ }))
    fireEvent.click(screen.getByRole('button', { name: 'Send' }))

    await waitFor(() => {
      expect(dispatchOperatorActionMock).toHaveBeenCalledWith({
        actor: 'dashboard-test',
        action_type: 'keeper_message',
        target_type: 'keeper',
        target_id: 'nick0cave',
        payload: { message: 'please check @nick0cave' },
      })
    })
    expect(sendBroadcastMock).not.toHaveBeenCalled()
  })

  it('requires a parsed state block before state sends', async () => {
    render(h(ComposerV2, { roomId: 'merge-blockers' }))

    fireEvent.click(screen.getByRole('button', { name: 'State mode' }))

    expect(screen.getByRole('button', { name: 'Send' })).toBeDisabled()

    fireEvent.input(screen.getByLabelText('Composer v2 state block'), {
      target: { value: '[STATE]\nGoal: close queue\nBlocker: none\n[/STATE]' },
    })
    fireEvent.click(screen.getByRole('button', { name: 'Send' }))

    await waitFor(() => {
      expect(sendBroadcastMock).toHaveBeenCalledWith(
        'dashboard-test',
        '[STATE]\nGoal: close queue\nBlocker: none\n[/STATE]',
      )
    })
  })
})
