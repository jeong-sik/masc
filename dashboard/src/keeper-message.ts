import { asNumber, asString, isRecord } from './components/common/normalize'
import type {
  KeeperConversationDetails,
  KeeperExternalEffectTarget,
  KeeperTurnOutcome,
} from './types'

function stripSkillRouteLines(text: string): string {
  return text
    .split('\n')
    .filter(line => {
      const trimmed = line.trim()
      return !trimmed.startsWith('SKILL')
    })
    .join('\n')
}

export function formatKeeperVisibleReply(reply: string): string {
  return stripSkillRouteLines(reply).replace(/\n{3,}/g, '\n\n').trim()
}

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
  const channelId = asString(value.channel_id, '').trim()
  if (!channelId) return null
  if (kind === 'discord') return { kind: 'discord', channelId }
  if (kind === 'slack') {
    const threadTs = asString(value.thread_ts, '').trim()
    return { kind: 'slack', channelId, threadTs: threadTs || null }
  }
  return null
}

function normalizeKeeperUsage(raw: unknown): NonNullable<KeeperConversationDetails['usage']> | null {
  if (!isRecord(raw)) return null
  const usage: NonNullable<KeeperConversationDetails['usage']> = {
    inputTokens: asNumber(raw.input_tokens) ?? null,
    outputTokens: asNumber(raw.output_tokens) ?? null,
    totalTokens: asNumber(raw.total_tokens) ?? null,
  }
  const cacheCreationInputTokens = asNumber(raw.cache_creation_input_tokens)
  const cacheReadInputTokens = asNumber(raw.cache_read_input_tokens)
  const costUsd = asNumber(raw.cost_usd)
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

  const reply = asString(payload.reply) ?? ''
  const usage = normalizeKeeperUsage(payload.usage)

  return {
    traceId: asString(payload.trace_id) ?? null,
    turnRef: asString(payload.turn_ref) ?? null,
    providerMessageId: asString(payload.provider_message_id) ?? null,
    generation: asNumber(payload.generation) ?? null,
    modelUsed: asString(payload.model_used) ?? asString(payload.model) ?? null,
    stopReason: asString(payload.stop_reason) ?? null,
    latencyMs: asNumber(payload.latency_ms) ?? null,
    costUsd: asNumber(payload.cost_usd) ?? usage?.costUsd ?? null,
    usage,
    replyText: reply || null,
    turnOutcome: normalizeKeeperTurnOutcome(payload.turn_outcome),
    externalEffectTarget: normalizeKeeperExternalEffectTarget(
      payload.external_effect_target,
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
      text: formatKeeperVisibleReply(trimmed),
      details: null,
    }
  }

  try {
    const payload = JSON.parse(trimmed) as unknown
    const details = normalizeKeeperConversationDetails(payload)
    const parsed = isRecord(payload) ? (asString(payload.reply) ?? trimmed) : trimmed
    return {
      text: formatKeeperVisibleReply(parsed),
      details,
    }
  } catch {
    return {
      text: formatKeeperVisibleReply(trimmed),
      details: null,
    }
  }
}
