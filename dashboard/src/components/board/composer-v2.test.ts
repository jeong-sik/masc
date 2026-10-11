import { h } from 'preact'
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { BroadcastSendReceipt } from '../../api/actions'
import { ComposerV2, buildComposerV2Request } from './composer-v2'
import {
  operatorActionBusy,
  operatorSnapshot,
} from '../../operator-store'
import { keepers as dashboardKeepers } from '../../store'
import type { Keeper, OperatorSnapshot } from '../../types'

import '@testing-library/jest-dom'

const currentDashboardActorMock = vi.hoisted(() => vi.fn(() => 'dashboard-test'))
const sendBroadcastMock = vi.hoisted(() => vi.fn())
const dispatchOperatorActionMock = vi.hoisted(() => vi.fn())
const showToastMock = vi.hoisted(() => vi.fn())
const voiceStartMock = vi.hoisted(() => vi.fn())
const voiceStopMock = vi.hoisted(() => vi.fn())
const voiceInputState = vi.hoisted(() => ({
  state: 'idle' as 'idle' | 'recording' | 'transcribing',
  supported: true,
  transcript: '스케줄러 결과 확인 바람',
}))

vi.mock('../../api', () => ({
  currentDashboardActor: currentDashboardActorMock,
  sendBroadcast: sendBroadcastMock,
  broadcastReceiptMessage: vi.fn(() => 'broadcast receipt'),
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

vi.mock('../chat/voice-input', () => ({
  useVoiceInput: (options: { onTranscribed: (text: string) => void }) => ({
    state: voiceInputState.state,
    supported: voiceInputState.supported,
    start: voiceStartMock.mockImplementation(() => {
      options.onTranscribed(voiceInputState.transcript)
      return Promise.resolve()
    }),
    stop: voiceStopMock,
  }),
}))

function snapshotWithKeepers(keepers: Array<{
  name: string
  status?: string
  phase?: string | null
  pipeline_stage?: string | null
  paused?: boolean | null
}>): OperatorSnapshot {
  return {
    root: { paused: false, namespace: 'default' },
    sessions: [],
    keepers,
    recent_messages: [],
    available_actions: [],
  } as unknown as OperatorSnapshot
}

function keeperFixture(overrides: Partial<Keeper> & { name: string }): Keeper {
  const { name, status = 'running', ...rest } = overrides
  return {
    name,
    status,
    ...rest,
  } as Keeper
}

describe('buildComposerV2Request', () => {
  it('keeps the broadcast compose shape', () => {
    expect(buildComposerV2Request({
      mode: 'broadcast',
      workspaceId: '#ops',
      body: 'ship and verify',
    })).toEqual({
      compose: {
        mode: 'broadcast',
        target: { workspace_id: 'ops' },
        body: 'ship and verify',
        attachments: [],
      },
    })
  })

  it('preserves multimodal attachment drafts in the request envelope', () => {
    expect(buildComposerV2Request({
      mode: 'broadcast',
      workspaceId: 'ops',
      body: 'see attached',
      attachments: [{
        id: 'att-1',
        kind: 'file',
        name: 'trace.log',
        size: '4 KB',
      }],
    })).toEqual({
      compose: {
        mode: 'broadcast',
        target: { workspace_id: 'ops' },
        body: 'see attached',
        attachments: [{
          id: 'att-1',
          kind: 'file',
          name: 'trace.log',
          size: '4 KB',
        }],
      },
    })
  })
})

describe('ComposerV2', () => {
  beforeEach(() => {
    currentDashboardActorMock.mockReturnValue('dashboard-test')
    sendBroadcastMock.mockReset()
    sendBroadcastMock.mockResolvedValue({
      ok: true,
      requestId: 'wmsg-test',
      deliveryKind: 'passive',
      reason: null,
      workspacePersisted: true,
    })
    dispatchOperatorActionMock.mockReset()
    dispatchOperatorActionMock.mockResolvedValue({
      status: 'ok',
      confirm_required: false,
      result: 'sent',
    })
    showToastMock.mockReset()
    voiceStartMock.mockReset()
    voiceStopMock.mockReset()
    voiceInputState.state = 'idle'
    voiceInputState.supported = true
    voiceInputState.transcript = '스케줄러 결과 확인 바람'
    operatorActionBusy.value = false
    operatorSnapshot.value = snapshotWithKeepers([
      { name: 'keeper-a', status: 'online' },
      { name: 'nick0cave', status: 'busy' },
      { name: 'offline-one', status: 'offline' },
    ])
    dashboardKeepers.value = []
  })

  afterEach(() => {
    cleanup()
    operatorSnapshot.value = null
    operatorActionBusy.value = false
    dashboardKeepers.value = []
    vi.clearAllMocks()
  })

  it.each([true, false])('preserves input authored while a broadcast receipt is pending (accepted=%s)', async (accepted) => {
    let resolve!: (value: BroadcastSendReceipt) => void
    sendBroadcastMock.mockReturnValue(new Promise(done => { resolve = done }))
    render(h(ComposerV2, { workspaceId: 'ops' }))
    const input = screen.getByLabelText('Composer v2 message') as HTMLTextAreaElement
    fireEvent.input(input, { target: { value: 'sent text' } })
    fireEvent.click(screen.getByRole('button', { name: 'Send' }))
    expect(sendBroadcastMock).toHaveBeenCalledTimes(1)
    fireEvent.input(input, { target: { value: 'next unsent text' } })
    resolve({ ok: accepted, requestId: 'pending-receipt', deliveryKind: 'passive', reason: null, workspacePersisted: true })
    await waitFor(() => expect(showToastMock).toHaveBeenCalledWith(accepted ? 'Message sent.' : 'broadcast receipt', accepted ? 'success' : 'warning'))
    expect(input.value).toBe('next unsent text')
  })

  it('preserves a newly authored draft even when its text equals the sent text', async () => {
    let resolve!: (value: BroadcastSendReceipt) => void
    sendBroadcastMock.mockReturnValue(new Promise(done => { resolve = done }))
    render(h(ComposerV2, { workspaceId: 'ops' }))
    const input = screen.getByLabelText('Composer v2 message') as HTMLTextAreaElement
    fireEvent.input(input, { target: { value: 'same text' } })
    fireEvent.click(screen.getByRole('button', { name: 'Send' }))
    fireEvent.input(input, { target: { value: 'temporary edit' } })
    fireEvent.input(input, { target: { value: 'same text' } })
    resolve({ ok: true, requestId: 'aba-receipt', deliveryKind: 'passive', reason: null, workspacePersisted: true })
    await waitFor(() => expect(showToastMock).toHaveBeenCalledWith('Message sent.', 'success'))
    expect(input.value).toBe('same text')
  })

  it.each(['broadcast', 'dm'] as const)('uses the current native input snapshot for %s sending', async (mode) => {
    render(h(ComposerV2, { workspaceId: 'ops', mode }))
    const input = screen.getByLabelText('Composer v2 message') as HTMLTextAreaElement
    fireEvent.input(input, { target: { value: 'old body' } })
    input.value = mode === 'dm' ? 'current body @nick0cave' : 'current body'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    screen.getByRole('button', { name: 'Send' }).dispatchEvent(new MouseEvent('click', { bubbles: true }))
    if (mode === 'dm') {
      expect(dispatchOperatorActionMock).toHaveBeenCalledWith(expect.objectContaining({
        target_id: 'nick0cave', payload: { message: 'current body @nick0cave' },
      }))
    } else {
      expect(sendBroadcastMock).toHaveBeenCalledWith('dashboard-test', 'current body')
    }
    await waitFor(() => expect(input.value).toBe(''))
  })

  it('admits one broadcast when two native send events arrive before rerender', async () => {
    let resolve!: (value: BroadcastSendReceipt) => void
    sendBroadcastMock.mockReturnValue(new Promise(done => { resolve = done }))
    render(h(ComposerV2, { workspaceId: 'ops' }))
    fireEvent.input(screen.getByLabelText('Composer v2 message'), { target: { value: 'one broadcast' } })
    const send = screen.getByRole('button', { name: 'Send' })
    send.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    send.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    expect(sendBroadcastMock).toHaveBeenCalledTimes(1)
    resolve({ ok: true, requestId: 'test-broadcast', deliveryKind: 'passive', reason: null, workspacePersisted: true })
    await waitFor(() => expect((screen.getByLabelText('Composer v2 message') as HTMLTextAreaElement).value).toBe(''))
  })

  it('releases submission admission after a transport exception for an explicit retry', async () => {
    sendBroadcastMock.mockRejectedValueOnce(new Error('transport exception'))
    render(h(ComposerV2, { workspaceId: 'ops' }))
    fireEvent.input(screen.getByLabelText('Composer v2 message'), { target: { value: 'first attempt' } })
    fireEvent.click(screen.getByRole('button', { name: 'Send' }))
    await waitFor(() => expect(showToastMock).toHaveBeenCalledWith('transport exception', 'error'))
    expect((screen.getByLabelText('Composer v2 message') as HTMLTextAreaElement).value).toBe('first attempt')
    sendBroadcastMock.mockResolvedValue({ ok: true, requestId: 'retry-broadcast', deliveryKind: 'passive', reason: null, workspacePersisted: true })
    fireEvent.input(screen.getByLabelText('Composer v2 message'), { target: { value: 'explicit next attempt' } })
    fireEvent.click(screen.getByRole('button', { name: 'Send' }))
    await waitFor(() => expect(sendBroadcastMock).toHaveBeenCalledTimes(2))
    expect(sendBroadcastMock).toHaveBeenLastCalledWith('dashboard-test', 'explicit next attempt')
  })

  it('sends broadcast drafts through the workspace broadcast transport', async () => {
    render(h(ComposerV2, { workspaceId: 'ops' }))

    expect(screen.getByLabelText('Target workspace: ops')).toBeInTheDocument()
    expect(screen.getByTestId('composer-v2-command-rail')).toHaveTextContent('Broadcast')
    expect(screen.getByTestId('composer-v2-command-rail')).toHaveTextContent('#ops')
    expect(screen.getByTestId('composer-v2-command-rail')).toHaveTextContent('no files')
    expect(screen.getByTestId('composer-v2-command-rail')).toHaveTextContent('blocked · draft empty')

    fireEvent.input(screen.getByLabelText('Composer v2 message'), {
      target: { value: 'workspace update' },
    })
    expect(screen.getByTestId('composer-v2-command-rail')).toHaveTextContent('ready · workspace broadcast')
    fireEvent.click(screen.getByRole('button', { name: 'Send' }))

    await waitFor(() => {
      expect(sendBroadcastMock).toHaveBeenCalledWith('dashboard-test', 'workspace update')
    })
    expect(dispatchOperatorActionMock).not.toHaveBeenCalled()
    expect((screen.getByLabelText('Composer v2 message') as HTMLTextAreaElement).value).toBe('')
  })

  it('blocks attachment-only drafts until block transport is available', () => {
    render(h(ComposerV2, { workspaceId: 'ops' }))

    fireEvent.change(screen.getByTestId('composer-v2-file-input'), {
      target: { files: [new File(['body'], 'trace.log', { type: 'text/plain' })] },
    })

    expect(screen.getByTestId('composer-v2-tray')).toHaveTextContent('trace.log')
    expect(screen.getByTestId('composer-v2-tray')).toHaveTextContent('text/plain')
    expect(screen.getByTestId('composer-v2-tray')).toHaveTextContent('transport unavailable')
    expect(screen.getByTestId('composer-v2-command-rail')).toHaveTextContent('1 file')
    expect(screen.getByTestId('composer-v2-command-rail')).toHaveTextContent('blocked · attachment transport unavailable')
    expect(screen.getByRole('button', { name: 'Send' })).toBeDisabled()
    fireEvent.click(screen.getByRole('button', { name: 'Send' }))

    expect(sendBroadcastMock).not.toHaveBeenCalled()
    expect(screen.getByTestId('composer-v2-tray')).toBeInTheDocument()
  })

  it('transcribes voice input into the current text transport', async () => {
    render(h(ComposerV2, { workspaceId: 'ops' }))

    fireEvent.click(screen.getByRole('button', { name: 'Start voice input' }))
    expect(voiceStartMock).toHaveBeenCalledTimes(1)
    expect(screen.getByLabelText('Composer v2 message')).toHaveValue('스케줄러 결과 확인 바람')

    fireEvent.click(screen.getByRole('button', { name: 'Send' }))

    await waitFor(() => {
      expect(sendBroadcastMock).toHaveBeenCalledWith('dashboard-test', '스케줄러 결과 확인 바람')
    })
  })

  it('sends keeper DMs through the operator keeper-message action', async () => {
    render(h(ComposerV2, { workspaceId: 'ops' }))

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

  it('keeps phase-paused keepers selectable for DMs even when status is offline', () => {
    operatorSnapshot.value = snapshotWithKeepers([
      { name: 'paused-one', status: 'offline', phase: 'paused', pipeline_stage: 'paused' },
      { name: 'offline-one', status: 'offline', phase: 'offline' },
    ])

    render(h(ComposerV2, { workspaceId: 'ops' }))
    fireEvent.click(screen.getByRole('button', { name: 'DM mode' }))

    const select = screen.getByLabelText('Composer v2 keeper target') as HTMLSelectElement
    const options = Array.from(select.options).map(option => option.textContent).filter(label => label !== 'Keeper')
    expect(options).toContain('paused-one')
    expect(options).not.toContain('offline-one')
  })

  it('uses execution keepers as a fallback when operator snapshot targets are empty', () => {
    operatorSnapshot.value = null
    dashboardKeepers.value = [
      keeperFixture({ name: 'fallback-a', status: 'running' }),
      keeperFixture({ name: 'fallback-paused', status: 'offline', phase: 'Paused', paused: true }),
      keeperFixture({ name: 'fallback-offline', status: 'offline', phase: 'Offline' }),
    ]

    render(h(ComposerV2, { workspaceId: 'ops' }))
    fireEvent.click(screen.getByRole('button', { name: 'DM mode' }))

    expect(screen.getByText('0 chars · no files · 2 keeper targets')).toBeInTheDocument()
    const select = screen.getByLabelText('Composer v2 keeper target') as HTMLSelectElement
    const options = Array.from(select.options)
      .map(option => option.textContent)
      .filter(label => label !== 'Keeper')
    expect(options).toEqual(['fallback-a', 'fallback-paused'])
    expect(select.value).toBe('keeper:fallback-a')
  })

})
