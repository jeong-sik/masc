// @vitest-environment happy-dom
import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  connectKeeperCursorPush,
  getKeeperColor,
  normalizeKeeperCursorSnapshot,
} from './keeper-cursor-overlay'

afterEach(() => {
  vi.useRealTimers()
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
  window.sessionStorage.clear()
})

describe('getKeeperColor', () => {
  it('maps explicit indexes to design-system keeper token slots', () => {
    expect(getKeeperColor('alpha', 0)).toMatchObject({
      slot: 1,
      cursor: 'var(--color-keeper-1)',
      glow: 'var(--color-keeper-1-glow)',
      selection: 'rgb(var(--color-keeper-1-glow) / 0.22)',
      text: 'var(--color-bg-page)',
    })
    expect(getKeeperColor('alpha', 11).cursor).toBe('var(--color-keeper-12)')
    expect(getKeeperColor('alpha', 12).cursor).toBe('var(--color-keeper-1)')
  })

  it('uses token references for hashed keeper ids instead of raw colors', () => {
    const color = getKeeperColor('nick0cave')
    expect(color.slot).toBeGreaterThanOrEqual(1)
    expect(color.slot).toBeLessThanOrEqual(12)
    expect(color.cursor).toMatch(/^var\(--color-keeper-\d+\)$/)
    expect(color.selection).toMatch(/^rgb\(var\(--color-keeper-\d+-glow\) \/ 0\.22\)$/)
    expect(`${color.cursor} ${color.selection} ${color.shadow}`).not.toMatch(/#[0-9a-fA-F]{3,8}|rgba\(/)
  })

  it('ignores presence-only snapshots without cursor fields', () => {
    const overlay = normalizeKeeperCursorSnapshot({
      runtime_id: 'masc-runtime',
      entries: [{
        keeper_id: 'sangsu',
        workspace_label: 'masc-mcp',
        branch: 'main',
        role: 'keeper',
        status: 'active',
        last_seen_ms: Date.now(),
      }],
    })

    expect(overlay.cursors.size).toBe(0)
    expect(overlay.active_file).toBeNull()
  })

  it('normalizes cursor snapshots with positive line positions', () => {
    const overlay = normalizeKeeperCursorSnapshot({
      runtime_id: 'masc-runtime',
      cursors: [{
        keeper_id: 'sangsu',
        file_path: 'lib/a.ml',
        line: 24,
        column: 2,
        focus_mode: 'editing',
        last_update: Date.now(),
        tool_name: 'keeper_ide_annotate',
        turn: 7,
      }],
    })

    expect(overlay.active_file).toBe('lib/a.ml')
    expect(overlay.cursors.get('sangsu')).toMatchObject({
      file_path: 'lib/a.ml',
      line: 24,
      focus_mode: 'editing',
      tool_name: 'keeper_ide_annotate',
      turn: 7,
    })
  })

  it('loads the initial cursor snapshot over the typed API', async () => {
    const fetchMock = vi.fn(async (_input: RequestInfo | URL) => new Response(JSON.stringify({
      ok: true,
      data: {
        runtime_id: 'masc-runtime',
        connected: true,
        cursors: [{
          keeper_id: 'sangsu',
          file_path: 'lib/a.ml',
          line: 24,
          column: 2,
          focus_mode: 'editing',
          last_update: Date.now(),
        }],
      },
    }), { status: 200, headers: { 'content-type': 'application/json' } }))
    vi.stubGlobal('fetch', fetchMock)
    const onUpdate = vi.fn()
    const onStatus = vi.fn()

    const cleanup = connectKeeperCursorPush(onUpdate, { codebase: 'github.com_jeong-sik_masc', onStatus })

    await vi.waitFor(() => expect(onUpdate).toHaveBeenCalledWith(expect.objectContaining({
      active_file: 'lib/a.ml',
    })))
    expect(String(fetchMock.mock.calls[0]?.[0])).toContain('/api/v1/ide/cursors?codebase=github.com_jeong-sik_masc')
    expect(onStatus).toHaveBeenLastCalledWith(expect.objectContaining({
      status: 'live',
      failedCount: 0,
    }))

    cleanup()
    expect(onStatus).toHaveBeenLastCalledWith({ status: 'closed', failedCount: 0 })
  })

  it('reports typed snapshot refresh failures without a fallback transport', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {})
    vi.stubGlobal('fetch', vi.fn(async () => new Response('unavailable', { status: 503 })))
    const onStatus = vi.fn()

    const cleanup = connectKeeperCursorPush(() => {}, { onStatus })

    await vi.waitFor(() => expect(onStatus).toHaveBeenLastCalledWith(expect.objectContaining({
      status: 'degraded',
      failedCount: 1,
      lastErrorMs: expect.any(Number),
    })))
    cleanup()
  })
})
