import { describe, it, expect } from 'vitest'
import { resolveKeeperToolPolicy } from './keeper-detail-source'
import type { KeeperConfig } from '../types'

// ================================================================
// resolveKeeperToolPolicy
// ================================================================

describe('resolveKeeperToolPolicy', () => {
  it('returns keeper_config source when tools present', () => {
    const config = {
      tools: {
        tool_denylist: ['dangerous'],
        resolved_allowlist: ['bash', 'read', 'custom_tool'],
      },
    } as unknown as Pick<KeeperConfig, 'tools'>
    const result = resolveKeeperToolPolicy(config, 'loaded')
    expect(result.source).toBe('keeper_config')
    expect(result.resolvedAllowlist).toEqual(['bash', 'read', 'custom_tool'])
  })

  it('returns loading source for idle status', () => {
    const result = resolveKeeperToolPolicy(null, 'idle')
    expect(result.source).toBe('loading')
  })

  it('returns loading source for loading status', () => {
    const result = resolveKeeperToolPolicy(null, 'loading')
    expect(result.source).toBe('loading')
  })

  it('returns error source for error status', () => {
    const result = resolveKeeperToolPolicy(null, 'error')
    expect(result.source).toBe('error')
  })

  it('returns none source for other status without tools', () => {
    const result = resolveKeeperToolPolicy(null, 'other')
    expect(result.source).toBe('none')
  })

  it('returns none source for loaded status without tools', () => {
    const result = resolveKeeperToolPolicy(null, 'loaded')
    expect(result.source).toBe('none')
  })

  it('defaults resolved allowlist to an empty array when missing', () => {
    const config = {
      tools: {
        tool_access: {},
      },
    } as unknown as Pick<KeeperConfig, 'tools'>
    const result = resolveKeeperToolPolicy(config, 'loaded')
    expect(result.resolvedAllowlist).toEqual([])
  })

  it('prefers tools over load status', () => {
    const config = {
      tools: {
        tool_access: {},
      },
    } as unknown as Pick<KeeperConfig, 'tools'>
    // Even with error status, tools present means keeper_config
    const result = resolveKeeperToolPolicy(config, 'error')
    expect(result.source).toBe('keeper_config')
  })
})
