// @vitest-environment jsdom

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { html } from 'htm/preact'
import { cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { authSession, resetAuthStateForTests } from '../../core/auth'
import { resourceCache } from '../../core/resource-cache'
import { FactSeen, digestHead } from './keeper-memory-fact-cells'
import { KeeperMemoryTab } from './keeper-memory-tab'

const KEEPER = 'sample-keeper'
const digest = (hex: string) => `sha256:${hex.repeat(64)}`

const ordinaryFact = (hex: string, claim: string, lastSeen: number) => ({
  memory_id: digest(hex),
  claim,
  category: 'lesson',
  first_seen: 100,
  last_seen: lastSeen,
})

const sourceBoundFact = (claim: string, path = 'docs/guides/operations.md') => ({
  claim,
  first_seen: 200,
  path,
  sha256: digest('e'),
})

function serveMemory(ordinary: readonly unknown[], sourceBound: readonly unknown[] = []) {
  vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => {
    const url = String(input)
    const json = (data: unknown) =>
      new Response(JSON.stringify(data), { status: 200, headers: { 'Content-Type': 'application/json' } })
    if (url.includes('/memory-facts')) {
      return json({
        keeper: KEEPER,
        ordinary: { present: true, revision: 7, snapshot_sha256: 'f'.repeat(64), updated_at: 400, facts: ordinary, support_invalidations: [] },
        source_bound: sourceBound.length > 0
          ? { present: true, revision: 2, updated_at: 400, facts: sourceBound, invalidations: [] }
          : { present: false },
        events_unreadable_lines: 0,
        events_read_error: null,
      })
    }
    if (url.includes('/memory-os-internals')) {
      return json({
        keeper: KEEPER,
        compaction: { present: true, epoch_count: 1, archived_turns_count: 0, anchor_bytes: 0, latest_epoch_id: 1, verified_facts_count: 0, decisions_count: 0, open_threads_count: 0, read_error: null },
        canonical_turns: { present: true, turn_count: 1, latest_turn_id: 't1', compaction_watermark_seq: 0, compaction_watermark_epoch: 1, history_resets_count: 0, read_error: null },
        memory_digest: { present: true, revision: 7, digest_sha256: 'abc', bytes: 64, fact_count: ordinary.length, derived_count: 0 },
        librarian_molt: { writer_kind: 'llm', writer_state: null, pending_molt: null, available_acts: [] },
      })
    }
    if (url.includes('/memory-journal')) {
      return json({ keeper: KEEPER, returned: 0, undecodable_lines: 0, entries: [], activity: { events: [], notes: [] } })
    }
    return json({})
  }))
}

// jsdom does no layout: every box is 0 px tall. A claim is read as running
// past its lines when its text says so.
function layOutClaims() {
  vi.spyOn(Element.prototype, 'scrollHeight', 'get').mockImplementation(function (this: Element) {
    return this.classList.contains('kp-mem-claim-text') && (this.textContent ?? '').includes('long') ? 200 : 0
  })
}

async function openTab(section: 'Ordinary Memory Facts' | 'Source-Bound Memory Facts') {
  const view = render(html`<${KeeperMemoryTab} keeperName=${KEEPER} />`)
  const table = await waitFor(() => {
    const found = view.container.querySelector(`[aria-label="${section}"] table`)
    expect(found?.querySelector('tbody tr td[data-label="Claim"]')).toBeTruthy()
    return found as HTMLTableElement
  })
  return { view, table }
}

const cells = (table: HTMLTableElement, label: string) =>
  [...table.querySelectorAll<HTMLTableCellElement>(`tbody td[data-label="${label}"]`)]

describe('Keeper memory fact tables', () => {
  beforeEach(() => {
    resetAuthStateForTests()
    resourceCache.clearAll()
    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: true,
      authMethods: { google: false, github: false, dev_token: false },
      workspaceId: 'default',
    }
  })

  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
    vi.useRealTimers()
  })

  it('opens with the fact seen last on top and says so in the header', async () => {
    serveMemory([ordinaryFact('a', 'seen first', 100), ordinaryFact('b', 'seen last', 300), ordinaryFact('c', 'seen between', 200)])
    const { table } = await openTab('Ordinary Memory Facts')

    expect(cells(table, 'Claim').map((cell) => cell.textContent?.trim())).toEqual(['seen last', 'seen between', 'seen first'])
    expect(table.querySelector('th[aria-sort="descending"]')?.textContent).toContain('Last seen')
  })

  it('shows the head of a digest and keeps the whole of it as the tooltip', async () => {
    serveMemory([ordinaryFact('b', 'a claim', 300)], [sourceBoundFact('a bound claim')])
    const { view, table } = await openTab('Ordinary Memory Facts')

    const id = cells(table, 'ID')[0]?.querySelector('span')
    expect(id?.textContent).toBe('b'.repeat(8))
    expect(id?.getAttribute('title')).toBe(digest('b'))

    const sha = view.container.querySelector('[aria-label="Source-Bound Memory Facts"] td[data-label="SHA256"] span')
    expect(sha?.textContent).toBe('e'.repeat(8))
    expect(sha?.getAttribute('title')).toBe(digest('e'))
  })

  it('reads the head of a digest with or without its scheme', () => {
    expect(digestHead(digest('a'))).toBe('a'.repeat(8))
    expect(digestHead('0123456789abcdef')).toBe('01234567')
  })

  it('says when a fact was seen, or that the time is not known', () => {
    vi.useFakeTimers({ toFake: ['Date'] })
    vi.setSystemTime(new Date(1_795_000_000_000 + 2 * 3_600_000))

    const seen = render(html`<${FactSeen} seenAt=${1_795_000_000} />`)
    expect(seen.container.textContent).toBe('2시간 전')
    seen.unmount()

    const unknown = render(html`<${FactSeen} seenAt=${0} />`)
    expect(unknown.container.textContent).toBe('없음')
  })

  it('marks the row picked for retraction', async () => {
    serveMemory([ordinaryFact('a', 'kept', 300), ordinaryFact('b', 'picked', 200)])
    const { view, table } = await openTab('Ordinary Memory Facts')
    const row = cells(table, 'Claim').find((cell) => cell.textContent?.includes('picked'))?.closest('tr')
    expect(row?.getAttribute('data-selected')).toBeNull()

    fireEvent.click(row!.querySelector('td[data-label="Cleanup"] button')!)

    await waitFor(() => expect(row?.getAttribute('data-selected')).toBe('true'))
    expect(table.querySelectorAll('tbody tr[data-selected="true"]')).toHaveLength(1)
    expect((view.getByLabelText('철회할 memory_id') as HTMLInputElement).value).toBe(digest('b'))
  })

  it('cuts a claim that runs past its lines and opens it on request', async () => {
    layOutClaims()
    serveMemory([ordinaryFact('a', 'a long claim', 300), ordinaryFact('b', 'a brief claim', 200)])
    const { table } = await openTab('Ordinary Memory Facts')
    const [long, brief] = cells(table, 'Claim')

    expect(brief?.querySelector('button')).toBeNull()
    const more = await waitFor(() => {
      const button = long?.querySelector('button')
      expect(button?.textContent?.trim()).toBe('더 보기')
      return button as HTMLButtonElement
    })
    const longBox = long?.querySelector('.kp-mem-claim-text')
    const briefBox = brief?.querySelector('.kp-mem-claim-text')
    expect(more.getAttribute('aria-expanded')).toBe('false')
    expect(document.getElementById(more.getAttribute('aria-controls') ?? '')).toBe(longBox)

    more.focus()
    expect(document.activeElement).toBe(more)
    fireEvent.click(more)

    await waitFor(() => expect(cells(table, 'Claim')[0]?.querySelector('.kp-mem-claim')?.getAttribute('data-open')).toBe('true'))
    expect(more.isConnected).toBe(true)
    expect(document.activeElement).toBe(more)
    expect(more.textContent?.trim()).toBe('접기')
    expect(more.getAttribute('aria-expanded')).toBe('true')
    expect(cells(table, 'Claim')[0]?.querySelector('.kp-mem-claim-text')).toBe(longBox)
    expect(cells(table, 'Claim')[1]?.querySelector('.kp-mem-claim-text')).toBe(briefBox)
  })

  it('opens one source-bound claim and leaves the other cut', async () => {
    layOutClaims()
    serveMemory(
      [ordinaryFact('a', 'a claim', 300)],
      [
        sourceBoundFact('a long first claim', 'docs/guides/operations.md'),
        sourceBoundFact('a long second claim', 'docs/guides/recovery.md'),
      ],
    )
    const { table } = await openTab('Source-Bound Memory Facts')
    await waitFor(() => expect(table.querySelectorAll('td[data-label="Claim"] button')).toHaveLength(2))

    const first = cells(table, 'Claim').find((cell) => cell.textContent?.includes('first'))
    fireEvent.click(first!.querySelector('button')!)

    await waitFor(() => expect(table.querySelectorAll('.kp-mem-claim[data-open="true"]')).toHaveLength(1))
    const opened = table.querySelector('.kp-mem-claim[data-open="true"]')
    expect(opened?.textContent).toContain('first')
    expect(table.querySelector('th[aria-sort="descending"]')?.textContent).toContain('First seen')
  })

  it('keeps a row with its fact when a search leaves fewer rows', async () => {
    serveMemory(
      [ordinaryFact('a', 'a claim', 300)],
      [
        sourceBoundFact('the first claim', 'docs/guides/operations.md'),
        sourceBoundFact('the second claim', 'docs/guides/recovery.md'),
      ],
    )
    const { view, table } = await openTab('Source-Bound Memory Facts')
    const rowOf = (word: string) => cells(table, 'Claim').find((cell) => cell.textContent?.includes(word))?.closest('tr')
    const second = rowOf('second')
    expect(second).toBeTruthy()

    fireEvent.input(view.getByLabelText('메모리 검색'), { target: { value: 'second' } })

    await waitFor(() => expect(cells(table, 'Claim')).toHaveLength(1))
    expect(rowOf('second')).toBe(second)
  })

  it('shows the claims of another keeper cut, whatever was opened before', async () => {
    layOutClaims()
    serveMemory([ordinaryFact('a', 'a long claim', 300)])
    const { view, table } = await openTab('Ordinary Memory Facts')
    fireEvent.click(await waitFor(() => {
      const button = cells(table, 'Claim')[0]?.querySelector('button')
      expect(button).toBeTruthy()
      return button as HTMLButtonElement
    }))
    await waitFor(() => expect(table.querySelector('.kp-mem-claim[data-open="true"]')).toBeTruthy())

    // The other keeper holds a fact of the same content, so of the same id.
    view.rerender(html`<${KeeperMemoryTab} keeperName="another-keeper" />`)

    await waitFor(() => {
      const claim = view.container.querySelector('[aria-label="Ordinary Memory Facts"] .kp-mem-claim')
      expect(claim).toBeTruthy()
      expect(claim?.hasAttribute('data-open')).toBe(false)
    })
  })
})
