import { afterEach, describe, expect, it, vi } from 'vitest'

import {
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

  it('labels typed next actions without warning', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})

    expect(nextHumanActionLabel('inspect_turn_budget')).toBe('턴 예산 소진 원인 확인')
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
