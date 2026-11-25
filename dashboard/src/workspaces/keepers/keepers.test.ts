import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { html } from 'htm/preact'
import { render, fireEvent, waitFor, cleanup } from '@testing-library/preact'
import { formatObserved, resourceCache } from '../../core/resource-cache'
import { authSession, resetAuthStateForTests } from '../../core/auth'
import { resetObserverStateForTests } from '../../core/observer'
import { resetPortraitCacheForTests } from '../../lib/portrait-cache'
import {
  buildChatStreamRequestBody,
  buildPortraitPreviewUrl,
  decodeChatJournalPage,
  decodeKeeperMemoryFacts,
  fetchKeeperTurnRecordsApi,
  filterAndSortRoster,
  formatCandleMilli,
  observeRosterContextPct,
  parseOrdinaryMemoryBranch,
  parseSourceBoundMemoryBranch,
  reconstructJournalReply,
  transcribeVoiceAudio,
} from './keepers-api'
import {
  buildContextFillSeries,
  computePromptCacheSegments,
  KeeperDebugCompanion,
  shouldDefaultOpenCompanion,
} from './keeper-debug-companion'
import { releaseAllViewStreams, getActiveViewStreamKey } from '../../core/view-stream-slot'
import { KeeperChatTab } from './keeper-chat-tab'
import { KeeperMemoryTab } from './keeper-memory-tab'
import { KeeperPortraitCandleTab } from './keeper-portrait-candle-tab'
import { KeeperWorkSandboxTab } from './keeper-work-sandbox-tab'
import { KeeperConfigTab } from './keeper-config-tab'
import { KeepersWorkspace } from './index'
import type { KeeperRosterItem, TurnRecordItem } from './types'

function makeRosterKeeper(overrides: Partial<KeeperRosterItem> = {}): KeeperRosterItem {
  return {
    name: 'code-reviewer-sister',
    status: 'running',
    phase: 'idle',
    health: 'healthy',
    paused: false,
    keepalive_running: true,
    activation_mode: 'autonomous',
    runtime_id: 'claude-code',
    sandbox_profile: 'microvm',
    company: 'code',
    context_ratio: 0.54,
    context_tokens: 108_000,
    context_max: 200_000,
    context_unavailable_reason: null,
    runtime_blocker_summary: null,
    last_failure: null,
    directory_issue: null,
    turns_24h: 42,
    candle_balance_milli: '12500',
    portrait_equipment: {
      face: 'glasses',
      neck: 'bare_neck',
      head: 'crown',
      hand: 'empty_hand',
      base: 'no_dish',
    },
    chat_control_token: 'ctrl-tok-1',
    active_turn: null,
    ...overrides,
  }
}

describe('Keepers Workspace — Pure Contracts & Parsers', () => {
  it('sorts and filters Keeper Roster across Companies, Attention, and 24h Wall modes', () => {
    const items = [
      makeRosterKeeper({ name: 'zeta-worker', company: 'zeta', turns_24h: 10, health: 'healthy' }),
      makeRosterKeeper({ name: 'alpha-reviewer', company: 'alpha', turns_24h: 95, health: 'healthy' }),
      makeRosterKeeper({ name: 'beta-fault', company: 'beta', turns_24h: 3, health: 'failing', runtime_blocker_summary: '429' }),
    ]

    expect(filterAndSortRoster(items, 'companies', '').map((k) => k.name)).toEqual([
      'alpha-reviewer',
      'beta-fault',
      'zeta-worker',
    ])
    expect(filterAndSortRoster(items, 'attention', '')[0]!.name).toBe('beta-fault')
    expect(filterAndSortRoster(items, 'wall24h', '')[0]!.name).toBe('alpha-reviewer')
    expect(filterAndSortRoster(items, 'companies', 'fault').map((k) => k.name)).toEqual(['beta-fault'])

    expect(formatObserved(observeRosterContextPct(makeRosterKeeper({ context_ratio: 0 })), (v) => `${v}%`)).toBe('0%')
    expect(formatObserved(observeRosterContextPct(makeRosterKeeper({ context_ratio: null })), (v) => `${v}%`)).toBe('없음')
  })

  it('builds Origin_bare Queue vs Steer (own operation_id) vs /btw payloads accurately', () => {
    const queued = buildChatStreamRequestBody({
      keeper: 'code-reviewer-sister',
      message: 'Check PR #5',
      operationId: 'op-queue-1',
      mode: { kind: 'queue' },
    })
    expect(queued).toEqual({
      request_id: 'op-queue-1',
      name: 'code-reviewer-sister',
      message: 'Check PR #5',
    })
    expect('channel' in queued).toBe(false)
    expect('admission_intent' in queued).toBe(false)

    const steered = buildChatStreamRequestBody({
      keeper: 'code-reviewer-sister',
      message: 'Pivot to tests',
      operationId: 'op-steer-9',
      mode: { kind: 'steer', controlToken: 'tok-xyz' },
    })
    expect('channel' in steered).toBe(false)
    expect(steered.admission_intent).toEqual({
      kind: 'interactive',
      control_token: 'tok-xyz',
      interrupt_token: null,
      operation_id: 'op-steer-9',
    })

    const btw = buildChatStreamRequestBody({
      keeper: 'code-reviewer-sister',
      message: 'Which commit?',
      operationId: 'op-btw-2',
      mode: { kind: 'btw' },
    })
    expect(btw.turn_instructions).toContain('/btw')
  })

  it('reconstructs cut-reply chat events respecting Cut_reply monotonic ownership & event_error', () => {
    const recovered = reconstructJournalReply([
      { kind: 'run_started' },
      { kind: 'text_delta', text: 'stale attempt ', owner: { kind: 'observed_response', contentGeneration: 0, streamScope: 1 } },
      { kind: 'runtime_attempt_started' },
      // Late superseded chunk from closed (0, 1) must be dropped without wiping attempt 2
      { kind: 'text_delta', text: 'late stale', owner: { kind: 'observed_response', contentGeneration: 0, streamScope: 1 } },
      { kind: 'text_delta', text: 'final ', owner: { kind: 'observed_response', contentGeneration: 1, streamScope: 0 } },
      // Older generation chunk arriving after (1, 0) must be dropped without wiping 'final '
      { kind: 'text_delta', text: 'out-of-order', owner: { kind: 'observed_response', contentGeneration: 0, streamScope: 2 } },
      { kind: 'text_delta', text: 'answer', owner: { kind: 'observed_response', contentGeneration: 1, streamScope: 0 } },
      { kind: 'run_finished' },
    ])
    expect(recovered).toEqual({ text: 'final answer', finished: true, error: null })

    // Server journal tag `event_error` must decode as error and fail recovery
    const errPage = decodeChatJournalPage(
      {
        has_more: false,
        events: [
          { event: { type: 'run_started' } },
          { event: { type: 'event_error', detail: 'provider_timeout' } },
        ],
      },
      'op-err-1',
    )
    expect(reconstructJournalReply(errPage.events)).toEqual({
      text: '',
      finished: false,
      error: 'provider_timeout',
    })
  })

  it('parses 3-way discriminated memory-facts (present:false / read_error / present:true)', () => {
    expect(parseOrdinaryMemoryBranch({ present: false })).toEqual({ state: 'absent' })
    expect(parseOrdinaryMemoryBranch({ read_error: 'corrupt jsonl' })).toEqual({
      state: 'read_error',
      read_error: 'corrupt jsonl',
    })
    const okOrd = parseOrdinaryMemoryBranch({
      present: true,
      revision: 7,
      snapshot_sha256: 'abc',
      updated_at: 100,
      facts: [{ memory_id: 'm1', claim: 'Uses OKLCH', category: 'ui', first_seen: 1, last_seen: 2 }],
      support_invalidations: [],
    })
    expect(okOrd.state).toBe('present')
    if (okOrd.state === 'present') {
      expect(okOrd.facts).toHaveLength(1)
      expect(okOrd.revision).toBe(7)
    }

    expect(parseSourceBoundMemoryBranch({ present: false })).toEqual({ state: 'absent' })
    expect(parseSourceBoundMemoryBranch({ read_error: 'io_err' })).toEqual({ state: 'read_error', read_error: 'io_err' })
    const decoded = decodeKeeperMemoryFacts(
      {
        keeper: 'k1',
        ordinary: { present: false },
        source_bound: {
          present: true,
          revision: 3,
          updated_at: 200,
          facts: [{ claim: 'README states MIT', first_seen: 10, path: 'README.md', sha256: 'deadbeef' }],
          invalidations: [{ source_path: 'OLD.md', invalidated_at: 15, reason: 'source_changed' }],
        },
        events_unreadable_lines: 0,
        events_read_error: null,
      },
      'k1',
    )
    expect(decoded.ordinary.state).toBe('absent')
    expect(decoded.source_bound.state).toBe('present')
  })

  it('computes Debug Companion defaults, 4-segment cache bar, and 60-turn compaction detection', () => {
    expect(shouldDefaultOpenCompanion(1024)).toBe(false)
    expect(shouldDefaultOpenCompanion(1279)).toBe(false)
    expect(shouldDefaultOpenCompanion(1280)).toBe(true)

    const sampleRecord: TurnRecordItem = {
      trace_id: 'tr1',
      absolute_turn: 10,
      turn_ref: 'tr1#10',
      turn_kind: 'direct',
      runtime_profile: 'default',
      input_tokens: 100_000,
      cache_read_input_tokens: 70_000,
      cache_creation_input_tokens: 10_000,
      output_tokens: 5_000,
      context_window: 200_000,
      ts: 1_700_000_000,
      blocks: [],
      raw_trace_run_ref: null,
    }
    const segs = computePromptCacheSegments(sampleRecord)
    expect(segs.cacheRead).toBe(70_000)
    expect(segs.cacheCreate).toBe(10_000)
    expect(segs.uncachedInput).toBe(20_000)
    expect(segs.output).toBe(5_000)
    expect(segs.cacheHitPct).toBe(70)

    // input_tokens (100k) already includes cached tokens (70k + 10k) — must NOT double-count to 180k (90%)!
    const series = buildContextFillSeries([
      { ...sampleRecord, absolute_turn: 1, ts: 100, input_tokens: 100_000, cache_read_input_tokens: 70_000, cache_creation_input_tokens: 10_000 },
      { ...sampleRecord, absolute_turn: 2, ts: 200, input_tokens: 40_000, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 },
    ])
    expect(series.data[1]).toEqual([50, 20])
    expect(series.compactionTurns).toEqual([2])
  })

  it('builds Portrait preview URLs (bare item id + 5-key object) and decimal-string Candle values', () => {
    const url = buildPortraitPreviewUrl('code-reviewer-sister', 256, 'crown', {
      face: 'glasses',
      neck: 'bare_neck',
      head: 'bare_head',
      hand: 'empty_hand',
      base: 'no_dish',
    })
    const parsed = new URL(url, 'http://localhost')
    expect(parsed.pathname).toBe('/api/v1/keepers/code-reviewer-sister/portrait.png')
    expect(parsed.searchParams.get('size')).toBe('256')
    expect(parsed.searchParams.get('preview')).toBe('crown')
    expect(JSON.parse(parsed.searchParams.get('expected_equipment') ?? '{}')).toEqual({
      face: 'glasses',
      neck: 'bare_neck',
      head: 'bare_head',
      hand: 'empty_hand',
      base: 'no_dish',
    })

    expect(formatObserved(formatCandleMilli('987654321000'))).toBe('987,654,321.000')
  })

  it('uses zero raw hex colors and zero off-grid px spacing literals in keepers.css', () => {
    const cssPath = resolve(process.cwd(), 'src/workspaces/keepers/keepers.css')
    const css = readFileSync(cssPath, 'utf8')
    expect(css).not.toMatch(/#[0-9a-fA-F]{3,8}\b/)
    expect(css).not.toMatch(/\b(?:padding|margin|gap):\s*[^;]*\b(?:1|2|3|5|6|10)px\b/)
  })
})

describe('Keepers Workspace — Interactive DOM & API Flows', () => {
  beforeEach(() => {
    resetAuthStateForTests()
    resetObserverStateForTests()
    resetPortraitCacheForTests()
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
    releaseAllViewStreams()
    resetPortraitCacheForTests()
    vi.restoreAllMocks()
  })

  it('attributes saved user messages to their recorded speakers', async () => {
    const messages = [
      { id: 'external', role: 'user', content: 'External message', ts: 1, speaker_name: ' Minsu ', speaker_id: 'U123', speaker_authority: 'external' },
      { id: 'peer', role: 'user', content: 'Keeper request', ts: 2, speaker_id: 'peer-keeper', speaker_authority: 'keeper' },
      { id: 'owner', role: 'user', content: 'Operator message', ts: 3, speaker_authority: 'owner' },
      { id: 'unattributed', role: 'user', content: 'Older message', ts: 4 },
    ]
    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => {
      const payload = String(input).includes('/chat/history/page')
        ? { messages, has_more: false, next_cursor: null }
        : { operations: [] }
      return new Response(JSON.stringify(payload), {
        headers: { 'Content-Type': 'application/json' },
      })
    }))

    const { container } = render(
      html`<${KeeperChatTab} keeper=${makeRosterKeeper()} onInspect=${vi.fn()} onMutated=${vi.fn()} />`,
    )
    await waitFor(() => {
      const speakers = Array.from(
        container.querySelectorAll('.kp-msg[data-role="user"] .kp-msg-head > span'),
        (heading) => heading.textContent?.trim(),
      )
      expect(speakers).toEqual(['Minsu', 'peer-keeper', 'Operator', '사용자'])
    })
  })

  it('dispatches Queue (Enter) vs Steer (⌘↵) with own operation_id and toggles Debug Companion with ⌘.', async () => {
    const streamBodies: Record<string, unknown>[] = []
    const mockFetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (url.includes('/chat/history/page')) {
        return new Response(JSON.stringify({ messages: [], has_more: false, next_cursor: null }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        })
      }
      if (url.includes('/chat/operations')) {
        return new Response(JSON.stringify({ operations: [] }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        })
      }
      if (url.includes('/api/v1/keepers/chat/stream')) {
        const parsed = JSON.parse(String(init?.body ?? '{}')) as Record<string, unknown>
        streamBodies.push(parsed)
        const sse = `data: ${JSON.stringify({ type: 'TEXT_MESSAGE_CONTENT', delta: 'Ack!' })}\n\ndata: ${JSON.stringify({ type: 'RUN_FINISHED' })}\n\n`
        return new Response(sse, {
          status: 200,
          headers: { 'Content-Type': 'text/event-stream' },
        })
      }
      return new Response(JSON.stringify({ entries: [], turns: [] }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })
    })
    vi.stubGlobal('fetch', mockFetch)

    const { container, getByLabelText } = render(
      html`<${KeeperChatTab} keeper=${makeRosterKeeper()} onInspect=${vi.fn()} onMutated=${vi.fn()} />`,
    )

    const input = getByLabelText('Keeper 채팅 입력') as HTMLTextAreaElement
    // Hangul IME composition Enter must NOT submit mid-composition (P1-6)
    fireEvent.input(input, { target: { value: '한글 조합중' } })
    fireEvent.keyDown(input, { key: 'Enter', isComposing: true })
    expect(streamBodies.length).toBe(0)

    fireEvent.input(input, { target: { value: 'Normal follow-up' } })
    fireEvent.keyDown(input, { key: 'Enter' })
    // Rapid duplicate Enter while in-flight must be ignored (P1-6 double-submit guard)
    fireEvent.keyDown(input, { key: 'Enter' })

    await waitFor(() => expect(streamBodies.length).toBe(1))
    expect(streamBodies[0]!.admission_intent).toBeUndefined()
    expect('channel' in streamBodies[0]!).toBe(false)
    // Wait for first reply to finish and composer to re-enable
    await waitFor(() => {
      expect(container.textContent).toContain('Ack!')
      expect(getActiveViewStreamKey()).toBeNull()
    })

    fireEvent.input(input, { target: { value: 'Urgent steer' } })
    fireEvent.keyDown(input, { key: 'Enter', metaKey: true })

    await waitFor(() => expect(streamBodies.length).toBe(2))
    const steerBody = streamBodies[1]!
    expect(steerBody.admission_intent).toMatchObject({
      kind: 'interactive',
      control_token: 'ctrl-tok-1',
      operation_id: steerBody.request_id,
    })

    // Toggle Debug Companion with ⌘.
    const initialOpen = container.querySelector('[data-companion-open]')?.getAttribute('data-companion-open')
    fireEvent.keyDown(window, { key: '.', metaKey: true })
    await waitFor(() => {
      const nextOpen = container.querySelector('[data-companion-open]')?.getAttribute('data-companion-open')
      expect(nextOpen).not.toBe(initialOpen)
    })
  })

  it('renders 3-way discriminated Memory tab states and Config CAS 409 conflict_cas alert', async () => {
    const mockFetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      const json = (data: unknown, status = 200) =>
        new Response(JSON.stringify(data), { status, headers: { 'Content-Type': 'application/json' } })
      if (url.includes('/memory-facts')) {
        return json({
          keeper: 'code-reviewer-sister',
          ordinary: { read_error: 'corrupted ordinary snapshot' },
          source_bound: { present: false },
          events_unreadable_lines: 0,
          events_read_error: null,
        })
      }
      if (url.includes('/memory-os-internals')) {
        return json({
          keeper: 'code-reviewer-sister',
          compaction: { present: true, epoch_count: 3, archived_turns_count: 45, anchor_bytes: 2048, latest_epoch_id: 3, verified_facts_count: 12, decisions_count: 4, open_threads_count: 1, read_error: null },
          canonical_turns: { present: true, turn_count: 60, latest_turn_id: 't60', compaction_watermark_seq: 45, compaction_watermark_epoch: 3, history_resets_count: 0, read_error: null },
          memory_digest: { present: true, revision: 9, digest_sha256: 'abc', bytes: 1024, fact_count: 12, derived_count: 2 },
          librarian_molt: { writer_kind: 'llm', writer_state: null, pending_molt: null, available_acts: ['resume'] },
        })
      }
      if (url.includes('/memory-journal')) {
        return json({ keeper: 'code-reviewer-sister', returned: 0, undecodable_lines: 0, entries: [], activity: { events: [], notes: [] } })
      }
      if (url.includes('/api/v1/config/schema')) {
        return json({
          schema_version: 1,
          instance_id: 'i1',
          generated_at_unix: 1,
          data: {
            target: 'keeper:code-reviewer-sister',
            keeper: 'code-reviewer-sister',
            file_exists: true,
            file_sha256: 'deadbeef1234',
            categories: [
              {
                id: 'autonomy',
                title: 'Autonomy',
                field_count: 1,
                fields: [
                  {
                    table: 'keeper',
                    key: 'activation_mode',
                    full_key: 'keeper.activation_mode',
                    type: 'string',
                    current_value: 'manual',
                    default_value: 'manual',
                    provenance: 'toml',
                    reload_scope: 'next_turn',
                    secret: false,
                    writable: true,
                    description: 'Activation mode',
                    enum_values: ['manual', 'autonomous'],
                  },
                ],
              },
            ],
          },
        })
      }
      if (url.includes('/api/v1/config/patch')) {
        const body = JSON.parse(String(init?.body ?? '{}')) as { dry_run?: boolean }
        if (body.dry_run) {
          return json({
            schema_version: 1,
            instance_id: 'i1',
            generated_at_unix: 1,
            data: {
              applied: false,
              dry_run: true,
              target: 'keeper:code-reviewer-sister',
              changed: true,
              before_sha256: 'deadbeef1234',
              new_sha256: 'cafebabe5678',
              snapshot_id: null,
              reload_scope: 'next_turn',
              unified_diff: '-activation_mode = "manual"\n+activation_mode = "autonomous"',
              validation_warnings: [],
            },
          })
        }
        return json({ error: { code: 'conflict_cas', message: 'sha mismatch' } }, 409)
      }
      if (url.includes('/api/v1/keepers/oauth/attached-tools')) {
        return json({ providers: [] })
      }
      return json({})
    })
    vi.stubGlobal('fetch', mockFetch)

    const mem = render(html`<${KeeperMemoryTab} keeperName="code-reviewer-sister" />`)
    await waitFor(() => {
      expect(mem.container.querySelector('[data-branch="read_error"]')?.textContent).toContain('corrupted ordinary snapshot')
      expect(mem.container.querySelector('[data-branch="absent"]')?.textContent).toContain('present: false')
    })
    mem.unmount()

    const cfg = render(html`<${KeeperConfigTab} keeperName="code-reviewer-sister" onMutated=${vi.fn()} />`)
    await waitFor(() => expect(cfg.getByLabelText('keeper.activation_mode')).toBeTruthy())

    const select = cfg.getByLabelText('keeper.activation_mode') as HTMLSelectElement
    fireEvent.change(select, { target: { value: 'autonomous' } })

    fireEvent.click(cfg.getByRole('button', { name: 'Dry-Run Unified Diff 미리보기' }))
    await waitFor(() => {
      expect(cfg.container.textContent).toContain('reload_scope: next_turn')
      expect(cfg.container.textContent).toContain('+activation_mode = "autonomous"')
    })

    fireEvent.click(cfg.getByRole('button', { name: 'CAS 설정 적용 (expected_sha256)' }))
    await waitFor(() => {
      expect(cfg.container.querySelector('[data-cas-conflict="true"]')).toBeTruthy()
    })
  })

  it('renders honest Portrait try-on preview (single bare item id) and KeepersWorkspace 2-pane shell', async () => {
    const requestedUrls: string[] = []
    const mockFetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      requestedUrls.push(url)
      const json = (data: unknown) =>
        new Response(JSON.stringify(data), { status: 200, headers: { 'Content-Type': 'application/json' } })
      if (url.includes('/api/v1/candle/ledger')) {
        return json({
          schema_version: 1,
          instance_id: 'i1',
          generated_at_unix: 1,
          data: {
            ledger_state: 'present',
            total_events: 1,
            policy: { configuration: 'enabled', disabled_reason: null, pricing_mode: 'fixed', half_life: { mode: 'decay', half_life_hours: 168 } },
            supply: { issued_milli: '50000', burned_milli: '5000', circulating_milli: '45000' },
            balances: [{ keeper: 'code-reviewer-sister', balance_milli: 12500, decayed_milli: '1250', last_event_unix: 100, owned_items: ['glasses'], equipped: { face: 'glasses', neck: null, head: null, hand: null, base: null } }],
            recent_events: [{ seq: 1, at_unix: 100, at_rfc3339: '2026-11-24T00:00:00Z', kind: 'awarded', amount_milli: '12500' }],
          },
        })
      }
      if (url.includes('/api/v1/keepers/code-reviewer-sister/items')) {
        return json({
          status: 'ready',
          keeper: 'code-reviewer-sister',
          account_revision: '1',
          balance_milli: '12500',
          owned_items: ['glasses'],
          catalog: [
            { id: 'glasses', slot: 'face', price_status: 'priced', price_milli: '5000' },
            { id: 'crown', slot: 'head', price_status: 'priced', price_milli: '9000' },
          ],
        })
      }
      if (url.includes('/api/v1/gate/keepers')) {
        return json({
          keepers: [
            { name: 'code-reviewer-sister', status: 'running', phase: 'idle', health: 'healthy', paused: false, keepalive_running: true, runtime_id: 'claude-code', context_ratio: 0.4 },
          ],
        })
      }
      if (url.includes('/api/v1/keepers/turns')) return json({ keepers: [] })
      if (url.includes('/portrait.png')) {
        return new Response(new Blob(['png'], { type: 'image/png' }), {
          status: 200,
          headers: { 'Content-Type': 'image/png' },
        })
      }
      if (url.includes('/chat/history/page')) return json({ messages: [], has_more: false, next_cursor: null })
      if (url.includes('/chat/operations')) return json({ operations: [] })
      return json({})
    })
    vi.spyOn(URL, 'createObjectURL').mockImplementation(() => `blob:portrait-${requestedUrls.length}`)
    vi.stubGlobal('fetch', mockFetch)

    const pc = render(html`<${KeeperPortraitCandleTab} keeper=${makeRosterKeeper()} onMutated=${vi.fn()} />`)
    await waitFor(() => expect(pc.container.textContent).toContain('12.500 C'))
    // Must NOT spoof /mcp purchase; clicking preview updates portrait img to bare `?preview=crown` via authenticated blob fetch
    const previewBtns = pc.getAllByRole('button', { name: '미리보기' })
    fireEvent.click(previewBtns[1]!)
    await waitFor(() => {
      const img = pc.container.querySelector('img.kp-portrait-preview') as HTMLImageElement | null
      expect(img).not.toBeNull()
      expect(img?.getAttribute('data-portrait-url')).toContain('preview=crown')
      expect(img?.getAttribute('src')).toMatch(/^blob:/)
    })
    expect(requestedUrls.some((u) => u.includes('preview=crown'))).toBe(true)
    expect(requestedUrls.some((u) => u === '/mcp')).toBe(false)
    pc.unmount()

    const onNavigate = vi.fn()
    const ws = render(
      html`<${KeepersWorkspace} subroute="" entityId="code-reviewer-sister" entityTab="chat" onNavigate=${onNavigate} onInspect=${vi.fn()} />`,
    )
    await waitFor(() => expect(ws.container.textContent).toContain('code-reviewer-sister'))
    expect(ws.container.querySelectorAll('*').length).toBeLessThan(1200)
    fireEvent.click(ws.getByRole('tab', { name: 'Memory' }))
    expect(onNavigate).toHaveBeenCalledWith('/keepers/code-reviewer-sister/memory')
  })

  it('sends raw binary audio for Voice STT, decodes diff_vs_prev.changed, guards Clear/Reset with TargetLockedAction, and preserves Config drafts on OAuth toggle', async () => {
    let voiceContentType: string | null = null
    let voiceBodyWasBinary = false
    const mockFetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      const json = (data: unknown) =>
        new Response(JSON.stringify(data), { status: 200, headers: { 'Content-Type': 'application/json' } })
      if (url === '/api/v1/voice/transcribe') {
        const hdrs = init?.headers as Record<string, string> | undefined
        voiceContentType = hdrs?.['Content-Type'] ?? null
        voiceBodyWasBinary = init?.body instanceof ArrayBuffer || init?.body instanceof Uint8Array
        return json({ text: 'hello world' })
      }
      if (url.includes('/turn-records')) {
        return json({
          keeper: 'code-reviewer-sister',
          count: 1,
          live_turn_in_progress: false,
          health: 'ok',
          entries: [
            {
              record: { trace_id: 'tr1', absolute_turn: 2, turn_ref: 'tr1#2', turn_kind: 'direct', runtime_profile: 'default', ts: 100, blocks: [], raw_trace_run_ref: null },
              diff_vs_prev: {
                added: [],
                removed: [],
                changed: [{ prev: { block: 'sys', bytes: 100, digest: 'a' }, next: { block: 'sys', bytes: 120, digest: 'b' } }],
              },
            },
          ],
        })
      }
      if (url.includes('/checkpoints')) {
        return json({ keeper: 'code-reviewer-sister', trace_id: 'tr1', current_status: 'available', current: { snapshot_id: 'snap-1', message_count: 4, created_at: 100, latest_preview: null }, history: [] })
      }
      if (url.includes('/api/v1/config/schema')) {
        return json({
          schema_version: 1,
          instance_id: 'i1',
          generated_at_unix: 1,
          data: {
            target: 'keeper:code-reviewer-sister',
            keeper: 'code-reviewer-sister',
            file_exists: true,
            file_sha256: 'deadbeef1234',
            categories: [{ id: 'autonomy', title: 'Autonomy', field_count: 1, fields: [{ table: 'keeper', key: 'activation_mode', full_key: 'keeper.activation_mode', type: 'string', current_value: 'manual', default_value: 'manual', provenance: 'toml', reload_scope: 'next_turn', secret: false, writable: true, description: 'mode', enum_values: ['manual', 'autonomous'] }] }],
          },
        })
      }
      if (url.includes('/api/v1/keepers/oauth/attached-tools')) {
        return json({
          providers: [
            { provider: 'github', provider_label: 'GitHub', attached: true, enabled: true, tools: ['gh_pr'] },
            { provider: 'slack', provider_label: 'Slack', attached: false },
          ],
        })
      }
      if (url.includes('/identity-switch')) return json({ ok: true })
      if (url.includes('/oauth-login')) return json({ authorize_url: 'https://slack.com/oauth/v2/authorize?client_id=123' })
      return json({ entries: [], turns: [] })
    })
    vi.stubGlobal('fetch', mockFetch)

    // P1-2: Voice STT sends raw binary with audio/webm
    const sttRes = await transcribeVoiceAudio(new Uint8Array([1, 2, 3, 4]).buffer, 'audio/webm')
    expect(sttRes.ok).toBe(true)
    if (sttRes.ok) expect(sttRes.value).toBe('hello world')
    expect(voiceContentType).toBe('audio/webm')
    expect(voiceBodyWasBinary).toBe(true)

    // P2-3: diff_vs_prev.changed decoded properly
    const trRes = await fetchKeeperTurnRecordsApi('code-reviewer-sister', 10)
    expect(trRes.ok).toBe(true)
    if (trRes.ok) {
      expect(trRes.value.entries[0]?.diff_vs_prev?.changed).toEqual([
        { prev: { block: 'sys', bytes: 100, digest: 'a' }, next: { block: 'sys', bytes: 120, digest: 'b' } },
      ])
    }

    // P2-2: Clear/Reset require confirmation inside TargetLockedAction
    const cmp = render(html`<${KeeperDebugCompanion} keeperName="code-reviewer-sister" onClose=${vi.fn()} onInspect=${vi.fn()} />`)
    fireEvent.click(cmp.getByRole('tab', { name: 'Context' }))
    await waitFor(() => expect(cmp.getByRole('button', { name: 'Clear Context…' })).toBeTruthy())
    fireEvent.click(cmp.getByRole('button', { name: 'Clear Context…' }))
    await waitFor(() => {
      expect(cmp.container.querySelector('.tla')).toBeTruthy()
      expect(cmp.getByRole('button', { name: 'Clear Context 실행 확인' })).toBeTruthy()
    })
    cmp.unmount()

    // P2-4: OAuth switch preserves unsaved TOML drafts & authorize_url renders clickable https link
    const cfg = render(html`<${KeeperConfigTab} keeperName="code-reviewer-sister" onMutated=${vi.fn()} />`)
    await waitFor(() => expect(cfg.getByLabelText('keeper.activation_mode')).toBeTruthy())
    const select = cfg.getByLabelText('keeper.activation_mode') as HTMLSelectElement
    fireEvent.change(select, { target: { value: 'autonomous' } })
    expect(cfg.container.textContent).toContain('변경 1건')

    fireEvent.click(cfg.getByRole('button', { name: '끄기' }))
    await waitFor(() => expect(cfg.container.textContent).toContain('GitHub 비활성화'))
    // Draft change must still be preserved!
    expect(cfg.container.textContent).toContain('변경 1건')

    fireEvent.click(cfg.getByRole('button', { name: '연결' }))
    await waitFor(() => {
      const link = cfg.getByRole('link', { name: 'OAuth 인증 페이지 열기 ↗' }) as HTMLAnchorElement
      expect(link.href).toBe('https://slack.com/oauth/v2/authorize?client_id=123')
      expect(link.rel).toBe('noopener noreferrer')
    })
  })

  it('recovers cut-reply stream via /chat/events journal and renders Work & Sandbox tab', async () => {
    let savedNoteBody: Record<string, unknown> | null = null
    const mockFetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      const json = (data: unknown) =>
        new Response(JSON.stringify(data), { status: 200, headers: { 'Content-Type': 'application/json' } })
      if (url.includes('/chat/history/page')) return json({ messages: [], has_more: false, next_cursor: null })
      if (url.includes('/chat/operations')) return json({ operations: [] })
      if (url.includes('/api/v1/keepers/chat/stream')) {
        // Cut mid-stream without RUN_FINISHED!
        const sse = `data: ${JSON.stringify({ type: 'TEXT_MESSAGE_CONTENT', delta: 'Partial' })}\n\n`
        return new Response(sse, { status: 200, headers: { 'Content-Type': 'text/event-stream' } })
      }
      if (url.includes('/chat/events')) {
        return json({
          schema: 'masc.keeper_chat_events.v2',
          has_more: false,
          events: [
            { event: { type: 'RUN_STARTED' } },
            { event: { type: 'TEXT_MESSAGE_CONTENT', delta: 'Full recovered reply', response: { content_generation: 0, stream_scope: 0 } } },
            { event: { type: 'RUN_FINISHED' } },
          ],
        })
      }
      if (url.includes('/api/v1/dashboard/execution')) {
        return json({ tasks: [{ id: 't-1', title: 'Audit sandbox', status: 'InProgress', priority: 1, assignee: 'code-reviewer-sister', goal_id: 'g-1' }] })
      }
      if (url.includes('/tool-calls')) {
        return json({ keeper: 'code-reviewer-sister', count: 1, health: 'ok', entries: [{ ts: 100, record_kind: 'tool_call', keeper: 'code-reviewer-sister', tool: 'rg', duration_ms: 18, wire_outcome: 'ok', disposition: 'completed', input: {}, output: {} }] })
      }
      if (url.includes('/tool-stats')) {
        return json({ keeper: 'code-reviewer-sister', window_hours: 24, total_entries: 1, tools: [{ name: 'rg', call_count: 1, success_count: 1, failure_count: 0, avg_duration_ms: 18, p95_duration_ms: 18 }] })
      }
      if (url.includes('/operator-note')) {
        if (init?.method === 'POST') {
          savedNoteBody = JSON.parse(String(init.body ?? '{}')) as Record<string, unknown>
          return json({ keeper: 'code-reviewer-sister', pending: true, note: { text: savedNoteBody.text, created_by: 'op', created_at: 200, consumed_turn: null } })
        }
        return json({ keeper: 'code-reviewer-sister', pending: false, note: { text: 'Initial note', created_by: 'op', created_at: 100, consumed_turn: 5 } })
      }
      if (url.includes('/api/v1/infra/sandboxes/code-reviewer-sister')) {
        return json({
          schema_version: 1,
          instance_id: 'i1',
          generated_at_unix: 1,
          data: { keeper: 'code-reviewer-sister', probe_state: { kind: 'fresh' }, sandbox: { backend: 'microvm', running: true } },
        })
      }
      return json({ entries: [], turns: [] })
    })
    vi.stubGlobal('fetch', mockFetch)

    const chat = render(html`<${KeeperChatTab} keeper=${makeRosterKeeper()} onInspect=${vi.fn()} onMutated=${vi.fn()} />`)
    const input = chat.getByLabelText('Keeper 채팅 입력') as HTMLTextAreaElement
    fireEvent.input(input, { target: { value: 'Trigger cut stream' } })
    fireEvent.keyDown(input, { key: 'Enter' })

    await waitFor(() => {
      expect(chat.container.textContent).toContain('Full recovered reply')
      expect(chat.container.textContent).toContain('Cut_recovered')
    })
    chat.unmount()

    const ws = render(html`<${KeeperWorkSandboxTab} keeperName="code-reviewer-sister" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`)
    await waitFor(() => {
      expect(ws.container.textContent).toContain('Audit sandbox')
      expect(ws.container.textContent).toContain('microvm')
      expect(ws.container.textContent).toContain('rg')
    })

    const noteArea = ws.getByLabelText('운영자 노트 입력') as HTMLTextAreaElement
    fireEvent.input(noteArea, { target: { value: 'Prioritize tests next turn' } })
    fireEvent.click(ws.getByRole('button', { name: '운영자 노트 저장' }))
    await waitFor(() => {
      expect(savedNoteBody).toEqual({ text: 'Prioritize tests next turn' })
    })
  })
})
