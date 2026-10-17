import { describe, expect, it } from 'vitest'
import {
  approvalContinuationLabel,
  approvalOriginSummary,
  normalizeKeeperApprovalContinuationChannel as channel,
  normalizeKeeperApprovalOrigin as origin,
} from './keeper-approval-origin'

const direct = { source: { kind: 'direct_operation', operation_id: 'operation-1' }, turn_ref: 'trace#12' }
const source = { snapshot_ref: 'a'.repeat(64), admitted_revision: '9223372036854775807', board_post_id: 'board-1' }
const admitted = { source: { kind: 'admitted_sources', sources: [source] }, turn_ref: 'trace#-1' }

describe('approval origin wire contract', () => {
  it('retains the three explicit origin states and their actual witnesses', () => {
    expect(origin(direct)).toEqual(direct)
    expect(origin(admitted)).toEqual(admitted)
    const unavailable = { source: { kind: 'no_admitted_source' }, turn_ref: null }
    expect(origin(unavailable)).toEqual(unavailable)
    expect(approvalOriginSummary(origin(direct)!)).toBe('직접 요청 · operation-1')
    expect(approvalOriginSummary(origin(admitted)!)).toBe('접수된 입력 1건 · Board board-1')
    expect(approvalOriginSummary(origin(unavailable)!)).toBe('요청 출처 확인 불가')
  })

  it.each([
    null,
    { source: direct.source },
    { ...direct, invented: true },
    { ...direct, source: { ...direct.source, guessed_post_id: 'post' } },
    { ...direct, turn_ref: null },
    { ...direct, turn_ref: 'trace#01' },
    { ...direct, source: { kind: 'direct_operation', operation_id: '../operation' } },
    { source: { kind: 'no_admitted_source' }, turn_ref: 'invented#1' },
    { source: { kind: 'unknown' }, turn_ref: null },
  ])('refuses malformed or invented origin fields: %j', raw => {
    expect(origin(raw)).toBeNull()
  })

  it.each([
    [],
    [{ ...source, admitted_revision: '9223372036854775808' }],
    [{ ...source, admitted_revision: '-1' }],
    [{ ...source, admitted_revision: 7 }],
    [{ ...source, admitted_revision: '07' }],
    [{ ...source, snapshot_ref: 'A'.repeat(64) }],
    [{ ...source, board_post_id: ' board-1' }],
    [{ snapshot_ref: source.snapshot_ref, admitted_revision: '1' }],
    [source, source],
  ].map(sources => ({ sources })))('refuses malformed admitted coordinates: %j', ({ sources }) => {
    expect(origin({ ...admitted, source: { kind: 'admitted_sources', sources } })).toBeNull()
  })

  it('describes admitted input without inventing a Board source', () => {
    const value = origin({ ...admitted, source: { kind: 'admitted_sources', sources: [{ ...source, board_post_id: null }] } })!
    expect(approvalOriginSummary(value)).toBe('접수된 입력 1건')
  })
})

describe('approval continuation wire contract', () => {
  it.each([
    [{ kind: 'dashboard', thread_id: 'dashboard-thread' }, 'Dashboard · dashboard-thread'],
    [{ kind: 'discord', guild_id: 'guild', channel_id: 'channel', parent_channel_id: 'parent', thread_id: 'thread', reply_to_message_id: 'message', user_id: 'user' }, 'Discord · channel / thread'],
    [{ kind: 'slack', team_id: 'team', channel_id: 'channel', thread_ts: '123.456', user_id: 'user' }, 'Slack · channel / 123.456'],
    [{ kind: 'imessage', chat_identifier: 'conversation', chat_guid: 'guid', user_id: 'user' }, 'iMessage · conversation'],
    [{ kind: 'keeper', keeper_name: 'keeper-a' }, 'Keeper · keeper-a'],
    [{ kind: 'unrouted', reason: 'no admitted reply route' }, '응답 경로 확인 불가 · no admitted reply route'],
  ])('preserves actual route fields: %j', (raw, label) => {
    const parsed = channel(raw)
    expect(parsed).toEqual(raw)
    expect(approvalContinuationLabel(parsed!)).toBe(label)
  })

  it.each([
    null,
    { kind: 'discord', channel_id: 'channel' },
    { kind: 'discord', channel_id: 'channel', user_id: 'user', thread_id: null },
    { kind: 'slack', channel_id: 'channel', user_id: 'user', thread_ts: '' },
    { kind: 'imessage', chat_identifier: 'conversation', user_id: 'user', chat_guid: 1 },
    { kind: 'dashboard', thread_id: 'thread', unknown: 'fallback' },
    { kind: 'keeper', keeper_name: ' ' },
    { kind: 'unknown', channel_id: 'channel' },
  ])('refuses missing, malformed or unknown routes: %j', raw => {
    expect(channel(raw)).toBeNull()
  })
})
