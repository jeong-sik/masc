import { describe, expect, it } from 'vitest'

import {
  safeParseKeeperChatHistoryMessage,
  type KeeperChatHistoryMessage,
} from './keeper-chat-history'

function validMessage(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    role: 'user',
    content: 'hello keeper',
    ts: 1_712_000_000.25,
    ...overrides,
  }
}

describe('safeParseKeeperChatHistoryMessage', () => {
  it('accepts a well-formed message and returns a typed output', () => {
    const out = safeParseKeeperChatHistoryMessage(validMessage())
    expect(out).not.toBeNull()
    expect(out?.role).toBe('user')
    expect(out?.content).toBe('hello keeper')
    expect(out?.ts).toBeCloseTo(1_712_000_000.25)
  })

  it('accepts unknown role strings (open enum for backend-ahead deploys)', () => {
    const out = safeParseKeeperChatHistoryMessage(
      validMessage({ role: 'tool-result-v2' }),
    )
    expect(out?.role).toBe('tool-result-v2')
  })

  it('returns null when a required field is missing', () => {
    const { ts: _ts, ...withoutTs } = validMessage()
    expect(safeParseKeeperChatHistoryMessage(withoutTs)).toBeNull()
  })

  it('returns null when a field has the wrong type', () => {
    expect(
      safeParseKeeperChatHistoryMessage(validMessage({ ts: '1712000000' })),
    ).toBeNull()
    expect(
      safeParseKeeperChatHistoryMessage(validMessage({ content: 42 })),
    ).toBeNull()
  })

  it('returns null for non-object inputs', () => {
    expect(safeParseKeeperChatHistoryMessage(null)).toBeNull()
    expect(safeParseKeeperChatHistoryMessage('string')).toBeNull()
    expect(safeParseKeeperChatHistoryMessage(42)).toBeNull()
    expect(safeParseKeeperChatHistoryMessage(undefined)).toBeNull()
  })

  it('passes RFC-0223 speaker fields through when present', () => {
    const out = safeParseKeeperChatHistoryMessage(
      validMessage({
        source: 'discord',
        speaker_id: '98791450001',
        speaker_name: 'Minsu',
        speaker_authority: 'external',
      }),
    )
    expect(out?.speaker_id).toBe('98791450001')
    expect(out?.speaker_name).toBe('Minsu')
    expect(out?.speaker_authority).toBe('external')
  })

  it('passes connector conversation coordinates through when present', () => {
    const out = safeParseKeeperChatHistoryMessage(
      validMessage({
        source: 'discord',
        conversation_id: 'discord:guild-1:channel:1514586257706061834',
        external_message_id: '1498985300729172039',
      }),
    )
    expect(out?.conversation_id).toBe(
      'discord:guild-1:channel:1514586257706061834',
    )
    expect(out?.external_message_id).toBe('1498985300729172039')
  })

  it('passes the RFC-0233 turn_ref join key through when present', () => {
    const out = safeParseKeeperChatHistoryMessage(
      validMessage({ turn_ref: 'trace-1780648779957-00000#4071' }),
    )
    expect(out?.turn_ref).toBe('trace-1780648779957-00000#4071')
  })

  it('passes the backend stream contract read model through when present', () => {
    const out = safeParseKeeperChatHistoryMessage(
      validMessage({
        stream_contract: {
          source: 'backend_turn_trace',
          status: 'backend_trace_join',
          turn_ref: 'trace-1780648779957-00000#4071',
          trace_event_count: 2,
          delivery_receipt: 'no_delivery_receipt',
          reason: 'turn_ref joined to retained trajectory/internal-history events',
        },
      }),
    )
    expect(out?.stream_contract).toEqual({
      source: 'backend_turn_trace',
      status: 'backend_trace_join',
      turn_ref: 'trace-1780648779957-00000#4071',
      trace_event_count: 2,
      delivery_receipt: 'no_delivery_receipt',
      reason: 'turn_ref joined to retained trajectory/internal-history events',
    })
  })

  it('passes durable backend lifecycle stream contracts through when present', () => {
    const out = safeParseKeeperChatHistoryMessage(
      validMessage({
        stream_contract: {
          source: 'backend_stream_lifecycle',
          status: 'backend_lifecycle_replay',
          turn_ref: 'trace-1780648779957-00000#4071',
          event_name: 'RUN_FINISHED',
          lifecycle_events: [
            'RUN_STARTED',
            'TEXT_MESSAGE_START',
            'TEXT_MESSAGE_END',
            'RUN_FINISHED',
          ],
          delivery_receipt: 'server_lifecycle_replay_only',
          reason: 'history row records durable server stream lifecycle replay',
        },
      }),
    )
    expect(out?.stream_contract).toEqual({
      source: 'backend_stream_lifecycle',
      status: 'backend_lifecycle_replay',
      turn_ref: 'trace-1780648779957-00000#4071',
      event_name: 'RUN_FINISHED',
      lifecycle_events: [
        'RUN_STARTED',
        'TEXT_MESSAGE_START',
        'TEXT_MESSAGE_END',
        'RUN_FINISHED',
      ],
      delivery_receipt: 'server_lifecycle_replay_only',
      reason: 'history row records durable server stream lifecycle replay',
    })
  })

  it('returns null when stream_contract has the wrong shape', () => {
    expect(
      safeParseKeeperChatHistoryMessage(
        validMessage({ stream_contract: { source: 'backend_turn_trace' } }),
      ),
    ).toBeNull()
  })

  it('leaves turn_ref undefined on legacy rows without dropping the message', () => {
    const out = safeParseKeeperChatHistoryMessage(validMessage())
    expect(out).not.toBeNull()
    expect(out?.turn_ref).toBeUndefined()
  })

  it('returns null when turn_ref has the wrong type', () => {
    expect(
      safeParseKeeperChatHistoryMessage(validMessage({ turn_ref: 4071 })),
    ).toBeNull()
  })

  it('passes surface ref fields through when present', () => {
    const out = safeParseKeeperChatHistoryMessage(
      validMessage({
        source: 'discord',
        surface: {
          kind: 'discord',
          guild_id: 'guild-1',
          channel_id: 'channel-1',
          thread_id: 'thread-1',
        },
      }),
    )
    expect(out?.surface).toEqual({
      kind: 'discord',
      guild_id: 'guild-1',
      channel_id: 'channel-1',
      thread_id: 'thread-1',
    })
  })

  it('accepts rows without speaker fields (legacy and non-user lines)', () => {
    const out = safeParseKeeperChatHistoryMessage(validMessage())
    expect(out).not.toBeNull()
    expect(out?.speaker_id).toBeUndefined()
    expect(out?.speaker_authority).toBeUndefined()
  })

  it('passes the R3 producer-assigned id through when present', () => {
    const out = safeParseKeeperChatHistoryMessage(
      validMessage({ id: 'msg-0001700000000000-0' }),
    )
    expect(out?.id).toBe('msg-0001700000000000-0')
  })

  it('accepts rows without an id (pre-R3 backend during the deploy window)', () => {
    const out = safeParseKeeperChatHistoryMessage(validMessage())
    expect(out).not.toBeNull()
    expect(out?.id).toBeUndefined()
  })

  it('composes in a filter chain — drops garbage entries silently', () => {
    const raw: unknown[] = [
      validMessage(),
      validMessage({ role: 'assistant', content: 'hi', ts: 1 }),
      { role: 'user', content: 'missing ts' },
      'not an object',
      null,
      validMessage({ role: 'system', content: 'bye', ts: 2 }),
    ]
    const cleaned = raw
      .map(safeParseKeeperChatHistoryMessage)
      .filter((m): m is KeeperChatHistoryMessage => m !== null)
    expect(cleaned).toHaveLength(3)
    expect(cleaned.map(m => m.role)).toEqual(['user', 'assistant', 'system'])
  })

  it('passes RFC-0235 audio clips through (snake_case history shape)', () => {
    const out = safeParseKeeperChatHistoryMessage(
      validMessage({
        role: 'assistant',
        audio: {
          token: 'clip-123',
          audio_url: 'https://cdn.example/voice/clip-123.mp3',
          mime: 'audio/mpeg',
          duration_sec: 12.34,
          message_text: 'hello',
          device_id: ' living-room',
        },
      }),
    )
    expect(out?.audio).toEqual({
      token: 'clip-123',
      audio_url: 'https://cdn.example/voice/clip-123.mp3',
      mime: 'audio/mpeg',
      duration_sec: 12.34,
      message_text: 'hello',
      device_id: ' living-room',
    })
  })

  it('passes malformed audio objects through so the consumer can validate safely', () => {
    const out = safeParseKeeperChatHistoryMessage(
      validMessage({ audio: { token: 'only-token' } }),
    )
    expect(out).not.toBeNull()
    // The boundary keeps the raw object; normalization filters out invalid
    // clips without dropping the whole history row.
    expect(out?.audio).toEqual({ token: 'only-token' })
  })

  it('passes RFC-0235 rich blocks through when they match the known shapes', () => {
    const out = safeParseKeeperChatHistoryMessage(
      validMessage({
        role: 'assistant',
        blocks: [
          { t: 'p', html: 'hello' },
          { t: 'code', cap: 'ocaml', html: 'let x = 1', source: 'let x = 1' },
          { t: 'table', head: ['name', { v: 'count', num: true }], rows: [['a', '1']] },
          { t: 'voice', secs: 3, wave: [0.2, 0.8], transcript: 'memo' },
          { t: 'attach', name: 'clip.mp4', src: 'https://cdn.example/clip.mp4', kind: 'video' },
          { t: 'image', src: 'https://cdn.example/x.png', cap: 'screen' },
          { t: 'link', url: 'https://example.com', title: 'Example' },
          {
            t: 'trace',
            trace: [
              { kind: 'think', text: 'checking', ts: '2026-07-05T00:00:00Z' },
              { kind: 'tool', name: 'keeper_tasks_list', tool_call_id: 'tc-1', status: 'ok', args: {}, result: { ok: true } },
            ],
          },
          { t: 'thinking', content: '', redacted: true },
        ],
      }),
    )
    expect(out?.blocks).toEqual([
      { t: 'p', html: 'hello' },
      { t: 'code', cap: 'ocaml', html: 'let x = 1', source: 'let x = 1' },
      { t: 'table', head: ['name', { v: 'count', num: true }], rows: [['a', '1']] },
      { t: 'voice', secs: 3, wave: [0.2, 0.8], transcript: 'memo' },
      { t: 'attach', name: 'clip.mp4', src: 'https://cdn.example/clip.mp4', kind: 'video' },
      { t: 'image', src: 'https://cdn.example/x.png', cap: 'screen' },
      { t: 'link', url: 'https://example.com', title: 'Example' },
      {
        t: 'trace',
        trace: [
          { kind: 'think', text: 'checking', ts: '2026-07-05T00:00:00Z' },
          { kind: 'tool', name: 'keeper_tasks_list', tool_call_id: 'tc-1', status: 'ok', args: {}, result: { ok: true } },
        ],
      },
      { t: 'thinking', content: '', redacted: true },
    ])
  })

  it('passes a fusion block through and keeps run_id optional', () => {
    const withRunId = safeParseKeeperChatHistoryMessage(
      validMessage({
        role: 'assistant',
        blocks: [{ t: 'fusion', board_post_id: 'post-123', run_id: 'fus-abc' }],
      }),
    )
    expect(withRunId?.blocks).toEqual([{ t: 'fusion', board_post_id: 'post-123', run_id: 'fus-abc' }])

    const withoutRunId = safeParseKeeperChatHistoryMessage(
      validMessage({
        role: 'assistant',
        blocks: [{ t: 'fusion', board_post_id: 'post-456' }],
      }),
    )
    expect(withoutRunId?.blocks).toEqual([{ t: 'fusion', board_post_id: 'post-456' }])
  })

  it('drops the whole row when a fusion block is missing board_post_id', () => {
    const out = safeParseKeeperChatHistoryMessage(
      validMessage({
        role: 'assistant',
        blocks: [{ t: 'fusion', run_id: 'fus-orphan' }],
      }),
    )
    expect(out).toBeNull()
  })

  it('drops the whole row when blocks contain an unknown shape', () => {
    const out = safeParseKeeperChatHistoryMessage(
      validMessage({
        role: 'assistant',
        blocks: [{ t: 'unknown', src: 'x' }],
      }),
    )
    expect(out).toBeNull()
  })
})
