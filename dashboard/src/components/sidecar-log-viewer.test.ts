// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  SidecarLogViewer,
  SidecarLogToggle,
  resetSidecarLogState,
  filterLines,
} from './sidecar-log-viewer'

const flushUi = async () => {
  // Cover: fetch → JSON parse → setEntry → render
  await Promise.resolve()
  await Promise.resolve()
  await Promise.resolve()
  await Promise.resolve()
}

describe('filterLines pure helper', () => {
  const mixed = [
    '2026-04-17 10:00 - discord_bot - INFO - heartbeat',
    '2026-04-17 10:01 - discord_bot - WARNING - slow gate response',
    '2026-04-17 10:02 - discord_bot - ERROR - auth failure (401)',
    '2026-04-17 10:03 - discord_bot - DEBUG - tick 42',
    '2026-04-17 10:04 - discord_bot - INFO - heartbeat',
  ]

  it('level=all returns all lines unchanged', () => {
    expect(filterLines(mixed, 'all', '')).toEqual(mixed)
  })

  it('level=error returns only ERROR-labeled lines', () => {
    const out = filterLines(mixed, 'error', '')
    expect(out.length).toBe(1)
    expect(out[0]).toContain('auth failure')
  })

  it('level=warn matches both WARN and WARNING tokens anywhere on the line', () => {
    const out = filterLines(
      [
        'ts - WARN - short form',
        'ts - WARNING - long form',
        'ts - INFO - heartbeat ok',
        'ts - ERROR - fatal',
      ],
      'warn',
      '',
    )
    expect(out.length).toBe(2)
    expect(out.every(l => /warn/i.test(l))).toBe(true)
  })

  it('keyword filter is case-insensitive substring', () => {
    const out = filterLines(mixed, 'all', 'AUTH')
    expect(out.length).toBe(1)
    expect(out[0]).toContain('auth failure')
  })

  it('level + keyword compose (AND)', () => {
    const out = filterLines(mixed, 'info', 'heartbeat')
    expect(out.length).toBe(2)
    // WARNING line about slow gate should NOT match (not INFO level)
    expect(out.every(l => !l.includes('slow gate'))).toBe(true)
  })

  it('respects maxWindow tail when input exceeds it', () => {
    const big = Array.from({ length: 2500 }, (_, i) => `line ${i} - INFO - ok`)
    const out = filterLines(big, 'info', '', 1000)
    expect(out.length).toBe(1000)
    // Tail — last 1000 should start at index 1500
    expect(out[0]).toBe('line 1500 - INFO - ok')
    expect(out[out.length - 1]).toBe('line 2499 - INFO - ok')
  })

  it('empty keyword is ignored (does not filter everything out)', () => {
    const out = filterLines(mixed, 'all', '   ')
    expect(out).toEqual(mixed)
  })
})

describe('SidecarLogViewer DOM', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    resetSidecarLogState()
  })
  afterEach(() => {
    document.body.removeChild(container)
    vi.restoreAllMocks()
  })

  it('renders filter controls and narrows output when a level pill is clicked', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(
        JSON.stringify({
          ok: true,
          log_path: '/tmp/discord.log',
          available: true,
          lines: [
            '2026-04-17 - INFO - hb',
            '2026-04-17 - ERROR - bang',
            '2026-04-17 - INFO - hb',
          ],
        }),
        { status: 200 },
      ),
    )
    render(html`
      <div>
        <${SidecarLogToggle} connectorId="discord" />
        <${SidecarLogViewer} connectorId="discord" />
      </div>
    `, container)

    // Open the viewer
    ;(container.querySelector('button[aria-expanded]') as HTMLButtonElement).click()
    await flushUi()
    await flushUi()

    // Before filter: match-count shows total
    const pre = container.querySelector('pre') as HTMLPreElement
    expect(pre.textContent).toContain('hb')
    expect(pre.textContent).toContain('bang')

    // Click ERROR pill
    const errorBtn = container.querySelector('[data-log-level="error"]') as HTMLButtonElement
    errorBtn.click()
    await flushUi()

    const preAfter = container.querySelector('pre') as HTMLPreElement
    expect(preAfter.textContent).toContain('bang')
    expect(preAfter.textContent).not.toContain('hb')

    // Count badge reflects narrowed view: "1 / 3 lines"
    const count = container.querySelector('[data-log-count]')?.textContent ?? ''
    expect(count).toMatch(/1\s*\/\s*3/)
  })

  it('clear button resets filters', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(
        JSON.stringify({
          ok: true,
          log_path: '/tmp/x.log',
          available: true,
          lines: ['a - INFO - hi', 'b - ERROR - no'],
        }),
        { status: 200 },
      ),
    )
    render(html`
      <div>
        <${SidecarLogToggle} connectorId="x" />
        <${SidecarLogViewer} connectorId="x" />
      </div>
    `, container)
    ;(container.querySelector('button[aria-expanded]') as HTMLButtonElement).click()
    await flushUi()
    await flushUi()

    ;(container.querySelector('[data-log-level="error"]') as HTMLButtonElement).click()
    await flushUi()
    const clearBtn = container.querySelector('[data-log-filter-clear]') as HTMLButtonElement
    expect(clearBtn).toBeTruthy()
    clearBtn.click()
    await flushUi()

    // After clear: both lines back
    const pre = container.querySelector('pre') as HTMLPreElement
    expect(pre.textContent).toContain('hi')
    expect(pre.textContent).toContain('no')
    // Clear button should disappear (no active filter)
    expect(container.querySelector('[data-log-filter-clear]')).toBeNull()
  })
})
