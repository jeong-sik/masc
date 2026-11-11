import { afterEach, describe, expect, it, vi } from 'vitest'
import { cancelKeeperQueue, parseKeeperQueueCancellation, parseKeeperQueuePreview, previewKeeperQueue, type KeeperQueueRow } from './keeper-event-queue'

const workspace = '/fixture/queue-workspace'
const first: KeeperQueueRow = { keeper_name: 'alpha', source_ref: 'a'.repeat(64), source_incarnation: '9007199254740993', source: 'bootstrap', state: 'pending', source_arrived_at: 1, first_admitted_at: 2 }
const second: KeeperQueueRow = { ...first, source_ref: 'b'.repeat(64), source_incarnation: '9007199254740994' }
function preview(rows: KeeperQueueRow[] = [first]) {
  return { schema: 'keeper_event_queue.bulk.result.v2', ok: true, action: 'preview', workspace_root: workspace,
    would_cancel: rows.length, keeper_counts: { alpha: rows.length }, source_counts: { bootstrap: rows.length }, oldest_age_seconds: 10, rows }
}
function report() {
  return { schema: 'keeper_event_queue.bulk.result.v2', ok: true, action: 'cancel', workspace_root: workspace,
    operation_id: 'fixture-op', backup_path: '/fixture/target-record.json', requested: 1, cancelled: 1,
    committed_followup_failed: 0, failed: 0,
    results: [{ row: first, status: 'cancelled', result: { status: 'applied', transition_id: 'exact-transition' } }] }
}
function respond(value: unknown) { return new Response(JSON.stringify(value), { headers: { 'Content-Type': 'application/json' } }) }
afterEach(() => { vi.unstubAllGlobals(); vi.restoreAllMocks() })

describe('fleet event queue protocol', () => {
  it('preserves a source incarnation beyond JavaScript integer precision', () => {
    expect(parseKeeperQueuePreview(preview(), workspace, {}).rows[0]?.source_incarnation).toBe('9007199254740993')
  })
  it('rejects foreign workspace, filter widening, duplicate targets and false counts', () => {
    expect(() => parseKeeperQueuePreview(preview(), '/other', {})).toThrow()
    expect(() => parseKeeperQueuePreview(preview(), workspace, { keepers: ['beta'] })).toThrow()
    expect(() => parseKeeperQueuePreview(preview([first, first]), workspace, {})).toThrow()
    expect(() => parseKeeperQueuePreview({ ...preview(), would_cancel: 2 }, workspace, {})).toThrow()
    expect(() => parseKeeperQueuePreview({ ...preview(), keeper_counts: { beta: 1 } }, workspace, {})).toThrow()
    expect(() => parseKeeperQueuePreview({ ...preview(), rows: [{ ...first, source_incarnation: 9007199254740992 }] }, workspace, {})).toThrow()
  })
  it('binds the result to every submitted identity and outcome count', () => {
    expect(parseKeeperQueueCancellation(report(), workspace, [first]).cancelled).toBe(1)
    expect(() => parseKeeperQueueCancellation(report(), workspace, [second])).toThrow()
    expect(() => parseKeeperQueueCancellation({ ...report(), cancelled: 0 }, workspace, [first])).toThrow()
    expect(() => parseKeeperQueueCancellation({ ...report(), results: [...report().results, ...report().results] }, workspace, [first])).toThrow()
  })
  it('retains committed follow-up failure separately from a failed request', () => {
    const value = { ...report(), cancelled: 0, committed_followup_failed: 1,
      results: [{ row: first, status: 'committed_followup_failed', result: {
        status: 'committed_followup_failed', transition_id: 'committed', stage: 'projection', detail: 'ledger unavailable',
      } }] }
    expect(parseKeeperQueueCancellation(value, workspace, [first]).committed_followup_failed).toBe(1)
  })
  it('sends the explicit selection without adding later arrivals or rounding versions', async () => {
    const fetch = vi.fn().mockResolvedValueOnce(respond(preview([first, second]))).mockResolvedValueOnce(respond(report()))
    vi.stubGlobal('fetch', fetch)
    const snapshot = await previewKeeperQueue(workspace, {})
    await cancelKeeperQueue(workspace, {}, [snapshot.rows[0]!], 'one selected row')
    expect(fetch).toHaveBeenCalledTimes(2)
    const [url, init] = fetch.mock.calls[1]!
    expect(url).toBe(`/api/v1/keepers_bulk/event-queue?expected_workspace=${encodeURIComponent(workspace)}`)
    expect(JSON.parse(init.body as string)).toEqual({ schema: 'keeper_event_queue.bulk.request.v2', action: 'cancel',
      filter: {}, reason: 'one selected row', selections: [{ keeper_name: first.keeper_name, source_ref: first.source_ref, source_incarnation: first.source_incarnation }] })
  })
  it('makes one mutation attempt and preserves unavailable transport as an error', async () => {
    const fetch = vi.fn().mockRejectedValue(new Error('response lost after commit'))
    vi.stubGlobal('fetch', fetch)
    await expect(cancelKeeperQueue(workspace, {}, [first], 'operator')).rejects.toThrow('response lost')
    expect(fetch).toHaveBeenCalledTimes(1)
  })
  it('does not dispatch an empty, duplicate or foreign-filter selection', async () => {
    const fetch = vi.fn(); vi.stubGlobal('fetch', fetch)
    await expect(cancelKeeperQueue(workspace, {}, [], 'operator')).rejects.toThrow()
    await expect(cancelKeeperQueue(workspace, {}, [first, first], 'operator')).rejects.toThrow()
    await expect(cancelKeeperQueue(workspace, { keepers: ['beta'] }, [first], 'operator')).rejects.toThrow()
    expect(fetch).not.toHaveBeenCalled()
  })
})
