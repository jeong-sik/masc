import { h } from 'preact'
import { cleanup, render } from '@testing-library/preact'
import { afterEach, describe, expect, it } from 'vitest'
import '@testing-library/jest-dom'

import type { Keeper } from '../types'
import { KeeperRuntimeAlertStrip } from './keeper-detail-alert-strip'

afterEach(() => {
  cleanup()
})

function keeper(overrides: Partial<Keeper> = {}): Keeper {
  return {
    name: 'quiet-keeper',
    status: 'active',
    ...overrides,
  }
}

describe('KeeperRuntimeAlertStrip', () => {
  it('stays hidden for a quiet keeper without runtime evidence', () => {
    const { container } = render(h(KeeperRuntimeAlertStrip, { keeper: keeper({ needs_attention: false }) }))

    expect(container).toBeEmptyDOMElement()
  })

  it('renders execution receipt evidence even when the attention flag is false', () => {
    const { container } = render(h(KeeperRuntimeAlertStrip, {
      keeper: keeper({
        needs_attention: false,
        trust: {
          execution_summary: {
            tool_contract_result: 'missing_required_tool_use',
            required_tools: ['keeper_task_done'],
            missing_required_tools: ['keeper_task_done'],
          },
        },
      }),
    }))

    expect(container.textContent).toContain('증명')
    expect(container.textContent).toContain('missing_required_tool_use')
    expect(container.textContent).toContain('필요 도구')
    expect(container.textContent).toContain('keeper_task_done')
    expect(container.textContent).toContain('누락')
  })

  it('separates paused state from runtime blocker evidence', () => {
    const { container } = render(h(KeeperRuntimeAlertStrip, {
      keeper: keeper({
        paused: true,
        keepalive_running: true,
        needs_attention: true,
        attention_reason: 'paused',
        next_human_action: 'inspect_blocker_before_resume',
        runtime_blocker_class: 'oas_timeout_budget',
        runtime_blocker_summary: 'OAS budget timeout fired before the keeper hard timeout.',
      }),
    }))

    expect(container.textContent).toContain('일시정지')
    expect(container.textContent).toContain('일시정지 원인')
    expect(container.textContent).toContain('OAS budget timeout fired before the keeper hard timeout.')
    expect(container.textContent).toContain('원인 확인 후 재개')
    expect(container.textContent).not.toContain('런타임 차단')
    expect(container.textContent).not.toContain('주의 사유 · paused')
  })
})
