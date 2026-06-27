import { afterEach, describe, expect, it, vi } from 'vitest'

import {
  attentionReasonLabel,
  completionContractAttentionReasonLabel,
} from './keeper-attention-labels'

afterEach(() => {
  vi.restoreAllMocks()
})

describe('keeper attention labels', () => {
  it('labels known completion-contract composite reasons without warning', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})

    expect(completionContractAttentionReasonLabel('completion_contract_result:passive_only')).toBe('수동 응답만 있음')
    expect(attentionReasonLabel('completion_contract_result:passive_only', false)).toBe('수동 응답만 있음')
    expect(warn).not.toHaveBeenCalled()
  })

  it('labels known bare completion-contract tokens without warning', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    expect(completionContractAttentionReasonLabel('passive_only')).toBe('수동 응답만 있음')
    expect(attentionReasonLabel('passive_only', false)).toBe('수동 응답만 있음')
    expect(warn).not.toHaveBeenCalled()
  })

  it('labels transient runtime retry without warning', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})

    expect(attentionReasonLabel('transient_runtime_retry', false)).toBe('일시적 런타임 재시도')
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
