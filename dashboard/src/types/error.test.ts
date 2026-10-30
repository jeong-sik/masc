import { describe, it, expect } from 'vitest'
import { ERROR_DOMAINS, parseErrorDomain, severityFor } from './error'
import type { ErrorDomain } from './error'

describe('parseErrorDomain', () => {
  it.each(ERROR_DOMAINS)('accepts the modelled domain %s', domain => {
    expect(parseErrorDomain(domain)).toBe(domain)
  })

  it('mirrors Agent_core.Error.category_label exactly', () => {
    // packages/agent_core/lib/base/error.ml — category_label
    expect([...ERROR_DOMAINS]).toEqual([
      'api',
      'provider',
      'agent',
      'mcp',
      'config',
      'serialization',
      'io',
      'orchestration',
      'internal',
    ])
  })

  it.each([
    'unknown',
    'exception',
    'fiber_unresolved',
    'operator_interrupt',
    'validation_error',
    '',
  ])('returns null for %s rather than defaulting', raw => {
    expect(parseErrorDomain(raw)).toBeNull()
  })
})

describe('severityFor', () => {
  it.each(ERROR_DOMAINS)('a retryable %s failure is a warning', domain => {
    expect(severityFor(domain, true)).toBe('warning')
  })

  it.each(ERROR_DOMAINS)('a non-retryable %s failure is critical', domain => {
    expect(severityFor(domain, false)).toBe('critical')
  })

  it('an unmodelled domain is critical whatever the retryable flag says', () => {
    expect(severityFor(null, true)).toBe('critical')
    expect(severityFor(null, false)).toBe('critical')
  })

  it('covers every domain the type admits', () => {
    const seen = new Set<ErrorDomain>(ERROR_DOMAINS)
    expect(seen.size).toBe(ERROR_DOMAINS.length)
  })
})
