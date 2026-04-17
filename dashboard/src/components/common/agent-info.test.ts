import { describe, it, expect } from 'vitest'
import { extractAgentInfo } from './agent-info'

describe('extractAgentInfo', () => {
  it('extracts keeper runtime for keeper- prefix', () => {
    const info = extractAgentInfo('keeper-janitor')
    expect(info).toEqual({ model: 'keeper runtime', nickname: 'janitor', isKeeper: true })
  })

  it('extracts keeper runtime for keeper-dm-keeper-agent', () => {
    const info = extractAgentInfo('keeper-dm-keeper-agent')
    expect(info).toEqual({ model: 'keeper runtime', nickname: 'dm-keeper-agent', isKeeper: true })
  })

  it('extracts model and nickname from standard agent name', () => {
    const info = extractAgentInfo('opus-leader-witty-heron')
    expect(info).toEqual({ model: 'opus', nickname: 'leader-witty-heron', isKeeper: false })
  })

  it('handles single-segment name', () => {
    const info = extractAgentInfo('claude')
    expect(info).toEqual({ model: 'claude', nickname: 'claude', isKeeper: false })
  })

  it('handles gemini prefix', () => {
    const info = extractAgentInfo('gemini-analyst-calm-dolphin')
    expect(info).toEqual({ model: 'gemini', nickname: 'analyst-calm-dolphin', isKeeper: false })
  })

  it('detects keeper as single word', () => {
    const info = extractAgentInfo('keeper')
    expect(info).toEqual({ model: 'keeper', nickname: 'keeper', isKeeper: true })
  })

  it('detects keeper model in two-segment name', () => {
    const info = extractAgentInfo('keeper-sentinel')
    // keeper- prefix is handled first → returns 'keeper runtime'
    expect(info.isKeeper).toBe(true)
  })

  it('handles empty string', () => {
    const info = extractAgentInfo('')
    expect(info).toEqual({ model: '', nickname: '', isKeeper: false })
  })

  it('handles name with only dash', () => {
    const info = extractAgentInfo('-suffix')
    expect(info.model).toBe('')
    expect(info.nickname).toBe('suffix')
  })
})
