import { computed, signal, type ReadonlySignal } from '@preact/signals'
import { fetchSocialGraph } from './api'
import type { SocialEvent, SocialGraphSnapshot } from './types'

const SOCIAL_SESSION_KEY = 'masc_dashboard_social_session_id'
const RECONNECT_BASE_MS = 1000
const RECONNECT_MAX_MS = 15000
const MAX_TIMELINE_EVENTS = 180

export const socialGraph = signal<SocialGraphSnapshot | null>(null)
export const socialGraphLoading = signal(false)
export const socialGraphError = signal<string | null>(null)
export const socialStreamConnected = signal(false)
export const socialStreamEventCount = signal(0)
export const socialLastEvent = signal<SocialEvent | null>(null)
export const socialTimeline = signal<SocialEvent[]>([])

let source: EventSource | null = null
let reconnectTimer: ReturnType<typeof setTimeout> | null = null
let refreshTimer: ReturnType<typeof setTimeout> | null = null
let reconnectAttempts = 0

function getOrCreateSessionId(): string {
  let sid = sessionStorage.getItem(SOCIAL_SESSION_KEY)
  if (!sid) {
    sid = typeof crypto.randomUUID === 'function'
      ? `social_${crypto.randomUUID()}`
      : `social_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 10)}`
    sessionStorage.setItem(SOCIAL_SESSION_KEY, sid)
  }
  return sid
}

function normalizeSeq(event: SocialEvent, fallback: string): SocialEvent {
  if (typeof event.seq === 'number') return event
  const parsed = Number.parseInt(fallback, 10)
  return Number.isFinite(parsed) ? { ...event, seq: parsed } : event
}

function mergeEvents(primary: SocialEvent[], secondary: SocialEvent[]): SocialEvent[] {
  const merged = new Map<number, SocialEvent>()
  for (const event of [...secondary, ...primary]) {
    if (typeof event.seq !== 'number') continue
    merged.set(event.seq, event)
  }
  return Array.from(merged.values())
    .sort((a, b) => (b.seq ?? 0) - (a.seq ?? 0))
    .slice(0, MAX_TIMELINE_EVENTS)
}

function scheduleReconnect(): void {
  if (reconnectTimer) return
  reconnectAttempts += 1
  const delay = Math.min(RECONNECT_MAX_MS, RECONNECT_BASE_MS * Math.pow(2, Math.min(reconnectAttempts, 5)))
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null
    connectSocialStream()
  }, delay)
}

function clearReconnectTimer(): void {
  if (reconnectTimer) {
    clearTimeout(reconnectTimer)
    reconnectTimer = null
  }
}

function scheduleSnapshotRefresh(): void {
  if (refreshTimer) return
  refreshTimer = setTimeout(() => {
    refreshTimer = null
    void refreshSocialGraph()
  }, 350)
}

function streamUrl(): string {
  const input = new URLSearchParams(window.location.search)
  const params = new URLSearchParams()
  const agent = input.get('agent') ?? input.get('agent_name')
  const token = input.get('token')
  if (agent) params.set('agent', agent)
  if (token) params.set('token', token)
  params.set('session_id', getOrCreateSessionId())
  return `/api/v1/events/stream?${params.toString()}`
}

function appendLiveEvent(event: SocialEvent): void {
  socialStreamEventCount.value += 1
  socialLastEvent.value = event
  socialTimeline.value = mergeEvents([event], socialTimeline.value)
}

export async function refreshSocialGraph(): Promise<void> {
  socialGraphLoading.value = true
  socialGraphError.value = null
  try {
    const snapshot = await fetchSocialGraph()
    socialGraph.value = snapshot
    socialTimeline.value = mergeEvents(snapshot.timeline ?? [], socialTimeline.value)
  } catch (err) {
    socialGraphError.value = err instanceof Error ? err.message : 'failed to load social graph'
  } finally {
    socialGraphLoading.value = false
  }
}

export function connectSocialStream(): void {
  clearReconnectTimer()
  if (source) {
    source.close()
    source = null
  }

  const es = new EventSource(streamUrl())
  source = es

  es.onopen = () => {
    if (source !== es) return
    reconnectAttempts = 0
    socialStreamConnected.value = true
  }

  es.onerror = () => {
    if (source !== es) return
    socialStreamConnected.value = false
    es.close()
    source = null
    scheduleReconnect()
  }

  es.onmessage = (message: MessageEvent) => {
    try {
      const raw = JSON.parse(message.data as string) as SocialEvent
      const event = normalizeSeq(raw, message.lastEventId)
      appendLiveEvent(event)
      scheduleSnapshotRefresh()
    } catch {
      // Keepalive comment or malformed payload.
    }
  }
}

export function disconnectSocialStream(): void {
  clearReconnectTimer()
  if (refreshTimer) {
    clearTimeout(refreshTimer)
    refreshTimer = null
  }
  if (source) {
    source.close()
    source = null
  }
  socialStreamConnected.value = false
}

export const socialNodes: ReadonlySignal<SocialGraphSnapshot['nodes']> = computed(() =>
  socialGraph.value?.nodes ?? [],
)

export const socialEdges: ReadonlySignal<SocialGraphSnapshot['edges']> = computed(() =>
  socialGraph.value?.edges ?? [],
)

export const socialStats: ReadonlySignal<SocialGraphSnapshot['stats'] | null> = computed(() =>
  socialGraph.value?.stats ?? null,
)
