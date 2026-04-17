import { describe, it, expect } from 'vitest'
import { githubCommitUrl } from './dashboard-shell'

describe('githubCommitUrl (pure)', () => {
  it('returns null for null / undefined / empty string', () => {
    expect(githubCommitUrl(null)).toBeNull()
    expect(githubCommitUrl(undefined)).toBeNull()
    expect(githubCommitUrl('')).toBeNull()
    expect(githubCommitUrl('   ')).toBeNull()
  })

  it('returns null for non-hex-looking strings (dev labels, semver, free text)', () => {
    // Regression guard: dev builds produce label strings like "dev" or
    // "v1.2.3-dirty"; we must NOT link them to
    // github.com/.../commit/dev (a 404).
    expect(githubCommitUrl('dev')).toBeNull()
    expect(githubCommitUrl('v1.2.3')).toBeNull()
    expect(githubCommitUrl('v1.2.3-dirty')).toBeNull()
    expect(githubCommitUrl('not-a-commit')).toBeNull()
  })

  it('rejects too-short hex (< 7 chars) — ambiguous, could collide', () => {
    // Git's default `--short` is 7. Anything under that is almost
    // never a real commit reference.
    expect(githubCommitUrl('abc123')).toBeNull()
    expect(githubCommitUrl('a1b2c3')).toBeNull()
  })

  it('accepts a 7-char short hex hash', () => {
    expect(githubCommitUrl('abc1234')).toBe(
      'https://github.com/jeong-sik/masc-mcp/commit/abc1234',
    )
  })

  it('accepts a full 40-char hex hash', () => {
    const sha = 'a'.repeat(40)
    expect(githubCommitUrl(sha)).toBe(
      `https://github.com/jeong-sik/masc-mcp/commit/${sha}`,
    )
  })

  it('accepts uppercase hex (some tooling emits uppercase)', () => {
    expect(githubCommitUrl('ABC1234')).toBe(
      'https://github.com/jeong-sik/masc-mcp/commit/ABC1234',
    )
  })

  it('rejects > 40 chars (not a real SHA)', () => {
    expect(githubCommitUrl('a'.repeat(41))).toBeNull()
  })

  it('trims surrounding whitespace before validating', () => {
    expect(githubCommitUrl('  abc1234  ')).toBe(
      'https://github.com/jeong-sik/masc-mcp/commit/abc1234',
    )
  })
})
