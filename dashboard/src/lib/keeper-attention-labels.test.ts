import { afterEach, describe, expect, it, vi } from 'vitest'

import {
  attentionReasonLabel,
  completionContractAttentionReasonLabel,
  nextHumanActionLabel,
} from './keeper-attention-labels'

afterEach(() => {
  vi.restoreAllMocks()
})

describe('keeper attention labels', () => {
  it('labels known completion-contract composite reasons without warning', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})

    expect(completionContractAttentionReasonLabel('completion_contract_result:passive_only')).toBe('진행 작업 없는 수동 응답')
    expect(attentionReasonLabel('completion_contract_result:passive_only', false)).toBe('진행 작업 없는 수동 응답')
    expect(attentionReasonLabel('completion_contract_result:no_capable_provider', false)).toBe('사용 가능한 provider 없음')
    expect(warn).not.toHaveBeenCalled()
  })

  it('labels known bare completion-contract tokens without warning', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    expect(completionContractAttentionReasonLabel('passive_only')).toBe('진행 작업 없는 수동 응답')
    expect(attentionReasonLabel('passive_only', false)).toBe('진행 작업 없는 수동 응답')
    expect(warn).not.toHaveBeenCalled()
  })

  it('labels transient runtime retry without warning', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})

    expect(attentionReasonLabel('transient_runtime_retry', false)).toBe('일시적 런타임 재시도')
    expect(warn).not.toHaveBeenCalled()
  })

  it('labels completion-contract next actions without warning', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})

    expect(nextHumanActionLabel('inspect_completion_contract')).toBe('완료 계약 상태 확인')
    expect(nextHumanActionLabel('resume_or_inspect_completion_contract')).toBe('재개 또는 완료 계약 확인')
    expect(nextHumanActionLabel('inspect_turn_budget')).toBe('턴 예산 소진 원인 확인')
    expect(warn).not.toHaveBeenCalled()
  })

  it('keeps unknown completion-contract composite reasons visible and warned', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})

    expect(completionContractAttentionReasonLabel('completion_contract_result:future_state')).toBeNull()
    expect(attentionReasonLabel('completion_contract_result:future_state', false)).toBe(
      'completion_contract_result:future_state',
    )
    expect(warn).toHaveBeenCalledWith(
      '[keeper-attention-labels] unknown attention_reason:',
      'completion_contract_result:future_state',
    )
  })
})
