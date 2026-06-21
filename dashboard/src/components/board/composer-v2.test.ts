import { h } from 'preact'
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
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
    pending_confirms: [],
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
  it('keeps the compose shape required by the C3 contract', () => {
    expect(buildComposerV2Request({
      mode: 'state-block',
      workspaceId: '#ops',
      body: '[STATE]\nGoal: ship\nNEXT: verify\n[/STATE]',
    })).toEqual({
      compose: {
        mode: 'state-block',
        target: { workspace_id: 'ops' },
        body: {
          kind: 'state-block',
          raw: '[STATE]\nGoal: ship\nNEXT: verify\n[/STATE]',
          keys: ['Goal', 'NEXT'],
        },
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
    dashboardKeepers.value = []
  })

  afterEach(() => {
    cleanup()
    operatorSnapshot.value = null
    operatorActionBusy.value = false
    dashboardKeepers.value = []
    vi.clearAllMocks()
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

  it('sends attachment-only drafts through the current text transport', async () => {
    render(h(ComposerV2, { workspaceId: 'ops' }))

    fireEvent.change(screen.getByTestId('composer-v2-file-input'), {
      target: { files: [new File(['body'], 'trace.log', { type: 'text/plain' })] },
    })

    expect(screen.getByTestId('composer-v2-tray')).toHaveTextContent('trace.log')
    expect(screen.getByTestId('composer-v2-tray')).toHaveTextContent('text/plain')
    expect(screen.getByTestId('composer-v2-command-rail')).toHaveTextContent('1 file')
    fireEvent.click(screen.getByRole('button', { name: 'Send' }))

    await waitFor(() => {
      expect(sendBroadcastMock).toHaveBeenCalledWith(
        'dashboard-test',
        'Attachments:\n- trace.log (4 B · file)',
      )
    })
    expect(screen.queryByTestId('composer-v2-tray')).not.toBeInTheDocument()
  })

  it('captures a voice draft and serializes it into the current text transport', async () => {
    render(h(ComposerV2, { workspaceId: 'ops' }))

    fireEvent.click(screen.getByRole('button', { name: 'Start voice draft' }))
    expect(screen.getByTestId('composer-v2-recorder')).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: /완료/ }))
    expect(screen.getByTestId('composer-v2-tray')).toHaveTextContent('받아쓰기')

    fireEvent.click(screen.getByRole('button', { name: 'Send' }))

    await waitFor(() => {
      expect(sendBroadcastMock).toHaveBeenCalledWith(
        'dashboard-test',
        expect.stringContaining('Voice memo 0:12 (40 KB)'),
      )
    })
    expect(sendBroadcastMock).toHaveBeenCalledWith(
      'dashboard-test',
      expect.stringContaining('스케줄러 p99 스파이크와 compact 타이밍을 비교해서 결과만 알려줘.'),
    )
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

  it('requires a parsed state block before state sends', async () => {
    render(h(ComposerV2, { workspaceId: 'merge-blockers' }))

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
