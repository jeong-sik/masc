import { afterEach, describe, expect, it, vi } from 'vitest'

import bridgeAttention from '../api/fixtures/keeper-attention-reasons.json'
import trustDisposition from '../api/fixtures/keeper-trust-disposition-reasons.json'
import {
  ATTENTION_REASONS,
  NEXT_HUMAN_ACTIONS,
  attentionReasonLabel,
  nextHumanActionLabel,
} from './keeper-attention-labels'

afterEach(() => {
  vi.restoreAllMocks()
})

describe('keeper attention labels', () => {
  it('labels transient runtime retry without warning', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})

    expect(attentionReasonLabel('transient_runtime_retry', false)).toBe('일시적 런타임 재시도')
    expect(warn).not.toHaveBeenCalled()
  })

  it('labels a fenced provider effect without exposing the raw token', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})

    expect(attentionReasonLabel('provider_attempt_effect_fenced', false)).toBe(
      'Provider 효과 결과 확인 필요',
    )
    expect(warn).not.toHaveBeenCalled()
  })

  it('labels official-client recovery without exposing the raw token', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})

    expect(attentionReasonLabel('official_client_recovery_required', false)).toBe(
      '공식 클라이언트 세션 복구 필요',
    )
    expect(warn).not.toHaveBeenCalled()
  })

  it('labels a runtime blocker class the trust snapshot names as the reason', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})

    expect(attentionReasonLabel('heartbeat_failures', false)).toBe('하트비트 실패')
    expect(attentionReasonLabel('turn_failures', false)).toBe('턴 실패 반복')
    expect(attentionReasonLabel('turn_configuration_error', false)).toBe('실행 설정 오류')
    expect(attentionReasonLabel('exception', false)).toBe('런타임 예외')
    expect(attentionReasonLabel('operator_interrupt', false)).toBe('운영자가 턴을 멈춤')
    expect(warn).not.toHaveBeenCalled()
  })

  it('labels typed next actions without warning', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})

    expect(nextHumanActionLabel('inspect_latest_error')).toBe('최근 오류 확인')
    expect(warn).not.toHaveBeenCalled()
  })

  it('keeps unknown reasons visible and warned', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})

    expect(attentionReasonLabel('future_state', false)).toBe(
      'future_state',
    )
    expect(warn).toHaveBeenCalledWith(
      '[keeper-attention-labels] unknown attention_reason:',
      'future_state',
    )
  })
})

describe('keeper attention vocabularies', () => {
  // test_keeper_attention_reason pins this fixture to every reason the
  // status bridge writes. These lists are wider (trust and goal surfaces add
  // their own), so they must contain the fixture rather than equal it.
  it('label every attention reason the status bridge writes', () => {
    const known: readonly string[] = ATTENTION_REASONS
    expect(bridgeAttention.attention_reasons.filter(reason => !known.includes(reason))).toEqual([])
  })

  it('label every first action the status bridge writes', () => {
    const known: readonly string[] = NEXT_HUMAN_ACTIONS
    expect(bridgeAttention.next_human_actions.filter(action => !known.includes(action))).toEqual([])
  })

  // test_keeper_trust_disposition_reason pins this fixture to every string the
  // trust snapshot writes as a disposition reason: its own reasons, each
  // runtime blocker class and each receipt reason. A reason is labelled when
  // the label function knows it, so a string it only echoes back fails here.
  it('label every disposition reason the trust snapshot writes', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})

    expect(
      trustDisposition.disposition_reasons.filter(
        reason => attentionReasonLabel(reason, false) === reason,
      ),
    ).toEqual([])
    expect(warn).not.toHaveBeenCalled()
  })
})
