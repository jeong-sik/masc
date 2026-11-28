// @vitest-environment jsdom

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { html } from 'htm/preact'
import { act, cleanup, render } from '@testing-library/preact'
import { READ_LATE_AFTER_MS } from '../../core/late-read'
import { observedValue } from '../../core/resource-cache'
import { formatTimeHmMs } from '../../lib/format-time'
import { KeeperRoster } from './keeper-roster'

const READ_AT = Date.UTC(2026, 10, 27, 4, 2)

function roster(stale: boolean) {
  return html`<${KeeperRoster}
    roster=${observedValue([], READ_AT, stale)}
    turnsObservation=${null}
    selectedKeeper=${null}
    onSelectKeeper=${vi.fn()}
    onCreatedKeeper=${vi.fn()}
  />`
}

const passTime = (ms: number): Promise<void> => act(async () => { await vi.advanceTimersByTimeAsync(ms) })

describe('KeeperRoster while its list is being read again', () => {
  beforeEach(() => vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] }))

  afterEach(() => {
    cleanup()
    vi.useRealTimers()
  })

  it('says nothing for a re-read that comes back soon', async () => {
    const view = render(roster(true))
    await passTime(READ_LATE_AFTER_MS - 1)
    expect(view.queryByTestId('keeper-roster-late')).toBeNull()

    view.rerender(roster(false))
    await passTime(READ_LATE_AFTER_MS)
    expect(view.queryByTestId('keeper-roster-late')).toBeNull()
  })

  it('marks a re-read that stays out, with the time of the list on screen', async () => {
    const view = render(roster(true))
    await passTime(READ_LATE_AFTER_MS)

    const mark = view.getByTestId('keeper-roster-late')
    const hint = `목록을 다시 읽는 중입니다 · ${formatTimeHmMs(READ_AT)} 조회 결과`
    expect(mark.getAttribute('role')).toBe('status')
    expect(mark.getAttribute('aria-label')).toBe(hint)
    expect(mark.parentElement?.getAttribute('title')).toBe(hint)

    view.rerender(roster(false))
    expect(view.queryByTestId('keeper-roster-late')).toBeNull()
  })

  it('starts the wait over when the list was current in between', async () => {
    const view = render(roster(true))
    await passTime(READ_LATE_AFTER_MS - 1)
    view.rerender(roster(false))
    view.rerender(roster(true))
    await passTime(READ_LATE_AFTER_MS - 1)
    expect(view.queryByTestId('keeper-roster-late')).toBeNull()

    await passTime(1)
    expect(view.queryByTestId('keeper-roster-late')).not.toBeNull()
  })

  it('keeps the title and its count whole beside the mark', async () => {
    const view = render(roster(true))
    await passTime(READ_LATE_AFTER_MS)

    const title = view.container.querySelector('.kp-roster-title')
    expect(title?.querySelector('.kp-roster-title-text')?.textContent?.replace(/\s+/g, ' ').trim()).toBe('Keepers (0)')
    // No text pill joins the title line, and no line is added under it.
    expect(title?.querySelector('.kp-pill')).toBeNull()
    expect(view.container.querySelector('.kp-roster-top')?.nextElementSibling?.matches('input[type="search"]')).toBe(true)
  })
})
