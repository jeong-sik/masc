import type { KeeperApprovalContinuationChannel, KeeperApprovalOrigin } from '../types'
import { isRecord } from './type-guards'

function exactKeys(raw: Record<string, unknown>, required: string[], optional: string[] = []): boolean {
  return required.every(key => Object.hasOwn(raw, key))
    && Object.keys(raw).every(key => required.includes(key) || optional.includes(key))
}

function nonblank(value: unknown): value is string {
  return typeof value === 'string' && value.trim() !== ''
}

export function normalizeKeeperApprovalOrigin(raw: unknown): KeeperApprovalOrigin | null {
  if (!isRecord(raw) || !exactKeys(raw, ['source', 'turn_ref']) || !isRecord(raw.source)) return null
  const source = raw.source
  if (source.kind === 'no_admitted_source') {
    return raw.turn_ref === null && exactKeys(source, ['kind'])
      ? { source: { kind: 'no_admitted_source' }, turn_ref: null }
      : null
  }
  // Turn_ref is an opaque join key. Validate its canonical scalar envelope,
  // while the host retains authority for its trace/absolute-turn identity.
  if (!nonblank(raw.turn_ref) || !/^.+#-?(0|[1-9][0-9]*)$/.test(raw.turn_ref)) return null
  if (source.kind === 'direct_operation') {
    if (!exactKeys(source, ['kind', 'operation_id']) || typeof source.operation_id !== 'string'
      || !/^[A-Za-z0-9_.-]{1,128}$/.test(source.operation_id)
      || source.operation_id === '.' || source.operation_id === '..') return null
    return { source: { kind: 'direct_operation', operation_id: source.operation_id }, turn_ref: raw.turn_ref }
  }
  if (source.kind !== 'admitted_sources' || !exactKeys(source, ['kind', 'sources'])
    || !Array.isArray(source.sources) || source.sources.length === 0) return null
  const seen = new Set<string>()
  const sources: Extract<KeeperApprovalOrigin['source'], { kind: 'admitted_sources' }>['sources'] = []
  for (const item of source.sources) {
    if (!isRecord(item) || !exactKeys(item, ['snapshot_ref', 'admitted_revision', 'board_post_id'])
      || typeof item.snapshot_ref !== 'string' || !/^[a-f0-9]{64}$/.test(item.snapshot_ref)
      || typeof item.admitted_revision !== 'string' || !/^(0|[1-9][0-9]*)$/.test(item.admitted_revision)
      || BigInt(item.admitted_revision) > 9223372036854775807n
      || (item.board_post_id !== null && (!nonblank(item.board_post_id) || item.board_post_id.trim() !== item.board_post_id))) return null
    const key = `${item.snapshot_ref}@${item.admitted_revision}`
    if (seen.has(key)) return null
    seen.add(key)
    sources.push({ snapshot_ref: item.snapshot_ref, admitted_revision: item.admitted_revision, board_post_id: item.board_post_id })
  }
  return { source: { kind: 'admitted_sources', sources }, turn_ref: raw.turn_ref }
}

export function normalizeKeeperApprovalContinuationChannel(raw: unknown): KeeperApprovalContinuationChannel | null {
  if (!isRecord(raw)) return null
  switch (raw.kind) {
    case 'dashboard':
      return exactKeys(raw, ['kind', 'thread_id']) && nonblank(raw.thread_id)
        ? { kind: 'dashboard', thread_id: raw.thread_id } : null
    case 'keeper':
      return exactKeys(raw, ['kind', 'keeper_name']) && nonblank(raw.keeper_name)
        ? { kind: 'keeper', keeper_name: raw.keeper_name } : null
    case 'unrouted':
      return exactKeys(raw, ['kind', 'reason']) && nonblank(raw.reason)
        ? { kind: 'unrouted', reason: raw.reason } : null
    case 'discord': {
      const optional = ['guild_id', 'parent_channel_id', 'thread_id', 'reply_to_message_id'] as const
      if (!exactKeys(raw, ['kind', 'channel_id', 'user_id'], [...optional])
        || !nonblank(raw.channel_id) || !nonblank(raw.user_id)
        || optional.some(key => Object.hasOwn(raw, key) && !nonblank(raw[key]))) return null
      return { kind: 'discord', channel_id: raw.channel_id, user_id: raw.user_id,
        ...Object.fromEntries(optional.filter(key => Object.hasOwn(raw, key)).map(key => [key, raw[key]])) }
    }
    case 'slack': {
      const optional = ['team_id', 'thread_ts'] as const
      if (!exactKeys(raw, ['kind', 'channel_id', 'user_id'], [...optional])
        || !nonblank(raw.channel_id) || !nonblank(raw.user_id)
        || optional.some(key => Object.hasOwn(raw, key) && !nonblank(raw[key]))) return null
      return { kind: 'slack', channel_id: raw.channel_id, user_id: raw.user_id,
        ...Object.fromEntries(optional.filter(key => Object.hasOwn(raw, key)).map(key => [key, raw[key]])) }
    }
    case 'imessage':
      if (!exactKeys(raw, ['kind', 'chat_identifier', 'user_id'], ['chat_guid'])
        || !nonblank(raw.chat_identifier) || !nonblank(raw.user_id)
        || (Object.hasOwn(raw, 'chat_guid') && !nonblank(raw.chat_guid))) return null
      return { kind: 'imessage', chat_identifier: raw.chat_identifier, user_id: raw.user_id,
        ...(typeof raw.chat_guid === 'string' ? { chat_guid: raw.chat_guid } : {}) }
    default: return null
  }
}

export function approvalOriginSummary(origin: KeeperApprovalOrigin): string {
  switch (origin.source.kind) {
    case 'direct_operation': return `직접 요청 · ${origin.source.operation_id}`
    case 'admitted_sources': {
      const posts = [...new Set(origin.source.sources.flatMap(source => source.board_post_id === null ? [] : [source.board_post_id]))]
      const intake = `접수된 입력 ${origin.source.sources.length}건`
      return posts.length ? `${intake} · Board ${posts.join(', ')}` : intake
    }
    case 'no_admitted_source': return '요청 출처 확인 불가'
  }
}

export function approvalContinuationLabel(channel: KeeperApprovalContinuationChannel): string {
  switch (channel.kind) {
    case 'dashboard': return `Dashboard · ${channel.thread_id}`
    case 'discord': return `Discord · ${channel.channel_id}${channel.thread_id ? ` / ${channel.thread_id}` : ''}`
    case 'slack': return `Slack · ${channel.channel_id}${channel.thread_ts ? ` / ${channel.thread_ts}` : ''}`
    case 'imessage': return `iMessage · ${channel.chat_identifier}`
    case 'keeper': return `Keeper · ${channel.keeper_name}`
    case 'unrouted': return `응답 경로 확인 불가 · ${channel.reason}`
  }
}
