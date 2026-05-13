import { asNumber, asString, isRecord } from './components/common/normalize'
import type { KeeperConversationDetails } from './types'

const STATE_START = '[STATE]'
const STATE_END = '[/STATE]'

function extractStateBlock(text: string): string | null {
  const start = text.indexOf(STATE_START)
  if (start < 0) return null
  const bodyStart = start + STATE_START.length
  const end = text.indexOf(STATE_END, bodyStart)
  if (end < 0) return null
  const state = text.slice(bodyStart, end).trim()
  return state || null
}

export function stripStateBlocks(text: string): string {
  let next = text
  for (;;) {
    const start = next.indexOf(STATE_START)
    if (start < 0) return next
    const end = next.indexOf(STATE_END, start + STATE_START.length)
    if (end < 0) return next.slice(0, start)
    next = `${next.slice(0, start)}${next.slice(end + STATE_END.length)}`
  }
}

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
  const withoutSkill = stripSkillRouteLines(reply)
  const withoutState = stripStateBlocks(withoutSkill)
  return withoutState.replace(/\n{3,}/g, '\n\n').trim()
}

export function normalizeKeeperConversationDetails(raw: unknown): KeeperConversationDetails | null {
  const payload = (() => {
    if (!isRecord(raw)) return null
    const nested = raw.raw_payload
    return isRecord(nested) ? nested : raw
  })()
  if (!payload) return null

  const reply = asString(payload.reply) ?? ''
  const stateBlock = reply ? extractStateBlock(reply) : null
  const usage = isRecord(payload.usage)
    ? {
        inputTokens: asNumber(payload.usage.input_tokens) ?? null,
        outputTokens: asNumber(payload.usage.output_tokens) ?? null,
        totalTokens: asNumber(payload.usage.total_tokens) ?? null,
      }
    : null

  return {
    traceId: asString(payload.trace_id) ?? null,
    generation: asNumber(payload.generation) ?? null,
    modelUsed: null,
    latencyMs: asNumber(payload.latency_ms) ?? null,
    costUsd: asNumber(payload.cost_usd) ?? null,
    usage,
    skillPrimary: asString(payload.skill_primary) ?? null,
    skillReason: asString(payload.skill_reason) ?? null,
    stateBlock,
    replyText: reply || null,
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
