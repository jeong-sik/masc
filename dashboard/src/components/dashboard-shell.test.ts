// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import {
  githubCommitUrl,
  currentSectionShareUrl,
  formatUptimeSecondsHuman,
  deriveBreadcrumbTrail,
} from './dashboard-shell'

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

describe('formatUptimeSecondsHuman (pure)', () => {
  it('null / undefined → "알 수 없음"', () => {
    expect(formatUptimeSecondsHuman(null)).toBe('알 수 없음')
    expect(formatUptimeSecondsHuman(undefined)).toBe('알 수 없음')
  })

  it('NaN → "알 수 없음" (no "NaNs" in the dropdown)', () => {
    expect(formatUptimeSecondsHuman(Number.NaN)).toBe('알 수 없음')
  })

  it('negative → "알 수 없음" (no "-5s" — clock skew guard)', () => {
    expect(formatUptimeSecondsHuman(-5)).toBe('알 수 없음')
  })

  it('sub-minute → "Xs" compact', () => {
    expect(formatUptimeSecondsHuman(3)).toBe('3s')
    expect(formatUptimeSecondsHuman(45)).toBe('45s')
  })

  it('sub-hour → "Xm Ys" compact', () => {
    expect(formatUptimeSecondsHuman(125)).toBe('2m 5s')
    expect(formatUptimeSecondsHuman(3599)).toBe('59m 59s')
  })

  it('hour+ → "Xh Ym" compact (regression over the raw "3600s" pre-fix)', () => {
    // The whole point of this helper: 3600 stopped reading as
    // "3600s" (cognitive load) and now reads as "1h 0m".
    expect(formatUptimeSecondsHuman(3600)).toBe('1h 0m')
    expect(formatUptimeSecondsHuman(9000)).toBe('2h 30m')
    expect(formatUptimeSecondsHuman(86_400)).toBe('24h 0m')
  })

  it('zero seconds → "0s" (fresh boot, still valid)', () => {
    expect(formatUptimeSecondsHuman(0)).toBe('0s')
  })
})

describe('deriveBreadcrumbTrail (pure)', () => {
  it('both null → [] (home / unknown, no crumb)', () => {
    expect(deriveBreadcrumbTrail(null, null, null)).toEqual([])
  })

  it('tab only, no section → single non-navigable crumb (standing on tab default)', () => {
    // A newcomer on \"Connectors\" default view sees \"Connectors\" as
    // the title already; duplicating it in a crumb above would be
    // pure noise, so the SurfaceLead consumer hides the trail in
    // this case — the pure helper still returns a single crumb so
    // other callers (e.g. future titlebar) can render it.
    expect(deriveBreadcrumbTrail('Connectors', null, 'connectors')).toEqual([
      { label: 'Connectors', navigableTab: null },
    ])
  })

  it('section only, no tab → single non-navigable crumb with section label', () => {
    expect(deriveBreadcrumbTrail(null, 'Discord', null)).toEqual([
      { label: 'Discord', navigableTab: null },
    ])
  })

  it('drilldown: tab + section → parent crumb navigable, leaf not', () => {
    // The parent tab is clickable so operator can bounce back up to
    // the grid; the leaf is where we currently stand, so clicking it
    // would be a no-op (marked non-navigable).
    expect(deriveBreadcrumbTrail('Connectors', 'Discord', 'connectors')).toEqual([
      { label: 'Connectors', navigableTab: 'connectors' },
      { label: 'Discord', navigableTab: null },
    ])
  })

  it('drilldown without tab id → parent crumb still rendered, but non-navigable', () => {
    // Regression guard: a section-only route that somehow doesn't
    // carry the parent tab id should still show the parent label,
    // just without a clickable link. Never throws.
    expect(deriveBreadcrumbTrail('Connectors', 'Discord', null)).toEqual([
      { label: 'Connectors', navigableTab: null },
      { label: 'Discord', navigableTab: null },
    ])
  })
})
