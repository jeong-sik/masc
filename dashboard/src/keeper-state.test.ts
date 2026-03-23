import { describe, expect, it } from 'vitest'
import {
  isVisibleDirectConversationEntry,
  normalizeStatusDetail,
} from './keeper-state'

describe('normalizeStatusDetail', () => {
  it('infers and hides internal keeper history from direct comms', () => {
    const detail = normalizeStatusDetail('sangsu', '', {
      history_tail: [
        {
          role: 'user',
          content:
            '## Current World State\n\n### Room State\n- Failed tasks: 9\n- Active agents: 5\n\n### Context\n- Utilization: 72%\n- Idle: 132s',
          ts_unix: 10,
        },
        {
          role: 'assistant',
          content: '9개 실패 태스크가 계속되는데 왜 이걸로 하냐니? 그냥 고치거나 무시하거냐.',
          ts_unix: 11,
        },
        {
          role: 'user',
          source: 'direct_user',
          content: '지금 상태 어때?',
          ts_unix: 20,
        },
        {
          role: 'assistant',
          source: 'direct_assistant',
          content: '직접 상태는 괜찮고, 대화 UI만 정리하면 됩니다.',
          ts_unix: 21,
        },
      ],
    })

    expect(detail.history.map(entry => entry.source)).toEqual([
      'world_state_prompt',
      'internal_assistant',
      'direct_user',
      'direct_assistant',
    ])
    expect(detail.history.filter(isVisibleDirectConversationEntry).map(entry => entry.text)).toEqual([
      '지금 상태 어때?',
      '직접 상태는 괜찮고, 대화 UI만 정리하면 됩니다.',
    ])
  })

  it('keeps explicit direct history visible', () => {
    const detail = normalizeStatusDetail('sangsu', '', {
      history_tail: [
        {
          role: 'user',
          source: 'direct_user',
          content: 'ping',
          ts_unix: 30,
        },
        {
          role: 'assistant',
          source: 'direct_assistant',
          content: 'pong',
          ts_unix: 31,
        },
      ],
    })

    expect(detail.history.every(isVisibleDirectConversationEntry)).toBe(true)
  })
})
