import { describe, it, expect } from 'vitest'
import { normalizeKeeperName, matchesKeeper } from './agent-detail-memory'

describe('normalizeKeeperName', () => {
  it('removes keeper- prefix', () => {
    expect(normalizeKeeperName('keeper-janitor')).toBe('janitor')
  })

  it('removes -agent suffix', () => {
    expect(normalizeKeeperName('sentinel-agent')).toBe('sentinel')
  })

  it('removes both keeper- prefix and -agent suffix', () => {
    expect(normalizeKeeperName('keeper-dreamer-agent')).toBe('dreamer')
  })

  it('leaves plain name unchanged', () => {
    expect(normalizeKeeperName('janitor')).toBe('janitor')
  })

  it('handles empty string', () => {
    expect(normalizeKeeperName('')).toBe('')
  })

  it('does not remove inner keeper or agent', () => {
    expect(normalizeKeeperName('my-keeper-bot')).toBe('my-keeper-bot')
    expect(normalizeKeeperName('agent-007')).toBe('agent-007')
  })

  it('handles name that is just the prefix', () => {
    expect(normalizeKeeperName('keeper-')).toBe('')
  })

  it('handles name that is just the suffix', () => {
    // '-agent' → replace /^keeper-/ → '-agent' → replace /-agent$/ → ''
    expect(normalizeKeeperName('-agent')).toBe('')
  })
})

describe('matchesKeeper', () => {
  it('matches identical names', () => {
    expect(matchesKeeper('janitor', 'janitor')).toBe(true)
  })

  it('matches with different prefix/suffix patterns', () => {
    expect(matchesKeeper('keeper-janitor', 'janitor')).toBe(true)
    expect(matchesKeeper('janitor', 'keeper-janitor')).toBe(true)
    expect(matchesKeeper('keeper-janitor', 'janitor-agent')).toBe(true)
    expect(matchesKeeper('keeper-dreamer-agent', 'dreamer')).toBe(true)
  })

  it('does not match different names', () => {
    expect(matchesKeeper('janitor', 'sentinel')).toBe(false)
    expect(matchesKeeper('keeper-janitor', 'keeper-sentinel')).toBe(false)
  })

  it('handles empty strings', () => {
    expect(matchesKeeper('', '')).toBe(true)
    expect(matchesKeeper('keeper-', '')).toBe(true)
    expect(matchesKeeper('', 'keeper-')).toBe(true)
  })

  it('is case-sensitive', () => {
    expect(matchesKeeper('Janitor', 'janitor')).toBe(false)
  })
})
