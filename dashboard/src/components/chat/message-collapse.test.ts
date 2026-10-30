// @vitest-environment happy-dom
//
// The fold used to hang off the plain-text body alone, so a message carrying
// any non-thinking block rendered through ChatBlocks with no way to fold it —
// which is most keeper output. What is asserted here is only observable after a
// render: a long block-carrying message offers the control, and a short one
// does not.
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import type { ChatBlock, KeeperConversationEntry } from '../../types'
import { ChatTranscript } from './primitives'

const paragraph = (text: string): ChatBlock =>
  ({ t: 'p', html: text }) as ChatBlock

const withBlocks = (blocks: ChatBlock[]): KeeperConversationEntry =>
  ({
    id: 'm1',
    role: 'assistant',
    source: 'direct_user',
    label: 'keeper',
    text: '',
    blocks,
    delivery: 'history',
    timestamp: '2026-08-25T09:00:00Z',
  }) as KeeperConversationEntry

describe('ChatTranscript — folding a block-rendered body', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  const draw = (entry: KeeperConversationEntry) => {
    render(
      html`<${ChatTranscript}
        entries=${[entry]}
        emptyText="대화 없음"
        showDayDividers=${false}
        groupToolCalls=${true}
        unreadAfterTs=${null}
        expandAutonomousRuns=${false}
      />`,
      container,
    )
  }

  const foldControl = (): HTMLElement | undefined =>
    Array.from(container.querySelectorAll('button')).find(button => {
      const label = button.textContent?.trim()
      return label === '더 보기' || label === '접기'
    })

  it('offers the fold on a long block-rendered body', () => {
    draw(withBlocks([paragraph('가'.repeat(4000))]))
    expect(foldControl()).toBeDefined()
  })

  it('leaves a short block-rendered body alone', () => {
    draw(withBlocks([paragraph('짧은 한 줄')]))
    expect(foldControl()).toBeUndefined()
  })

  it('counts every block, not just the first', () => {
    const many = Array.from({ length: 40 }, (_, index) =>
      paragraph(`문단 ${index} ${'가'.repeat(60)}`),
    )
    draw(withBlocks(many))
    expect(foldControl()).toBeDefined()
  })
})
