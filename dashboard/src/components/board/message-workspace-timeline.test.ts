// @vitest-environment jsdom
import { h } from 'preact'
import { cleanup, fireEvent, render, screen } from '@testing-library/preact'
import { afterEach, describe, expect, it } from 'vitest'
import { MessageWorkspaceTimeline, buildMessageWorkspaceModel } from './message-workspace-timeline'
import { messages } from '../../store'
import type { Message } from '../../types'

import '@testing-library/jest-dom'

function message(overrides: Partial<Message> & { content: string }): Message {
  const { content, ...rest } = overrides
  return {
    from: 'keeper',
    content,
    timestamp: '2026-05-06T03:00:00Z',
    ...rest,
  }
}

describe('message workspace timeline helpers', () => {
  it('groups messages by workspace and defaults workspaceless payloads to execution', () => {
    const model = buildMessageWorkspaceModel([
      message({ id: 'm-1', workspace: 'ops', content: 'ops note', seq: 2 }),
      message({ id: 'm-2', content: 'runtime note', seq: 1 }),
      message({ id: 'm-3', workspace: '#ops', content: '@dashboard ship', seq: 3 }),
    ])

    expect(model.workspaces.map(workspace => workspace.workspace)).toEqual(['execution', 'ops'])
    expect(model.workspaces.find(workspace => workspace.workspace === 'ops')?.rows.map(row => row.message.id)).toEqual(['m-1', 'm-3'])
    expect(model.totalMentions).toBe(1)
  })
})

describe('MessageWorkspaceTimeline', () => {
  afterEach(() => {
    cleanup()
    messages.value = []
  })

  it('renders workspace tabs and switches the visible timeline', async () => {
    messages.value = [
      message({ id: 'm-1', workspace: 'ops', from: 'sojin', content: 'ops first', seq: 1 }),
      message({ id: 'm-2', workspace: 'review', from: 'ani', content: '@dashboard review needed', seq: 2 }),
    ]

    render(h(MessageWorkspaceTimeline, null))

    expect(screen.getByRole('heading', { name: 'Workspace timeline' })).toBeInTheDocument()
    expect(screen.getByRole('tab', { name: /#ops/ })).toHaveAttribute('aria-selected', 'true')
    expect(screen.getByLabelText('Target workspace: ops')).toBeInTheDocument()
    expect(await screen.findByText('ops first')).toBeInTheDocument()

    fireEvent.click(screen.getByRole('tab', { name: /#review/ }))

    expect(screen.getByRole('tab', { name: /#review/ })).toHaveAttribute('aria-selected', 'true')
    expect(screen.getByLabelText('Target workspace: review')).toBeInTheDocument()
    expect(await screen.findByText(/review needed/)).toBeInTheDocument()
    expect(screen.getByText('@dashboard')).toBeInTheDocument()
  })

})
