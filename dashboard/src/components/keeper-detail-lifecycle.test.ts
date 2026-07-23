import { fireEvent, render } from '@testing-library/preact'
import { html } from 'htm/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'

const { runKeeperAction } = vi.hoisted(() => ({
  runKeeperAction: vi.fn(),
}))

vi.mock('./keeper-action-panel', () => ({
  KEEPER_ACTION_LABELS: {
    resume: { title: 'resume', verb: '재개하기' },
    boot: { title: 'boot', verb: '기동하기' },
    shutdown: { title: 'shutdown', verb: '종료하기' },
  },
  runKeeperAction,
}))

import { KeeperLifecycleButtons } from './keeper-detail-lifecycle'
import type { Keeper } from '../types'

describe('KeeperLifecycleButtons', () => {
  afterEach(() => {
    document.body.innerHTML = ''
    runKeeperAction.mockReset()
  })

  it('resumes an offline paused keeper with its durable owner generation', () => {
    const keeper = {
      name: 'sangsu',
      status: 'offline',
      phase: 'Paused',
      paused: true,
      keepalive_running: false,
      generation: 2570,
    } as Keeper

    const { getByRole, queryByText } = render(html`
      <${KeeperLifecycleButtons} keeper=${keeper} effectiveStatus="offline" />
    `)

    fireEvent.click(getByRole('button', { name: '재개하기' }))

    expect(queryByText('기동하기')).toBeNull()
    expect(runKeeperAction).toHaveBeenCalledWith('sangsu', 'resume', 2570)
  })
})
