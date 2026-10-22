import { asNumber, asString, isRecord } from './components/common/normalize'
import type {
  KeeperConversationDetails,
  KeeperExternalEffectTarget,
  KeeperTurnOutcome,
} from './types'

// RFC-0232 P2: closed decode of the producer-typed `turn_outcome` label.
// Missing field (older server) or unknown label decodes to null, which
// consumers treat as a visible reply — the bitten failure mode (#20870)
// was a reply silently dropped, so decode failure fails toward showing.
function normalizeKeeperTurnOutcome(value: unknown): KeeperTurnOutcome | null {
  switch (asString(value, '').trim()) {
    case 'visible_reply':
      return 'visible_reply'
    case 'continuation_checkpoint':
      return 'continuation_checkpoint'
    case 'waiting_for_input':
      return 'waiting_for_input'
    case 'external_effect_completed':
      return 'external_effect_completed'
    case 'external_effect_pending':
      return 'external_effect_pending'
    case 'no_visible_reply':
      return 'no_visible_reply'
    default:
      return null
  }
}

// Closed decode of the reply payload's `external_effect_target` /
// KEEPER_EXTERNAL_EFFECT_COMPLETED target. The reply payload carries the
// field only when the turn completed an external effect; a missing field or
// any malformed shape decodes to null and the card keeps its generic copy
// instead of guessing a destination.
export function normalizeKeeperExternalEffectTarget(
  value: unknown,
): KeeperExternalEffectTarget | null {
  if (!isRecord(value)) return null
  const kind = asString(value.kind, '').trim()
  if (kind === 'dashboard') return { kind: 'dashboard' }
  // The stored normalized shape camel-cases these keys; the wire payload
  // snake-cases them. Accept both so a persisted draft restores its target.
  const channelId = (asString(value.channel_id) ?? asString(value.channelId))?.trim() ?? ''
  if (!channelId) return null
  if (kind === 'discord') return { kind: 'discord', channelId }
  if (kind === 'slack') {
    const threadTs = (asString(value.thread_ts) ?? asString(value.threadTs))?.trim() ?? ''
    return { kind: 'slack', channelId, threadTs: threadTs || null }
  }
  return null
}

function normalizeKeeperUsage(raw: unknown): NonNullable<KeeperConversationDetails['usage']> | null {
  if (!isRecord(raw)) return null
  // The server's wire payload snake-cases these keys; the normalized shape
  // persisted with an in-flight assistant draft camel-cases them. Reading both
  // keeps usage metadata intact when a draft is restored after a reload.
  const usage: NonNullable<KeeperConversationDetails['usage']> = {
    inputTokens: asNumber(raw.input_tokens) ?? asNumber(raw.inputTokens) ?? null,
    outputTokens: asNumber(raw.output_tokens) ?? asNumber(raw.outputTokens) ?? null,
    totalTokens: asNumber(raw.total_tokens) ?? asNumber(raw.totalTokens) ?? null,
  }
  const cacheCreationInputTokens = asNumber(raw.cache_creation_input_tokens) ?? asNumber(raw.cacheCreationInputTokens)
  const cacheReadInputTokens = asNumber(raw.cache_read_input_tokens) ?? asNumber(raw.cacheReadInputTokens)
  const costUsd = asNumber(raw.cost_usd) ?? asNumber(raw.costUsd)
  if (cacheCreationInputTokens !== undefined) {
    usage.cacheCreationInputTokens = cacheCreationInputTokens
  }
  if (cacheReadInputTokens !== undefined) {
    usage.cacheReadInputTokens = cacheReadInputTokens
  }
  if (costUsd !== undefined) usage.costUsd = costUsd
  return usage
}

export function keeperTurnOutcomeSuppressesReply(
  outcome: KeeperTurnOutcome | null | undefined,
): boolean {
  return outcome === 'continuation_checkpoint'
    || outcome === 'waiting_for_input'
    || outcome === 'external_effect_completed'
    || outcome === 'external_effect_pending'
    || outcome === 'no_visible_reply'
}

export function normalizeKeeperConversationDetails(raw: unknown): KeeperConversationDetails | null {
  const payload = (() => {
    if (!isRecord(raw)) return null
    const nested = raw.raw_payload
    return isRecord(nested) ? nested : raw
  })()
  if (!payload) return null

  const reply = asString(payload.reply, '')
  const usage = normalizeKeeperUsage(payload.usage)

  return {
    // Each field falls back from the server's snake-case wire key to the
    // camel-case key of the normalized shape persisted with an in-flight
    // draft, so restoring that draft keeps continuation state and provider
    // metadata instead of decoding them back to nulls.
    traceId: asString(payload.trace_id) ?? asString(payload.traceId) ?? null,
    turnRef: asString(payload.turn_ref) ?? asString(payload.turnRef) ?? null,
    providerMessageId: asString(payload.provider_message_id) ?? asString(payload.providerMessageId) ?? null,
    modelUsed: asString(payload.model_used) ?? asString(payload.model) ?? asString(payload.modelUsed) ?? null,
    stopReason: asString(payload.stop_reason) ?? asString(payload.stopReason) ?? null,
    latencyMs: asNumber(payload.latency_ms) ?? asNumber(payload.latencyMs) ?? null,
    costUsd: asNumber(payload.cost_usd) ?? usage?.costUsd ?? asNumber(payload.costUsd) ?? null,
    usage,
    replyText: asString(payload.replyText) ?? (reply.trim() ? reply : null),
    turnOutcome: normalizeKeeperTurnOutcome(payload.turn_outcome) ?? normalizeKeeperTurnOutcome(payload.turnOutcome),
    externalEffectTarget: normalizeKeeperExternalEffectTarget(
      payload.external_effect_target ?? payload.externalEffectTarget,
    ),
    rawPayload: payload,
  }
}

export function normalizeKeeperToolResponse(raw: string): {
  text: string
  details: KeeperConversationDetails | null
} {
  const trimmed = raw.trim()
  if (!trimmed.startsWith('{')) {
    return {
      text: raw,
      details: null,
    }
  }

  try {
    const payload = JSON.parse(trimmed) as unknown
    const details = normalizeKeeperConversationDetails(payload)
    const parsed = isRecord(payload) ? asString(payload.reply, raw) : raw
    return {
      text: parsed,
      details,
    }
  } catch {
    return {
      text: raw,
      details: null,
    }
  }
}
