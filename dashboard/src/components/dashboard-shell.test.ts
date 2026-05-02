// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import {
  githubCommitUrl,
  currentSectionShareUrl,
  formatUptimeSecondsHuman,
  deriveBreadcrumbTrail,
  composeDocumentTitle,
  describeReconnecting,
  dashboardRouteBoundaryKey,
  summarizeAttentionPreview,
  composeHealthIndicatorTitle,
  composeBuildBadgeTitle,
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
    window.history.pushState({}, '', '/?tab=connectors&section=connector-status&connector=discord')
    expect(currentSectionShareUrl()).toContain('?tab=connectors&section=connector-status&connector=discord')
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

describe('dashboardRouteBoundaryKey (pure)', () => {
  it('keeps the agents directory on the stable section key', () => {
    expect(dashboardRouteBoundaryKey({
      tab: 'monitoring',
      params: { section: 'agents' },
      postId: null,
    })).toBe('monitoring:agents')
  })

  it('keys keeper detail separately from the agents directory', () => {
    const directoryKey = dashboardRouteBoundaryKey({
      tab: 'monitoring',
      params: { section: 'agents' },
      postId: null,
    })
    const keeperKey = dashboardRouteBoundaryKey({
      tab: 'monitoring',
      params: { section: 'agents', keeper: 'analyst' },
      postId: null,
    })

    expect(keeperKey).toBe('monitoring:agents:keeper=analyst')
    expect(keeperKey).not.toBe(directoryKey)
  })

  it('keys agent profile detail separately from keeper detail', () => {
    expect(dashboardRouteBoundaryKey({
      tab: 'monitoring',
      params: { section: 'agents', agent: 'sangsu' },
      postId: null,
    })).toBe('monitoring:agents:agent=sangsu')
  })

  it('includes structural view and trace identifiers without using noisy filters', () => {
    expect(dashboardRouteBoundaryKey({
      tab: 'monitoring',
      params: {
        section: 'runtime',
        view: 'inspector',
        q: 'typing-filter',
        session_id: 'sess-1',
        operation_id: 'op-1',
        worker_run_id: 'worker-1',
      },
      postId: null,
    })).toBe('monitoring:runtime:view=inspector:session=sess-1:operation=op-1:worker=worker-1')
  })
})

describe('formatUptimeSecondsHuman (pure)', () => {
  it('null / undefined -> "Unknown"', () => {
    expect(formatUptimeSecondsHuman(null)).toBe('Unknown')
    expect(formatUptimeSecondsHuman(undefined)).toBe('Unknown')
  })

  it('NaN -> "Unknown" (no "NaNs" in the dropdown)', () => {
    expect(formatUptimeSecondsHuman(Number.NaN)).toBe('Unknown')
  })

  it('negative -> "Unknown" (no "-5s" clock skew guard)', () => {
    expect(formatUptimeSecondsHuman(-5)).toBe('Unknown')
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

describe('composeDocumentTitle (pure)', () => {
  it('both null → fallback to default brand title', () => {
    expect(composeDocumentTitle(null, null)).toBe('MASC Dashboard')
  })

  it('whitespace-only labels fall back to default (no ghost \"MASC · \")', () => {
    expect(composeDocumentTitle('   ', null)).toBe('MASC Dashboard')
    expect(composeDocumentTitle(null, '   ')).toBe('MASC Dashboard')
  })

  it('tab only → \"MASC · {tab}\"', () => {
    expect(composeDocumentTitle('Connectors', null)).toBe('MASC · Connectors')
  })

  it('section only → \"MASC · {section}\"', () => {
    expect(composeDocumentTitle(null, 'Discord')).toBe('MASC · Discord')
  })

  it('section takes precedence over tab (deeper drill wins the tab title)', () => {
    // The rationale: if an operator has 4 tabs open — Connectors,
    // Connectors/Discord, Connectors/Slack, Monitoring — the browser
    // tab list should distinguish the three Connectors-variants by
    // their leaf section, not repeat \"MASC · Connectors\" three times.
    expect(composeDocumentTitle('Connectors', 'Discord')).toBe('MASC · Discord')
  })

  it('returned string always starts with \"MASC\" brand prefix (or is plain brand on fallback)', () => {
    // Regression guard: a future refactor must not accidentally drop
    // the brand prefix — operators scanning the browser tab bar look
    // for \"MASC\" first.
    const titles = [
      composeDocumentTitle('Connectors', 'Discord'),
      composeDocumentTitle('Connectors', null),
      composeDocumentTitle(null, null),
    ]
    for (const t of titles) expect(t.startsWith('MASC')).toBe(true)
  })
})

describe('describeReconnecting (pure)', () => {
  it('disconnectedAt=0 -> bare "Reconnecting..." label, empty title', () => {
    // Fresh page load / never disconnected state: nothing to show
    // yet. Regression guard: no ghost \"0s\" suffix.
    const r = describeReconnecting({ disconnectedAt: 0, now: 1_000_000, reconnects: 0 })
    expect(r.label).toBe('Reconnecting...')
    expect(r.title).toBe('')
  })

  it('sub-5s disconnect → suppress elapsed (flicker noise floor)', () => {
    // Discord / Slack both debounce reconnect UI — a 2-second blip
    // shouldn't yank the operator's attention with a running timer.
    const now = 10_000_000
    const r = describeReconnecting({ disconnectedAt: now - 2_000, now, reconnects: 0 })
    expect(r.label).toBe('Reconnecting')
    // Title also suppresses the disconnect timestamp below 5s since
    // the elapsed reading itself isn't shown.
    expect(r.title).toBe('')
  })

  it('5–59s disconnect → compact seconds suffix', () => {
    const now = 10_000_000
    const r = describeReconnecting({ disconnectedAt: now - 15_000, now, reconnects: 0 })
    expect(r.label).toBe('Reconnecting · 15s')
  })

  it('≥60s disconnect → rounded-[var(--r-1)] minutes', () => {
    const now = 10_000_000
    const r = describeReconnecting({ disconnectedAt: now - 125_000, now, reconnects: 0 })
    // 125s → 2m (Math.round)
    expect(r.label).toBe('Reconnecting · 2m')
  })

  it('title includes disconnect timestamp + cumulative reconnect count', () => {
    // Regression guard: operator diagnosing a reconnect loop needs
    // both "when did we lose it" and "how many times have we
    // bounced so far" - drop either and the badge loses its
    // diagnostic value.
    const now = 10_000_000
    const r = describeReconnecting({
      disconnectedAt: now - 30_000,
      now,
      reconnects: 3,
    })
    expect(r.title).toMatch(/Disconnected at \d{2}:\d{2}:\d{2}/)
    expect(r.title).toContain('Reconnect attempts 3')
  })

  it('reconnects=0 suppresses the cumulative counter (no "Reconnect attempts 0")', () => {
    // \"Zero reconnects so far\" is the expected state for the first
    // disconnect — printing it as \"0회\" is noise, not signal.
    const now = 10_000_000
    const r = describeReconnecting({ disconnectedAt: now - 30_000, now, reconnects: 0 })
    expect(r.title).not.toContain('Reconnect attempts 0')
    expect(r.title).not.toContain('Reconnect attempts')
  })

  it('clock skew (now < disconnectedAt) → floors elapsed to 0, no negative display', () => {
    // Regression guard: system-clock drift between browser tab and
    // NTP-resynced OS can briefly produce now < disconnectedAt.
    // We must not render "Reconnecting · -3s".
    const now = 10_000_000
    const r = describeReconnecting({
      disconnectedAt: now + 3_000,
      now,
      reconnects: 0,
    })
    expect(r.label).toBe('Reconnecting')
    expect(r.label).not.toContain('-')
  })
})

describe('summarizeAttentionPreview (pure)', () => {
  it('empty list → empty preview (health dot reads green with no tooltip clutter)', () => {
    expect(summarizeAttentionPreview([])).toEqual([])
  })

  it('uses item.summary when available', () => {
    const items = [
      { summary: 'CI gate failed on main', kind: 'ci_failure' },
      { summary: 'Session 42 blocker: network timeout', kind: 'session_blocker' },
    ]
    expect(summarizeAttentionPreview(items)).toEqual([
      'CI gate failed on main',
      'Session 42 blocker: network timeout',
    ])
  })

  it('falls back to kind when summary is empty / null / undefined', () => {
    // Backend occasionally sends a kind without a summary (e.g., a
    // new attention_kind not yet narrativized). Showing the kind string
    // is strictly better than dropping the item silently.
    const items = [
      { summary: null, kind: 'keeper_silence' },
      { summary: '', kind: 'config_drift' },
      { kind: 'untyped_event' },
    ]
    expect(summarizeAttentionPreview(items)).toEqual([
      'keeper_silence',
      'config_drift',
      'untyped_event',
    ])
  })

  it('skips items with no summary AND no kind (pure noise)', () => {
    const items = [
      { summary: 'Real issue', kind: 'real' },
      { summary: null, kind: null },
      { summary: '', kind: '' },
      { summary: 'Another', kind: 'x' },
    ]
    expect(summarizeAttentionPreview(items)).toEqual(['Real issue', 'Another'])
  })

  it('truncates over-long lines at 60 chars with ellipsis', () => {
    // Regression guard: a 500-char blocker_summary dumped into title
    // would render as a wall of wrapped text in the native tooltip —
    // operators want a hint, not an essay.
    const long = 'x'.repeat(200)
    const [line] = summarizeAttentionPreview([{ summary: long, kind: 'bulk' }])
    expect(line).not.toBeUndefined()
    expect(line!.length).toBeLessThanOrEqual(60)
    expect(line!.endsWith('...')).toBe(true)
  })

  it('respects max=3 and appends a remaining-count tail when there are more', () => {
    const items = Array.from({ length: 7 }, (_, i) => ({
      summary: `item-${i}`,
      kind: 'generic',
    }))
    const preview = summarizeAttentionPreview(items, 3)
    expect(preview.slice(0, 3)).toEqual(['item-0', 'item-1', 'item-2'])
    // 7 - 3 = 4 more
    expect(preview[3]).toBe('... +4 more')
  })

  it('no tail when we rendered every item (exact fit)', () => {
    const items = [
      { summary: 'a', kind: 'k' },
      { summary: 'b', kind: 'k' },
    ]
    const preview = summarizeAttentionPreview(items, 3)
    expect(preview).toEqual(['a', 'b'])
    expect(preview.some(l => l.startsWith('... +'))).toBe(false)
  })
})

describe('composeHealthIndicatorTitle (pure)', () => {
  it('no attention lines → bare label (tooltip stays terse when state is boring)', () => {
    expect(composeHealthIndicatorTitle('Healthy', [])).toBe('Healthy')
    expect(composeHealthIndicatorTitle('Offline', [])).toBe('Offline')
  })

  it('label on line 1, attention items indented beneath', () => {
    const title = composeHealthIndicatorTitle('Attention 2', ['foo blocker', 'bar gate fail'])
    expect(title).toBe('Attention 2\n  · foo blocker\n  · bar gate fail')
  })

  it('newlines (not <br>) — native title tooltips render \\n verbatim on Chrome/Safari/Firefox', () => {
    // Regression guard: a well-meaning future refactor might swap \n
    // for <br> thinking this is an HTML attribute. Title is plain text;
    // <br> would render as literal "<br>" in the tooltip.
    const title = composeHealthIndicatorTitle('Attention 1', ['x'])
    expect(title.split('\n')).toHaveLength(2)
    expect(title).not.toContain('<br>')
  })
})

describe('composeBuildBadgeTitle (pure)', () => {
  it('no build / no fallback -> "Build unavailable" (matches existing label)', () => {
    expect(composeBuildBadgeTitle(null, null)).toBe('Build unavailable')
    expect(composeBuildBadgeTitle(undefined, undefined)).toBe('Build unavailable')
    expect(composeBuildBadgeTitle(null, '')).toBe('Build unavailable')
  })

  it('fallback version only → uses it + "dev" suffix (loose build info)', () => {
    const t = composeBuildBadgeTitle(null, '0.9.13')
    expect(t).toContain('Server build')
    expect(t).toContain('· v0.9.13 · dev')
    expect(t).toContain('Click for details')
  })

  it('full build (version + commit + uptime) → all three lines', () => {
    const t = composeBuildBadgeTitle(
      { release_version: '0.9.13', commit: 'a8b7412a3', uptime_seconds: 9000 },
      null,
    )
    expect(t).toContain('· v0.9.13 · a8b7412a3')
    // 9000s → 2h 30m per formatUptimeSecondsHuman
    expect(t).toContain('Uptime 2h 30m')
    expect(t).toContain('Click for details')
  })

  it('unknown uptime (null / negative) -> skips the Uptime line (no ghost "Unknown")', () => {
    // Regression guard: we explicitly filter out the "unknown" sentinel
    // so the hover tooltip stays compact during pre-boot / clock-skew.
    const t = composeBuildBadgeTitle(
      { release_version: '0.9.13', commit: 'abc1234', uptime_seconds: null },
      null,
    )
    expect(t).not.toContain('Uptime')
    expect(t).not.toContain('Unknown')
  })

  it('newline separated (native title tooltip plain text)', () => {
    // Same contract as composeHealthIndicatorTitle — never emit <br>;
    // this is a title attribute, not HTML markup.
    const t = composeBuildBadgeTitle(
      { release_version: '0.9.13', commit: 'abc1234', uptime_seconds: 60 },
      null,
    )
    expect(t).not.toContain('<br>')
    expect(t.split('\n').length).toBeGreaterThanOrEqual(3)
  })

  it('commit missing / empty → " · dev" suffix (not " · undefined")', () => {
    const t1 = composeBuildBadgeTitle({ release_version: '0.9.13', commit: null }, null)
    const t2 = composeBuildBadgeTitle({ release_version: '0.9.13', commit: '' }, null)
    for (const t of [t1, t2]) {
      expect(t).toContain('· v0.9.13 · dev')
      expect(t).not.toContain('undefined')
      expect(t).not.toContain('null')
    }
  })
})
