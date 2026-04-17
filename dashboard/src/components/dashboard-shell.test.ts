// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { githubCommitUrl, currentSectionShareUrl } from './dashboard-shell'

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

describe('currentSectionShareUrl (pure)', () => {
  const originalHref = typeof window !== 'undefined' ? window.location.href : ''

  beforeEach(() => {
    if (typeof window !== 'undefined') {
      window.history.pushState({}, '', '/')
    }
  })

  afterEach(() => {
    if (typeof window !== 'undefined') {
      window.history.pushState({}, '', originalHref)
    }
  })

  it('returns window.location.href when available', () => {
    window.history.pushState({}, '', '/?tab=connectors&section=connector-discord')
    expect(currentSectionShareUrl()).toContain('?tab=connectors&section=connector-discord')
  })

  it('preserves hash fragments (router hash-based flow)', () => {
    window.history.pushState({}, '', '/#section=discord')
    const url = currentSectionShareUrl()
    expect(url).toContain('#section=discord')
  })

  it('returns the full absolute URL (not a relative path) — paste-into-Slack safety', () => {
    // Regression guard: callers paste this into Slack / docs — relative
    // paths would land the reader on the wrong origin.
    const url = currentSectionShareUrl()
    expect(url.startsWith('http')).toBe(true)
  })

  it('returns empty string when window is undefined (SSR guard)', () => {
    const windowSpy = vi.spyOn(globalThis, 'window', 'get')
    windowSpy.mockReturnValue(undefined as unknown as Window & typeof globalThis)
    try {
      expect(currentSectionShareUrl()).toBe('')
    } finally {
      windowSpy.mockRestore()
    }
  })
})
