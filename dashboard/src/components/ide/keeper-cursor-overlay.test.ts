// @vitest-environment happy-dom
import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  connectKeeperCursorStream,
  getKeeperColor,
  keeperCursorStreamUrl,
  normalizeKeeperCursorSnapshot,
} from './keeper-cursor-overlay'

afterEach(() => {
  vi.useRealTimers()
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
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

  it('connects to the dedicated cursor stream endpoint', () => {
    const instances: Array<{
      readonly url: string
      onmessage: ((event: MessageEvent) => void) | null
      onerror: ((event: Event) => void) | null
      close: () => void
    }> = []
    class MockEventSource {
      onmessage: ((event: MessageEvent) => void) | null = null
      onerror: ((event: Event) => void) | null = null
      readonly url: string

      constructor(url: string) {
        this.url = url
        instances.push(this)
      }

      close = vi.fn()
    }
    vi.stubGlobal('EventSource', MockEventSource)

    const cleanup = connectKeeperCursorStream('http://localhost:8935', () => {})

    expect(instances[0]?.url).toBe('http://localhost:8935/api/v1/ide/cursors/stream')
    cleanup()
    expect(instances[0]?.close).toHaveBeenCalled()
  })

  it('builds repository-scoped cursor stream URLs', () => {
    expect(keeperCursorStreamUrl('http://localhost:8935', { repoId: 'masc' }))
      .toBe('http://localhost:8935/api/v1/ide/cursors/stream?repo_id=masc')
  })

  it('cancels cursor stream reconnect timers during cleanup', () => {
    vi.useFakeTimers()
    vi.spyOn(Math, 'random').mockReturnValue(0)
    vi.spyOn(console, 'error').mockImplementation(() => {})
    const instances: Array<{
      readonly url: string
      onmessage: ((event: MessageEvent) => void) | null
      onerror: ((event: Event) => void) | null
      close: () => void
    }> = []
    class MockEventSource {
      onmessage: ((event: MessageEvent) => void) | null = null
      onerror: ((event: Event) => void) | null = null
      readonly url: string

      constructor(url: string) {
        this.url = url
        instances.push(this)
      }

      close = vi.fn()
    }
    vi.stubGlobal('EventSource', MockEventSource)

    const onUpdate = vi.fn()
    const cleanup = connectKeeperCursorStream('http://localhost:8935', onUpdate)
    instances[0]!.onmessage?.({
      data: JSON.stringify({
        cursors: [{
          keeper_id: 'sangsu',
          file_path: 'lib/a.ml',
          line: 24,
          column: 2,
          focus_mode: 'editing',
          last_update: Date.now(),
        }],
      }),
    } as MessageEvent)
    expect(onUpdate).toHaveBeenCalledWith(expect.objectContaining({
      active_file: 'lib/a.ml',
    }))

    instances[0]!.onerror?.(new Event('error'))
    cleanup()
    vi.advanceTimersByTime(1_000)

    expect(instances).toHaveLength(1)
    expect(instances[0]!.close).toHaveBeenCalled()
  })
})
