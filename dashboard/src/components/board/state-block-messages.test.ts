import { h } from 'preact'
import { cleanup, render, screen } from '@testing-library/preact'
import { afterEach, describe, expect, it } from 'vitest'
import { StateBlockMessages, buildStateBlockRows, extractStateBlocks, stateBlockFields } from './state-block-messages'
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

describe('state block message helpers', () => {
  it('extracts complete state blocks from message content', () => {
    expect(extractStateBlocks('hello [STATE]\nGoal: ship\nNext: verify\n[/STATE] bye')).toEqual([
      'Goal: ship\nNext: verify',
    ])
  })

  it('ignores incomplete state blocks', () => {
    expect(extractStateBlocks('hello [STATE]\nGoal: missing end')).toEqual([])
  })

  it('parses state block fields into label/value rows', () => {
    expect(stateBlockFields('Goal: ship\nProgress: 80%\nloose line\nNext: review')).toEqual([
      { label: 'Goal', value: 'ship' },
      { label: 'Progress', value: '80%' },
      { label: 'Next', value: 'review' },
    ])
  })

  it('builds newest-first rows and strips messages without state payloads', () => {
    const rows = buildStateBlockRows([
      message({ id: 'plain', content: 'plain text', seq: 1 }),
      message({ id: 'old', content: '[STATE]\nGoal: older\n[/STATE]', seq: 2, timestamp: '2026-05-06T02:00:00Z' }),
      message({ id: 'new', content: '[STATE]\nGoal: newer\n[/STATE]', seq: 3, timestamp: '2026-05-06T04:00:00Z' }),
    ])

    expect(rows.map(row => row.message.id)).toEqual(['new', 'old'])
    expect(rows[0]?.fields).toEqual([{ label: 'Goal', value: 'newer' }])
  })
})

describe('StateBlockMessages', () => {
  afterEach(() => {
    cleanup()
    messages.value = []
  })

  it('renders state payloads separately from the human preview', async () => {
    messages.value = [
      message({
        id: 'state-1',
        from: 'nick0cave',
        seq: 8,
        content: 'status changed\n[STATE]\nGoal: restore room\nNext: notify sangsu\n[/STATE]\nready',
      }),
    ]

    render(h(StateBlockMessages, null))

    expect(screen.getByRole('heading', { name: 'State-block messages' })).toBeInTheDocument()
    expect(await screen.findByText('status changed')).toBeInTheDocument()
    expect(screen.getByText('Goal')).toBeInTheDocument()
    expect(screen.getByText('restore room')).toBeInTheDocument()
    expect(screen.getByText('Next')).toBeInTheDocument()
    expect(screen.getByText('notify sangsu')).toBeInTheDocument()
  })

  it('shows an empty state when no messages carry state blocks', () => {
    messages.value = [message({ id: 'plain', content: '@dashboard no state here' })]

    render(h(StateBlockMessages, null))

    expect(screen.getByText('state block 메시지가 없습니다')).toBeInTheDocument()
  })
})
