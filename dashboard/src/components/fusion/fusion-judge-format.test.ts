import { describe, expect, it } from 'vitest'
import {
  judgeShapeLabel,
  judgeRoleLabel,
  judgeNodeTokenLabel,
  judgeNodeIdentity,
  judgeNodeElapsedLabel,
} from './fusion-judge-format'
import type { FusionJudgeNode } from '../../lib/fusion-meta'

function node(partial: Partial<FusionJudgeNode>): FusionJudgeNode {
  return { role: 'first', identity: 'gpt-5', failed: false, ...partial }
}

describe('judgeShapeLabel', () => {
  it('maps every shape to its Korean label', () => {
    expect(judgeShapeLabel('single')).toBe('단일 심판')
    expect(judgeShapeLabel('refine')).toBe('재검토')
    expect(judgeShapeLabel('judge-of-judges')).toBe('심판의 심판')
    expect(judgeShapeLabel('custom')).toBe('심판 위상')
  })
})

describe('judgeRoleLabel', () => {
  it('maps every role of the closed six-role backend enum', () => {
    expect(judgeRoleLabel('first')).toBe('1차')
    expect(judgeRoleLabel('meta')).toBe('메타')
    expect(judgeRoleLabel('refine')).toBe('재검토')
    expect(judgeRoleLabel('single')).toBe('단일')
    // staged JoJ reducers — previously fell through to the raw latin role string
    expect(judgeRoleLabel('stage_meta')).toBe('단계 심판')
    expect(judgeRoleLabel('final_meta')).toBe('최종 심판')
  })
  it('falls through to the raw string for an unanticipated role', () => {
    expect(judgeRoleLabel('arbiter')).toBe('arbiter')
  })
})

describe('judgeNodeElapsedLabel', () => {
  it('returns null when the node carries no timing', () => {
    expect(judgeNodeElapsedLabel(node({}))).toBeNull()
  })
  it('formats the elapsed seconds to one decimal', () => {
    expect(judgeNodeElapsedLabel(node({ failed: true, elapsedS: 4.12 }))).toBe('4.1s')
    expect(judgeNodeElapsedLabel(node({ failed: true, elapsedS: 0 }))).toBe('0.0s')
  })
})

describe('judgeNodeTokenLabel', () => {
  it('renders an em-dash when there is no usage', () => {
    expect(judgeNodeTokenLabel(node({}))).toBe('—')
    expect(judgeNodeTokenLabel(node({ inputTokens: 0, outputTokens: 0 }))).toBe('—')
  })
  it('sums input + output, plain figure below 1000', () => {
    expect(judgeNodeTokenLabel(node({ inputTokens: 120, outputTokens: 300 }))).toBe('420 tok')
  })
  it('k-formats to one decimal at or above 1000', () => {
    expect(judgeNodeTokenLabel(node({ inputTokens: 400, outputTokens: 1200 }))).toBe('1.6k tok')
  })
})

describe('judgeNodeIdentity', () => {
  it('keeps an identity that differs from the role (the panelist_id on `first`)', () => {
    expect(judgeNodeIdentity(node({ role: 'first', identity: 'gpt-5' }))).toBe('gpt-5')
  })
  it('suppresses an identity that merely echoes the role', () => {
    expect(judgeNodeIdentity(node({ role: 'meta', identity: 'meta' }))).toBeNull()
    expect(judgeNodeIdentity(node({ role: 'single', identity: 'single' }))).toBeNull()
  })
  it('suppresses an empty identity', () => {
    expect(judgeNodeIdentity(node({ role: 'first', identity: '' }))).toBeNull()
  })
})
