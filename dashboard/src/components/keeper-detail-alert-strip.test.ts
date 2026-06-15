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

  it('renders runtime execution evidence even when the attention flag is false', () => {
    const { container } = render(h(KeeperRuntimeAlertStrip, {
      keeper: keeper({
        needs_attention: false,
        trust: {
          execution_summary: {
            runtime_outcome: 'fallback_exhausted',
            provider_attempt_count: 2,
          },
        },
      }),
    }))

    expect(container.textContent).toContain('마지막 시도')
    expect(container.textContent).toContain('fallback_exhausted')
  })

  it('renders trust failure without tool-contract sibling evidence', () => {
    const { container } = render(h(KeeperRuntimeAlertStrip, {
      keeper: keeper({
        needs_attention: true,
        trust: {
          disposition: 'Alert',
          attention_reason: 'completion_contract_violation',
        },
      }),
    }))

    const text = container.textContent ?? ''
    expect(text).toContain('검증')
    expect(text).not.toContain('completion_contract_violation')
    expect(text).not.toContain('증명')
  })

  it('canonicalizes runtime attention tokens before rendering operator copy', () => {
    const { container } = render(h(KeeperRuntimeAlertStrip, {
      keeper: keeper({
        needs_attention: true,
        attention_reason: 'watchdog_stale_turn',
        next_human_action: 'inspect_watchdog_root_cause',
      }),
    }))

    const text = container.textContent ?? ''
    expect(text).toContain('런타임 근거 확인 필요')
    expect(text).not.toContain('watchdog_stale_turn')
    expect(text).not.toContain('inspect_watchdog_root_cause')
  })

  // Lock the remaining producer-side attention reasons that
  // [canonicalAttentionReason] folds into runtime_blocked. Producers
  // live at Keeper_status_bridge.ml:782/784/791 (runtime_attempts_exhausted,
  // provider_tool_capability_missing, fiber_unresolved). The previous
  // canonicalizes-* it() blocks already cover watchdog_stale_turn and
  // completion_contract_violation; this parametrises the rest. The
  // rendered Korean copy "런타임 근거 확인 필요" is the user-visible label
  // mapped from runtime_blocked in ATTENTION_REASON_LABELS.
  it.each([
    'runtime_attempts_exhausted',
    'provider_tool_capability_missing',
    'fiber_unresolved',
  ])('canonicalizes %s into runtime_blocked operator copy', (reason) => {
    const { container } = render(h(KeeperRuntimeAlertStrip, {
      keeper: keeper({
        needs_attention: true,
        attention_reason: reason,
      }),
    }))

    const text = container.textContent ?? ''
    expect(text).toContain('런타임 근거 확인 필요')
    expect(text).not.toContain(reason)
  })

  it('canonicalizes turn-disposition timeout actions before rendering operator copy', () => {
    const { container } = render(h(KeeperRuntimeAlertStrip, {
      keeper: keeper({
        needs_attention: true,
        next_human_action: 'inspect_turn_timeout',
      }),
    }))

    const text = container.textContent ?? ''
    expect(text).toContain('런타임 근거 확인')
    expect(text).not.toContain('inspect_turn_timeout')
  })

  it('labels provider runtime error tokens from the live keeper status surface', () => {
    const { container } = render(h(KeeperRuntimeAlertStrip, {
      keeper: keeper({
        needs_attention: true,
        attention_reason: 'provider_runtime_error',
        next_human_action: 'inspect_provider_runtime_cause',
      }),
    }))

    const text = container.textContent ?? ''
    expect(text).toContain('런타임 호출 오류')
    expect(text).toContain('Provider 런타임 원인 확인')
    expect(text).not.toContain('provider_runtime_error')
    expect(text).not.toContain('inspect_provider_runtime_cause')
  })

  it('labels direct latest-error inspection actions from the live keeper status surface', () => {
    const { container } = render(h(KeeperRuntimeAlertStrip, {
      keeper: keeper({
        needs_attention: true,
        next_human_action: 'inspect_latest_error',
      }),
    }))

    const text = container.textContent ?? ''
    expect(text).toContain('최근 오류 확인')
    expect(text).not.toContain('inspect_latest_error')
  })

  // Lock the remaining producer-side action wires that
  // [canonicalNextHumanAction] folds into inspect_runtime_blocker. Each
  // wire here has a live producer in lib/keeper (see
  // Keeper_turn_disposition.next_action and Keeper_status_bridge), so
  // dropping any rewrite branch silently in a future sweep would leak
  // the raw legacy label into operator copy. The previous
  // canonicalizes-* it() blocks already cover inspect_watchdog_root_cause
  // and inspect_turn_timeout.
  it.each([
    'inspect_runtime_attempts',
    'inspect_provider_tool_lane',
    'inspect_completion_contract',
    'inspect_turn_finalization',
  ])('canonicalizes %s into inspect_runtime_blocker operator copy', (action) => {
    const { container } = render(h(KeeperRuntimeAlertStrip, {
      keeper: keeper({
        needs_attention: true,
        next_human_action: action,
      }),
    }))

    const text = container.textContent ?? ''
    expect(text).toContain('런타임 근거 확인')
    expect(text).not.toContain(action)
  })

  it('closes 모순 #3: per-attempt completed outcome is hidden when per-turn stop cause is terminal failure', () => {
    const { container } = render(h(KeeperRuntimeAlertStrip, {
      keeper: keeper({
        stop_cause: {
          code: 'turn_timeout',
          source: 'runtime_blocker_class',
          label: 'Turn timeout',
          summary: 'turn wall clock exceeded before completion',
        },
        trust: {
          execution_summary: {
            runtime_outcome: 'completed',
            provider_attempt_count: 1,
          },
        },
      }),
    }))

    const text = container.textContent ?? ''
    // Per-turn stop cause is rendered through the canonical terminal code.
    expect(text).toContain('정지 원인')
    expect(text).toContain('turn_timeout')
    expect(text).toContain('turn_timeout')
    // Per-attempt success is gated out so the strip no longer shows
    // "런타임 레인 · completed" next to "정지 원인 · turn_timeout".
    expect(text).not.toContain('런타임 레인')
    expect(text).not.toContain('마지막 시도')
  })

  it('renders per-attempt observation under scope label when no terminal turn failure', () => {
    const { container } = render(h(KeeperRuntimeAlertStrip, {
      keeper: keeper({
        trust: {
          execution_summary: {
            runtime_outcome: 'completed',
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
        runtime_blocker_class: 'turn_timeout',
        runtime_blocker_summary: 'Turn timeout fired before resume.',
      }),
    }))

    expect(container.textContent).toContain('일시정지')
    expect(container.textContent).toContain('일시정지 원인')
    expect(container.textContent).toContain('턴 응답 만료')
    expect(container.textContent).toContain('Turn timeout fired before resume.')
    expect(container.textContent).not.toContain('OAS budget timeout fired before the keeper hard timeout.')
    expect(container.textContent).toContain('원인 확인 후 재개')
    expect(container.textContent).not.toContain('런타임 차단')
    expect(container.textContent).not.toContain('주의 사유 · paused')
  })

  it('uses lifecycle action visibility SSOT for phase-only paused keepers', () => {
    const { container } = render(h(KeeperRuntimeAlertStrip, {
      keeper: keeper({
        phase: 'Paused',
        paused: false,
        needs_attention: true,
        runtime_blocker_class: 'turn_timeout',
      }),
    }))

    const text = container.textContent ?? ''
    expect(text).toContain('재개하기')
    expect(text).not.toContain('일시정지하기')
    expect(text).not.toContain('깨우기')
  })

  it('uses lifecycle action visibility SSOT to show wake for non-paused blocked keepers', () => {
    const { container } = render(h(KeeperRuntimeAlertStrip, {
      keeper: keeper({
        phase: 'Running',
        paused: false,
        needs_attention: true,
        runtime_blocker_class: 'turn_timeout',
      }),
    }))

    const text = container.textContent ?? ''
    expect(text).toContain('일시정지하기')
    expect(text).toContain('깨우기')
    expect(text).not.toContain('재개하기')
  })
})
