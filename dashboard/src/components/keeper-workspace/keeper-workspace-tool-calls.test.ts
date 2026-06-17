import { render } from 'preact'
import { afterEach, describe, expect, it } from 'vitest'
import { html } from 'htm/preact'
import { RecentToolList, toolCallRowKey } from './keeper-workspace-tool-calls'
import type { ToolCallEntry } from '../../api/dashboard'

function entry(partial: Partial<ToolCallEntry>): ToolCallEntry {
  return {
    ts: 1_700_000_000_000,
    keeper: 'analyst',
    tool: 'masc_status',
    input: {},
    output: '',
    success: true,
    duration_ms: 120,
    ...partial,
  }
}

describe('toolCallRowKey', () => {
  it('disambiguates same-tool retries by ts + turn', () => {
    const a = entry({ tool: 'masc_status', ts: 1, turn: 1 })
    const b = entry({ tool: 'masc_status', ts: 1, turn: 2 })
    expect(toolCallRowKey(a)).not.toBe(toolCallRowKey(b))
  })
})

describe('RecentToolList', () => {
  let host: HTMLElement
  afterEach(() => {
    if (host) render(null, host)
  })

  function mount(entries: ToolCallEntry[], expandedKey: string | null = null) {
    host = document.createElement('div')
    render(
      html`<${RecentToolList} entries=${entries} expandedKey=${expandedKey} onToggle=${() => {}} />`,
      host,
    )
    return host
  }

  it('renders the tool name and duration for each call', () => {
    mount([entry({ tool: 'masc_board_post', duration_ms: 1500 })])
    const name = host.querySelector('.kw-toolcall-head .nm') as HTMLElement
    expect(name.textContent).toBe('masc_board_post')
    const dur = host.querySelector('.kw-toolcall-head .dur') as HTMLElement
    // formatMsCompact renders ms/s — assert it produced a non-empty duration.
    expect(dur.textContent?.trim().length).toBeGreaterThan(0)
  })

  it('flags a failed call with the bad status dot (not a green ok dot)', () => {
    mount([entry({ tool: 'masc_done', success: false })])
    expect(host.querySelector('.kw-toolcall-head .kw-dot.bad')).toBeTruthy()
    expect(host.querySelector('.kw-toolcall-head .kw-dot.ok')).toBeFalsy()
  })

  it('uses the ok dot for a successful call', () => {
    mount([entry({ success: true })])
    expect(host.querySelector('.kw-toolcall-head .kw-dot.ok')).toBeTruthy()
  })

  it('shows input/output only for the expanded row', () => {
    const e = entry({ tool: 'masc_status', input: { scope: 'fleet' }, output: 'done-ok' })
    const key = toolCallRowKey(e)
    // collapsed: no body
    mount([e], null)
    expect(host.querySelector('.kw-toolcall-body')).toBeFalsy()
    render(null, host)
    // expanded: body shows input + output text
    mount([e], key)
    const body = host.querySelector('.kw-toolcall-body') as HTMLElement
    expect(body).toBeTruthy()
    expect(body.textContent).toContain('fleet')
    expect(body.textContent).toContain('done-ok')
  })

  it('applies v2-monitoring marker classes', () => {
    mount([entry({ tool: 'masc_status' })])
    expect(host.innerHTML).toContain('v2-monitoring-row')
    expect(host.innerHTML).toContain('v2-monitoring-panel')
  })
})
