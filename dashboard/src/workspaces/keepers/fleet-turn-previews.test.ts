// @vitest-environment jsdom

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { html } from 'htm/preact'
import { cleanup, render, waitFor } from '@testing-library/preact'
import { authSession, bumpSessionEpoch, resetAuthStateForTests } from '../../core/auth'
import { observerConnected, resetObserverStateForTests, startObserverStream } from '../../core/observer'
import { resourceCache } from '../../core/resource-cache'
import { releaseAllViewStreams } from '../../core/view-stream-slot'
import { resetPortraitCacheForTests } from '../../lib/portrait-cache'
import type { ReceivedTurnPreview } from './chat-turn-progress'
import { NO_FLEET_TURN_PREVIEWS, retainFleetTurnPreview, withObservedTurn } from './fleet-turn-previews'
import { KeepersWorkspace } from './index'
import { KEEPER_ROSTER_OBSERVER_TOPICS, parseKeeperTurnPreviewEvent } from './keepers-api'
import type { KeeperActiveTurn, KeeperActiveTurnPreview, KeeperRosterItem } from './types'

const preview = (revision: number | null, statusText = `at ${revision}`): KeeperActiveTurnPreview => ({
  status_text: statusText, activity: 'tool', preparation: null, work_context: null, open_activities: null, text_tail: '', last_tool: null,
  updated_at_unix: 100, revision,
})
const received = (ownerKey: string, revision: number | null): ReceivedTurnPreview => ({
  ownerKey, preview: preview(revision), receivedAt: 0, live: true,
})
const keeperNamed = (name: string, activeTurn: KeeperActiveTurn | null): KeeperRosterItem => ({
  name, status: 'running', phase: 'running', health: 'healthy', paused: false, keepalive_running: true,
  activation_mode: 'autonomous', runtime_id: 'rt-1', sandbox_profile: null, company: 'co',
  context_ratio: null, context_tokens: null, context_max: null, context_unavailable_reason: null,
  runtime_blocker_summary: null, last_failure: null, directory_issue: null, turns_24h: null,
  candle_balance_milli: null, portrait_equipment: null, chat_control_token: null, active_turn: activeTurn,
})
const keeperInTurn = (ownerKey: string | null, through: number | null, snapshotRevision: number | null = through) =>
  keeperNamed('alpha', {
    lane: 'autonomous', owner_key: ownerKey, started_at_unix: 50, preview_observed_through: through,
    preview: preview(snapshotRevision, 'snapshot'),
  })
const seenAt = (keeper: KeeperRosterItem) => keeper.active_turn?.preview?.status_text

describe('the previews kept for every Keeper', () => {
  it('keeps the newest preview of a turn and leaves the map alone for one that is not newer', () => {
    const first = retainFleetTurnPreview(NO_FLEET_TURN_PREVIEWS, 'alpha', received('A', 3))
    expect(first.get('alpha')?.map((sample) => sample.preview.revision)).toEqual([3])
    const newer = retainFleetTurnPreview(first, 'alpha', received('A', 4))
    expect(newer.get('alpha')?.map((sample) => sample.preview.revision)).toEqual([4])
    // The same map back is what keeps the screen from being drawn again.
    expect(retainFleetTurnPreview(newer, 'alpha', received('A', 4))).toBe(newer)
    expect(retainFleetTurnPreview(newer, 'alpha', received('A', 2))).toBe(newer)
  })

  it('keeps each Keeper apart', () => {
    const alpha = retainFleetTurnPreview(NO_FLEET_TURN_PREVIEWS, 'alpha', received('A', 3))
    const both = retainFleetTurnPreview(alpha, 'beta', received('B', 9))
    expect(both.get('alpha')).toBe(alpha.get('alpha'))
    expect(both.get('beta')?.map((sample) => sample.ownerKey)).toEqual(['B'])
  })

  it('keeps the turn on screen and the one after it, whose snapshot has not been read yet', () => {
    const one = retainFleetTurnPreview(NO_FLEET_TURN_PREVIEWS, 'alpha', received('A', 7))
    const two = retainFleetTurnPreview(one, 'alpha', received('B', 1))
    expect(two.get('alpha')?.map((sample) => sample.ownerKey)).toEqual(['B', 'A'])
    const three = retainFleetTurnPreview(two, 'alpha', received('C', 1))
    expect(three.get('alpha')?.map((sample) => sample.ownerKey)).toEqual(['C', 'B'])
  })
})

describe('a turn as last seen', () => {
  const fleet = (ownerKey: string, revision: number | null) =>
    retainFleetTurnPreview(NO_FLEET_TURN_PREVIEWS, 'alpha', received(ownerKey, revision)).get('alpha')

  it('lays a preview of the same turn, newer than the snapshot, over the snapshot', () => {
    const seen = withObservedTurn(keeperInTurn('A', 5), fleet('A', 6))
    expect(seenAt(seen)).toBe('at 6')
    expect(seen.active_turn?.preview_observed_through).toBe(6)
  })

  it('keeps the snapshot when the preview is not newer than what the snapshot holds', () => {
    const keeper = keeperInTurn('A', 6)
    expect(withObservedTurn(keeper, fleet('A', 6))).toBe(keeper)
    expect(withObservedTurn(keeper, fleet('A', 5))).toBe(keeper)
  })

  it('counts from the revision of the snapshot preview when the snapshot does not say how far it observed', () => {
    expect(seenAt(withObservedTurn(keeperInTurn('A', null, 5), fleet('A', 6)))).toBe('at 6')
    const keeper = keeperInTurn('A', null, 6)
    expect(withObservedTurn(keeper, fleet('A', 6))).toBe(keeper)
  })

  it('keeps the snapshot when the preview belongs to another turn or carries no revision', () => {
    const keeper = keeperInTurn('A', 5)
    expect(withObservedTurn(keeper, fleet('B', 9))).toBe(keeper)
    expect(withObservedTurn(keeper, fleet('A', null))).toBe(keeper)
    const unnamed = keeperInTurn(null, 5)
    expect(withObservedTurn(unnamed, fleet('A', 9))).toBe(unnamed)
  })

  it('leaves a Keeper with no turn, or with nothing received, as it is', () => {
    const idle = keeperNamed('alpha', null)
    expect(withObservedTurn(idle, fleet('A', 9))).toBe(idle)
    const keeper = keeperInTurn('A', 5)
    expect(withObservedTurn(keeper, NO_FLEET_TURN_PREVIEWS.get('alpha'))).toBe(keeper)
    // What another Keeper's turn sent is not this Keeper's.
    expect(withObservedTurn(keeper, retainFleetTurnPreview(NO_FLEET_TURN_PREVIEWS, 'beta', received('A', 9)).get('alpha'))).toBe(keeper)
  })
})

describe('a turn preview read from a shared Observer frame', () => {
  const wire = { status_text: 'rt · tool', activity: 'tool', updated_at_unix: 100, revision: 4 }
  const frame = (more: object) => ({ type: 'keeper_turn_preview_changed', name: 'alpha', ...more })

  it('carries the Keeper and the turn it belongs to', () => {
    const event = parseKeeperTurnPreviewEvent('message', frame({ observation: { owner_key: 'A', preview: wire } }))
    expect(event).toMatchObject({ keeperName: 'alpha', ownerKey: 'A', preview: { status_text: 'rt · tool', revision: 4 } })
  })

  it('is read from a JSON-RPC envelope too', () => {
    const event = parseKeeperTurnPreviewEvent('message', {
      jsonrpc: '2.0', params: frame({ observation: { owner_key: 'A', preview: wire } }),
    })
    expect(event?.keeperName).toBe('alpha')
  })

  it.each([
    ['a preview that names no turn', frame({ observation: { preview: wire } })],
    ['a preview this dashboard cannot read', frame({ observation: { owner_key: 'A', preview: { activity: 'tool' } } })],
    ['a frame with no observation', frame({})],
    ['a frame that names no Keeper', { type: 'keeper_turn_preview_changed', observation: { owner_key: 'A', preview: wire } }],
    ['another event of the same Keeper', { type: 'keeper_turn_changed', name: 'alpha' }],
    ['something that is not a frame', 'keeper_turn_preview_changed'],
  ])('is nothing for %s', (_what, data) => {
    expect(parseKeeperTurnPreviewEvent('message', data)).toBeNull()
  })
})

describe('the Keepers workspace between two reads of the turns', () => {
  beforeEach(() => {
    resetAuthStateForTests()
    resetObserverStateForTests()
    resetPortraitCacheForTests()
    resourceCache.clearAll()
    authSession.value = {
      kind: 'single_user_local', mode: 'single_user', tokenPresent: true,
      authMethods: { google: false, github: false, dev_token: false }, workspaceId: 'default',
    }
    // jsdom lays nothing out: the roster's virtual list needs a height to keep its rows.
    vi.spyOn(HTMLElement.prototype, 'clientHeight', 'get').mockReturnValue(480)
    vi.spyOn(HTMLElement.prototype, 'offsetHeight', 'get').mockReturnValue(480)
    vi.spyOn(HTMLElement.prototype, 'offsetWidth', 'get').mockReturnValue(260)
  })

  afterEach(() => {
    cleanup()
    releaseAllViewStreams()
    resetPortraitCacheForTests()
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  it('says in the header and in the roster what each turn is doing now, without reading the turns again', async () => {
    const now = Date.now() / 1000
    const tool = (name: string, stage: 'executing' | 'requested') => ({
      kind: 'tool', tool_use_id: name, name, stage, started_at_unix: now - 5, since_unix: now - 4, cohort: null, reach: null,
    })
    const turn = (ownerKey: string, statusText: string, open: readonly object[]) => ({
      lane: 'autonomous', owner_key: ownerKey, started_at_unix: now - 60, preview_observed_through: 3,
      preview: { status_text: statusText, activity: 'tool', updated_at_unix: now, revision: 3, open_activities: open },
    })
    const row = (name: string) => ({
      name, status: 'running', phase: 'running', health: 'healthy', paused: false, keepalive_running: true,
      runtime_id: 'rt-1', context_ratio: 0.4,
    })
    let turnsRead = 0
    let observer!: ReadableStreamDefaultController<Uint8Array>
    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url === '/mcp?sse_kind=observer') {
        return new Response(new ReadableStream({ start: (controller) => { observer = controller } }),
          { headers: { 'Content-Type': 'text/event-stream' } })
      }
      if (url.includes('/api/v1/gate/keepers')) return Response.json({ keepers: [row('alpha-one'), row('beta-two')] })
      if (url.includes('/api/v1/keepers/turns')) {
        turnsRead += 1
        return Response.json({ keepers: [
          { keeper_name: 'alpha-one', status: 'ok', turn: turn('A', 'rt-1 · tool running: Grep', [tool('Grep', 'executing')]) },
          { keeper_name: 'beta-two', status: 'ok', turn: turn('B', 'rt-1 · tool running: Read', [tool('Read', 'executing')]) },
        ] })
      }
      if (url.includes('/portrait.png')) return new Response(new Uint8Array([0x89, 0x50, 0x4e, 0x47]), { headers: { 'Content-Type': 'image/png' } })
      return Response.json({ operations: [], messages: [], rows: [], keepers: [] })
    }))
    vi.spyOn(URL, 'createObjectURL').mockReturnValue('blob:portrait')
    const stream = startObserverStream({ autoReconnect: false })
    await waitFor(() => expect(observerConnected.value).toBe(true))

    const view = render(html`<${KeepersWorkspace} subroute="" entityId="alpha-one" entityTab="memory" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`)
    const pill = () => view.container.querySelector('[data-turn-pill]')
    const says = () => pill()?.textContent?.trim()
    const rosterLine = (name: string) =>
      view.container.querySelector(`.kp-roster-row[data-keeper="${name}"] [data-roster-state]`)?.textContent
    await waitFor(() => expect(says()).toBe('● 자율 턴 · Grep · 실행 중'))
    expect(pill()?.getAttribute('title')).toBe('rt-1 · tool running: Grep')
    expect(rosterLine('alpha-one')).toBe('Grep')
    expect(rosterLine('beta-two')).toBe('Read')
    const readsBefore = turnsRead

    const send = (name: string, ownerKey: string, revision: number, statusText: string, open: readonly object[]) =>
      observer.enqueue(new TextEncoder().encode(`data: ${JSON.stringify({
        type: 'keeper_turn_preview_changed', name,
        observation: { owner_key: ownerKey, preview: { status_text: statusText, activity: 'tool', updated_at_unix: now, revision, open_activities: open } },
      })}\n\n`))
    const thinking = [{ kind: 'response', channel: 'thinking', started_at_unix: now - 2, since_unix: now - 1 }]

    // The Keeper on screen moves on to two other tools; the one beside it starts to think.
    send('alpha-one', 'A', 4, 'rt-1 · tool running: Execute · tool called: Read', [tool('Execute', 'executing'), tool('Read', 'requested')])
    send('beta-two', 'B', 4, 'rt-1 · receiving reasoning', thinking)
    await waitFor(() => expect(says()).toBe('● 자율 턴 · Execute 외 1건 · 실행 중'))
    expect(pill()?.getAttribute('title')).toBe('rt-1 · tool running: Execute · tool called: Read')
    expect(rosterLine('alpha-one')).toBe('Execute 외 1건')
    await waitFor(() => expect(rosterLine('beta-two')).toBe('추론 중'))

    // A preview that carries the owner key of another Keeper's turn, one of a
    // turn the snapshot does not name, and one that is not newer, change nothing.
    send('beta-two', 'A', 9, 'rt-1 · tool called: WebFetch', [tool('WebFetch', 'requested')])
    send('alpha-one', 'Z', 9, 'rt-1 · tool running: Glob', [tool('Glob', 'executing')])
    send('alpha-one', 'A', 2, 'rt-1 · tool running: Grep', [tool('Grep', 'executing')])
    // A marker frame after them: once it is drawn, the three before it were handled.
    send('alpha-one', 'A', 5, 'rt-1 · receiving reasoning · tool running: Execute', [...thinking, tool('Execute', 'executing')])
    await waitFor(() => expect(pill()?.getAttribute('title')).toBe('rt-1 · receiving reasoning · tool running: Execute'))
    expect(says()).toBe('● 자율 턴 · Execute · 실행 중')
    expect(rosterLine('alpha-one')).toBe('Execute')
    expect(rosterLine('beta-two')).toBe('추론 중')

    // A preview is not a reason to read the turns again: it is the news itself.
    expect(KEEPER_ROSTER_OBSERVER_TOPICS).not.toContain('keeper_turn_preview_changed')
    expect(turnsRead).toBe(readsBefore)

    // Another session starts from the snapshot: what this one heard is not shown to it.
    // The session change also ends this session's stream.
    bumpSessionEpoch()
    await waitFor(() => expect(says()).toBe('● 자율 턴 · Grep · 실행 중'))
    expect(rosterLine('alpha-one')).toBe('Grep')
    expect(rosterLine('beta-two')).toBe('Read')
    await stream
  })
})
