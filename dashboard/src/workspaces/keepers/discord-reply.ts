import { resourceCache } from '../../core/resource-cache'
import { apiGet, apiRequest } from '../../core/transport'
import { dashboardAuthAccess } from '../../lib/dashboard-auth-access'
import type { DashboardShellResponse } from '../../types'

export interface DiscordReplyOrigin {
  readonly guildId: string | null
  readonly channelId: string
  readonly messageId: string
}

export interface DiscordReplyTarget {
  readonly keeperName: string
  readonly chatId: string
  readonly origin: DiscordReplyOrigin
}

export interface DiscordReplyWorkspace {
  readonly base_path: string
  readonly masc_root: string
}

export interface DiscordReplyAuthority {
  readonly actor: string
  readonly workspace: DiscordReplyWorkspace
}

export type DiscordReplyReceipt =
  | { readonly state: 'sending' | 'outcome_unknown' }
  | { readonly state: 'delivered'; readonly messageId: string }
  | { readonly state: 'refused'; readonly reason: 'binding_changed' | 'discord_unconfigured' | 'discord_rejected' }

export const DISCORD_REPLY_CONTENT_LIMIT = 2000

function record(raw: unknown): raw is Record<string, unknown> {
  return typeof raw === 'object' && raw !== null && !Array.isArray(raw)
}

function snowflake(raw: unknown): raw is string {
  return typeof raw === 'string' && /^[1-9][0-9]*$/.test(raw)
}

export async function readDiscordOperator(): Promise<DiscordReplyAuthority | null> {
  const observation = await resourceCache.fetch('keepers:discord-operator', signal =>
    apiGet<DashboardShellResponse & { paths?: unknown }>('/api/v1/dashboard/shell?light=true', { signal }),
  )
  if (observation.kind !== 'value') return null
  const { auth, paths } = observation.data
  if (!auth?.enabled || !auth.require_token || !auth.token_valid || !dashboardAuthAccess(auth, 'admin').allowed) return null
  const actor = auth.token_agent ?? auth.effective_agent
  if (!actor || !record(paths)) return null
  const { effective_base_path: base, effective_masc_root: root } = paths
  if (typeof base !== 'string' || !base.startsWith('/') || typeof root !== 'string' || !root.startsWith('/')) return null
  return { actor, workspace: { base_path: base, masc_root: root } }
}

export function decodeDiscordReplyOrigin(surface: unknown, messageId: unknown): DiscordReplyOrigin | null {
  if (!record(surface) || surface.kind !== 'discord' || !snowflake(surface.channel_id) || !snowflake(messageId)) return null
  const { guild_id: guildId, channel_id: channelId, parent_channel_id: parent, thread_id: thread } = surface
  if (guildId != null && !snowflake(guildId)) return null
  if (parent == null ? thread != null : !snowflake(parent) || parent === channelId || thread !== channelId) return null
  return { guildId: guildId ?? null, channelId, messageId }
}

export function discordMessageUrl(origin: DiscordReplyOrigin, messageId: string): string {
  return `https://discord.com/channels/${origin.guildId ?? '@me'}/${origin.channelId}/${messageId}`
}

function decodeReceipt(raw: unknown, target: DiscordReplyTarget, operationId: string): DiscordReplyReceipt {
  if (!record(raw) || raw.operation_id !== operationId || raw.keeper_name !== target.keeperName
      || raw.chat_id !== target.chatId || raw.channel_id !== target.origin.channelId
      || raw.original_message_id !== target.origin.messageId) {
    throw new Error('Discord 전송 결과의 대상이 요청과 일치하지 않습니다.')
  }
  switch (raw.state) {
    case 'sending':
    case 'outcome_unknown':
      return { state: raw.state }
    case 'delivered':
      if (snowflake(raw.message_id)) return { state: raw.state, messageId: raw.message_id }
      break
    case 'refused':
      if (raw.reason === 'binding_changed' || raw.reason === 'discord_unconfigured' || raw.reason === 'discord_rejected') {
        return { state: raw.state, reason: raw.reason }
      }
      break
  }
  throw new Error('Discord 전송 결과 형식을 읽을 수 없습니다.')
}

export function requestDiscordReply(
  workspace: DiscordReplyWorkspace,
  target: DiscordReplyTarget,
  operationId: string,
  request: { readonly kind: 'send'; readonly content: string } | { readonly kind: 'status' },
  signal: AbortSignal,
) {
  const receiptAddress = { expected_workspace: workspace, operation_id: operationId }
  return apiRequest({
    method: 'POST',
    path: `/api/v1/keepers/discord/reply${request.kind === 'status' ? '/status' : ''}`,
    body: request.kind === 'status' ? receiptAddress : {
      ...receiptAddress,
      keeper_name: target.keeperName,
      chat_id: target.chatId,
      content: request.content,
    },
    signal,
    decode: raw => decodeReceipt(raw, target, operationId),
  })
}
