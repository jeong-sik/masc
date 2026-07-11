// notifications.ts — browser Notification delivery for a closed subset of
// typed dashboard SSE events (masc issue #54).
//
// This module is the SSOT for "should a browser notification fire": it owns
// both halves of that decision — the per-event-kind opt-in rules (persisted
// client-side; there is no server config to shadow, so browser-local
// storage IS the routing table, same classification as theme/density) and
// the Notification.permission lifecycle. The Settings→Notify panel is a
// thin view over the exports here, not a second source of truth.
//
// Deliberately NOT a heuristic: there is no score, no keyword weighting, no
// threshold. A notification fires iff (a) the browser granted permission,
// (b) the user opted into that specific typed event kind, and (c) a
// matching SSE event arrived. The previous keeper alert fanout scored
// interestingness with keyword weights (removed in #23929) — that pattern
// is deliberately not resurrected here.

import { signal } from '@preact/signals'
import { lastEvent, normalizeSSEDispatchType } from './sse'
import { parseOasPayload } from './schemas/sse-event-payload'
import { persistentSignal } from './lib/persistent-signal'
import { assertExhaustive } from './lib/exhaustive'
import { errorToString } from './lib/format-string'
import type { SSEEvent } from './types'

/** Closed subset of SSEEventType this module knows how to notify on. Adding
 *  a kind requires a matching arm in every exhaustive switch below —
 *  TypeScript's assertExhaustive fails the build otherwise (mirrors the
 *  OCaml FSM-sparse-match guard; see software-development.md). */
export type NotifyEventKind =
  | 'keeper_guardrail'
  | 'keeper_handoff'
  | 'approval:pending'
  | 'oas:agent_failed'

export const NOTIFY_EVENT_KINDS: readonly NotifyEventKind[] = [
  'keeper_guardrail',
  'keeper_handoff',
  'approval:pending',
  'oas:agent_failed',
]

export const NOTIFY_EVENT_LABELS: Record<NotifyEventKind, string> = {
  keeper_guardrail: 'Keeper guardrail triggered',
  keeper_handoff: 'Keeper handoff',
  'approval:pending': 'HITL approval pending',
  'oas:agent_failed': 'OAS agent run failed',
}

function toNotifyEventKind(rawType: string): NotifyEventKind | null {
  const type = normalizeSSEDispatchType(rawType)
  switch (type) {
    case 'keeper_guardrail':
    case 'keeper_handoff':
    case 'approval:pending':
    case 'oas:agent_failed':
      return type
    default:
      return null
  }
}

// --- Permission ---

export type NotificationPermissionState = 'unsupported' | 'default' | 'granted' | 'denied'

function notificationApiAvailable(): boolean {
  return typeof window !== 'undefined' && 'Notification' in window
}

function currentBrowserPermission(): NotificationPermissionState {
  return notificationApiAvailable() ? (window.Notification.permission as NotificationPermissionState) : 'unsupported'
}

/** Mirrors the browser's own permission state. Not persisted on our side —
 *  the browser already persists it across reloads, and caching a stale
 *  'granted' here would lie to the UI after the user revokes it from
 *  browser chrome (no event fires for that; re-read on demand instead). */
export const notificationPermission = signal<NotificationPermissionState>(currentBrowserPermission())
export const notificationDeliveryError = signal<string | null>(null)

/** Refresh the signal from the live browser state. Call when the Notify
 *  panel mounts so a permission change made outside the tab (browser
 *  settings) is reflected instead of showing a stale cached value. */
export function refreshNotificationPermission(): NotificationPermissionState {
  notificationPermission.value = currentBrowserPermission()
  return notificationPermission.value
}

/** Must be invoked from a user gesture (click handler) — browsers reject or
 *  silently no-op requestPermission() calls made outside one. */
export async function requestNotificationPermission(): Promise<NotificationPermissionState> {
  if (!notificationApiAvailable()) {
    notificationPermission.value = 'unsupported'
    return 'unsupported'
  }
  try {
    const result = await window.Notification.requestPermission()
    notificationPermission.value = result as NotificationPermissionState
    notificationDeliveryError.value = null
  } catch (error) {
    // Some engines throw instead of resolving 'denied' when the call is
    // rejected outright (e.g. blocked by a site permission policy).
    notificationPermission.value = 'denied'
    notificationDeliveryError.value = errorToString(error)
  }
  return notificationPermission.value
}

// --- Rules (per-event-kind opt-in) ---

const NOTIFY_RULES_STORAGE_KEY = 'dashboard:notify:rules-v1'

const DEFAULT_NOTIFY_RULES: Record<NotifyEventKind, boolean> = {
  keeper_guardrail: true,
  keeper_handoff: true,
  'approval:pending': true,
  'oas:agent_failed': true,
}

function decodeNotifyRules(raw: string): Record<NotifyEventKind, boolean> {
  const parsed: unknown = JSON.parse(raw)
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new TypeError('notification rules must be an object')
  }
  const record = parsed as Record<string, unknown>
  return {
    keeper_guardrail:
      typeof record.keeper_guardrail === 'boolean'
        ? record.keeper_guardrail
        : DEFAULT_NOTIFY_RULES.keeper_guardrail,
    keeper_handoff:
      typeof record.keeper_handoff === 'boolean'
        ? record.keeper_handoff
        : DEFAULT_NOTIFY_RULES.keeper_handoff,
    'approval:pending':
      typeof record['approval:pending'] === 'boolean'
        ? record['approval:pending']
        : DEFAULT_NOTIFY_RULES['approval:pending'],
    'oas:agent_failed':
      typeof record['oas:agent_failed'] === 'boolean'
        ? record['oas:agent_failed']
        : DEFAULT_NOTIFY_RULES['oas:agent_failed'],
  }
}

export const notifyRules = persistentSignal<Record<NotifyEventKind, boolean>>({
  key: NOTIFY_RULES_STORAGE_KEY,
  defaultValue: DEFAULT_NOTIFY_RULES,
  deserialize: decodeNotifyRules,
})

export function isNotifyRuleEnabled(kind: NotifyEventKind): boolean {
  return notifyRules.value[kind] ?? DEFAULT_NOTIFY_RULES[kind]
}

export function setNotifyRuleEnabled(kind: NotifyEventKind, enabled: boolean): void {
  notifyRules.value = { ...notifyRules.value, [kind]: enabled }
}

// --- Event -> notification content mapping ---

interface NotifyContent {
  title: string
  body: string
  /** Identity used for Notification `tag` coalescing (browser-owned, not a
   *  homemade dedup window — repeat events with the same tag replace the
   *  prior notification instead of stacking). */
  identity: string
}

function keeperIdentity(event: SSEEvent): string {
  return event.name ?? event.agent ?? event.keeper_name ?? 'keeper'
}

function describeAgentFailed(event: SSEEvent): NotifyContent {
  const parsed = parseOasPayload('oas:agent_failed', event.payload)
  if (!parsed.success || parsed.data.kind !== 'agent_failed') {
    return {
      title: NOTIFY_EVENT_LABELS['oas:agent_failed'],
      body: 'An OAS agent run failed (payload did not match the typed schema).',
      identity: event.agent ?? 'oas-agent',
    }
  }
  const { agent_name, task_id, error } = parsed.data.payload
  return {
    title: NOTIFY_EVENT_LABELS['oas:agent_failed'],
    body: `${agent_name}${task_id ? ` · ${task_id}` : ''}${error ? `: ${error}` : ''}`,
    identity: agent_name,
  }
}

function describeNotifyEvent(kind: NotifyEventKind, event: SSEEvent): NotifyContent {
  switch (kind) {
    case 'keeper_guardrail':
      return {
        title: NOTIFY_EVENT_LABELS.keeper_guardrail,
        body: `${keeperIdentity(event)}: ${event.reason ?? '(unknown reason)'}`,
        identity: keeperIdentity(event),
      }
    case 'keeper_handoff':
      return {
        title: NOTIFY_EVENT_LABELS.keeper_handoff,
        body: `${keeperIdentity(event)} — gen ${event.from_generation ?? '?'} → ${event.to_generation ?? '?'}`,
        identity: keeperIdentity(event),
      }
    case 'approval:pending':
      return {
        title: NOTIFY_EVENT_LABELS['approval:pending'],
        body: 'A human approval is waiting for review.',
        identity: 'approvals',
      }
    case 'oas:agent_failed':
      return describeAgentFailed(event)
    default:
      return assertExhaustive(kind, 'NotifyEventKind')
  }
}

// --- Delivery ---

function deliverBrowserNotification(kind: NotifyEventKind, event: SSEEvent): void {
  if (!notificationApiAvailable()) return
  if (refreshNotificationPermission() !== 'granted') return
  if (!isNotifyRuleEnabled(kind)) return
  const { title, body, identity } = describeNotifyEvent(kind, event)
  try {
    void new window.Notification(title, { body, tag: `${kind}:${identity}` })
    notificationDeliveryError.value = null
  } catch (err) {
    const detail = errorToString(err)
    notificationDeliveryError.value = detail
    console.warn('[notifications] failed to show browser notification', detail)
  }
}

/** Wire this once at app boot (mirrors setupSSEReaction / handleHarnessSSE)
 *  so delivery keeps working regardless of which settings section, tab, or
 *  panel is currently mounted. Returns the unsubscribe function. */
export function initNotificationDelivery(): () => void {
  return lastEvent.subscribe((event) => {
    if (!event) return
    const kind = toNotifyEventKind(event.type)
    if (!kind) return
    deliverBrowserNotification(kind, event)
  })
}
