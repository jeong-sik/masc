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

    // Tool contract result is now rendered as scope-tagged evidence
    // ("도구 계약") attached to a single typed verdict, using the Korean
    // label from `toolContractLabel`. The prior sibling "증명" span and
    // its raw English token are intentionally removed (모순 #2).
    expect(container.textContent).toContain('도구 계약')
    expect(container.textContent).toContain('필수 도구 호출 누락')
    expect(container.textContent).not.toContain('증명')
    expect(container.textContent).toContain('필요 도구')
    expect(container.textContent).toContain('keeper_task_done')
    expect(container.textContent).toContain('누락')
  })

  it('closes 모순 #2: simultaneous failure verdict + tool-contract success collapse into one verdict', () => {
    const { container } = render(h(KeeperRuntimeAlertStrip, {
      keeper: keeper({
        needs_attention: true,
        trust: {
          disposition: 'Alert',
          attention_reason: 'timeout_budget_exhausted',
          execution_summary: {
            tool_contract_result: 'satisfied_execution',
          },
        },
      }),
    }))

    const text = container.textContent ?? ''
    // Verdict failure is surfaced under a single "검증" label.
    expect(text).toContain('검증')
    expect(text).toContain('timeout_budget_exhausted')
    // The tool contract success is preserved but tagged as scope
    // evidence ("도구 계약"), not as a sibling "증명" claim that would
    // read as the surface contradicting itself.
    expect(text).toContain('도구 계약')
    expect(text).toContain('계약 충족 (실행)')
    expect(text).not.toContain('증명')
  })

  it('closes 모순 #3: per-attempt completed outcome is hidden when per-turn stop cause is terminal failure', () => {
    const { container } = render(h(KeeperRuntimeAlertStrip, {
      keeper: keeper({
        stop_cause: {
          code: 'oas_timeout_budget',
          source: 'runtime_blocker_class',
          label: 'OAS timeout budget',
          summary: 'budget exhausted before turn completion',
        },
        trust: {
          execution_summary: {
            tool_contract_result: 'satisfied_execution',
            cascade_outcome: 'completed',
            provider_attempt_count: 1,
          },
        },
      }),
    }))

    const text = container.textContent ?? ''
    // Per-turn stop cause is still rendered.
    expect(text).toContain('정지 원인')
    expect(text).toContain('oas_timeout_budget')
    // Per-attempt success is gated out so the strip no longer shows
    // "런타임 레인 · completed" next to "정지 원인 · oas_timeout_budget".
    expect(text).not.toContain('런타임 레인')
    expect(text).not.toContain('마지막 시도')
  })

  it('renders per-attempt observation under scope label when no terminal turn failure', () => {
    const { container } = render(h(KeeperRuntimeAlertStrip, {
      keeper: keeper({
        trust: {
          execution_summary: {
            cascade_outcome: 'completed',
            provider_attempt_count: 2,
            provider_fallback_applied: true,
          },
        },
      }),
    }))

    const text = container.textContent ?? ''
    // Without a terminal turn failure, the attempt outcome surfaces
    // but is scope-tagged ("마지막 시도") rather than the generic
    // "런타임 레인" so the operator does not mistake a per-attempt
    // outcome for a per-turn verdict.
    expect(text).toContain('마지막 시도')
    expect(text).toContain('completed')
    expect(text).toContain('2회 시도')
    expect(text).toContain('폴백')
    expect(text).not.toContain('런타임 레인')
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
