import { h } from 'preact'
import { cleanup, fireEvent, render, screen } from '@testing-library/preact'
import { afterEach, describe, expect, it } from 'vitest'
import { MessageRoomTimeline, buildMessageRoomModel } from './message-room-timeline'
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

describe('message room timeline helpers', () => {
  it('groups messages by room and defaults roomless payloads to execution', () => {
    const model = buildMessageRoomModel([
      message({ id: 'm-1', room: 'ops', content: 'ops note', seq: 2 }),
      message({ id: 'm-2', content: 'runtime note', seq: 1 }),
      message({ id: 'm-3', room: '#ops', content: '@dashboard [STATE]\nGoal: ship\n[/STATE]', seq: 3 }),
    ])

    expect(model.rooms.map(room => room.room)).toEqual(['execution', 'ops'])
    expect(model.rooms.find(room => room.room === 'ops')?.rows.map(row => row.message.id)).toEqual(['m-1', 'm-3'])
    expect(model.totalMentions).toBe(1)
    expect(model.totalStateBlocks).toBe(1)
  })
})

describe('MessageRoomTimeline', () => {
  afterEach(() => {
    cleanup()
    messages.value = []
  })

  it('renders room tabs and switches the visible timeline', async () => {
    messages.value = [
      message({ id: 'm-1', room: 'ops', from: 'sojin', content: 'ops first', seq: 1 }),
      message({ id: 'm-2', room: 'review', from: 'ani', content: '@dashboard review needed', seq: 2 }),
    ]

    render(h(MessageRoomTimeline, null))

    expect(screen.getByRole('heading', { name: 'Room timeline' })).toBeInTheDocument()
    expect(screen.getByRole('tab', { name: /#ops/ })).toHaveAttribute('aria-selected', 'true')
    expect(await screen.findByText('ops first')).toBeInTheDocument()

    fireEvent.click(screen.getByRole('tab', { name: /#review/ }))

    expect(screen.getByRole('tab', { name: /#review/ })).toHaveAttribute('aria-selected', 'true')
    expect(await screen.findByText(/review needed/)).toBeInTheDocument()
    expect(screen.getByText('@dashboard')).toBeInTheDocument()
  })

  it('shows state counts on timeline rows', () => {
    messages.value = [
      message({ id: 'm-state', room: 'ops', content: '[STATE]\nGoal: keep context\n[/STATE]', seq: 1 }),
    ]

    render(h(MessageRoomTimeline, null))

    expect(screen.getByText('STATE 1')).toBeInTheDocument()
  })
})
