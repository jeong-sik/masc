import { describe, expect, it } from 'vitest'
import { keeperChatTargetName } from './agent-profile'

describe('keeperChatTargetName', () => {
  it('prefers the canonical keeper name over the runtime agent name', () => {
    expect(
      keeperChatTargetName('keeper-tool-test-agent', { name: 'tool-test' }),
    ).toBe('tool-test')
  })

  it('falls back to the provided name when no keeper mapping exists', () => {
    expect(keeperChatTargetName('plain-agent', null)).toBe('plain-agent')
  })
})
