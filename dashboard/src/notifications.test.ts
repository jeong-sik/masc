// @vitest-environment happy-dom
//
// notifications.ts owns two decisions: (1) whether the browser has granted
// Notification permission, and (2) whether the operator opted into a given
// typed event kind. Both are module-level @preact/signals state seeded once
// at import time (permission from `window.Notification.permission`, rules
// from localStorage) — so most tests here reload the module fresh via
// vi.resetModules() + dynamic import, mirroring sse-store.test.ts's
// loadSseStore() pattern, to control that seed per test.

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { SSEEvent } from './types'

class MockNotification {
  static permission: NotificationPermission = 'default'
  static requestPermission = vi.fn(async () => MockNotification.permission)
  static instances: MockNotification[] = []
  readonly title: string
  readonly options?: NotificationOptions
  constructor(title: string, options?: NotificationOptions) {
    this.title = title
    this.options = options
    MockNotification.instances.push(this)
  }
}

function installMockNotification(permission: NotificationPermission = 'default'): void {
  MockNotification.permission = permission
  MockNotification.instances = []
  MockNotification.requestPermission = vi.fn(async () => MockNotification.permission)
  vi.stubGlobal('Notification', MockNotification)
}

function uninstallNotification(): void {
  vi.stubGlobal('Notification', undefined)
  Reflect.deleteProperty(window, 'Notification')
}

async function loadNotifications() {
  vi.resetModules()
  return import('./notifications')
}

function baseEvent(overrides: Partial<SSEEvent>): SSEEvent {
  return { type: 'keeper_guardrail', ...overrides } as SSEEvent
}

beforeEach(() => {
  localStorage.clear()
})

afterEach(() => {
  vi.unstubAllGlobals()
  localStorage.clear()
})

describe('notify rules (persisted, per-event-kind opt-in)', () => {
  it('defaults every known event kind to enabled', async () => {
    uninstallNotification()
    const notif = await loadNotifications()
    for (const kind of notif.NOTIFY_EVENT_KINDS) {
      expect(notif.isNotifyRuleEnabled(kind)).toBe(true)
    }
  })

  it('setNotifyRuleEnabled flips the rule and persists to localStorage', async () => {
    uninstallNotification()
    const notif = await loadNotifications()
    notif.setNotifyRuleEnabled('keeper_guardrail', false)
    expect(notif.isNotifyRuleEnabled('keeper_guardrail')).toBe(false)
    expect(notif.isNotifyRuleEnabled('keeper_handoff')).toBe(true)
    const stored = JSON.parse(localStorage.getItem('dashboard:notify:rules-v1') ?? '{}')
    expect(stored.keeper_guardrail).toBe(false)
  })

  it('round-trips a disabled rule across a fresh module load', async () => {
    uninstallNotification()
    const first = await loadNotifications()
    first.setNotifyRuleEnabled('oas:agent_failed', false)

    const second = await loadNotifications()
    expect(second.isNotifyRuleEnabled('oas:agent_failed')).toBe(false)
    expect(second.isNotifyRuleEnabled('keeper_guardrail')).toBe(true)
  })
})

describe('notification permission lifecycle', () => {
  it('reports unsupported when the browser has no Notification API', async () => {
    uninstallNotification()
    const notif = await loadNotifications()
    expect(notif.notificationPermission.value).toBe('unsupported')
    const result = await notif.requestNotificationPermission()
    expect(result).toBe('unsupported')
    expect(notif.notificationPermission.value).toBe('unsupported')
  })

  it('requests permission only on explicit call and reflects granted', async () => {
    installMockNotification('default')
    const notif = await loadNotifications()
    expect(notif.notificationPermission.value).toBe('default')
    expect(MockNotification.requestPermission).not.toHaveBeenCalled()

    MockNotification.permission = 'granted'
    const result = await notif.requestNotificationPermission()

    expect(MockNotification.requestPermission).toHaveBeenCalledTimes(1)
    expect(result).toBe('granted')
    expect(notif.notificationPermission.value).toBe('granted')
  })

  it('surfaces denied honestly instead of silently swallowing it', async () => {
    installMockNotification('default')
    MockNotification.permission = 'denied'
    const notif = await loadNotifications()
    const result = await notif.requestNotificationPermission()
    expect(result).toBe('denied')
    expect(notif.notificationPermission.value).toBe('denied')
  })

  it('treats a throwing requestPermission as denied rather than crashing the caller', async () => {
    installMockNotification('default')
    const notif = await loadNotifications()
    MockNotification.requestPermission = vi.fn(async () => {
      throw new Error('blocked by permissions policy')
    })
    const result = await notif.requestNotificationPermission()
    expect(result).toBe('denied')
    expect(notif.notificationPermission.value).toBe('denied')
  })

  it('refreshNotificationPermission re-reads the live browser value', async () => {
    installMockNotification('default')
    const notif = await loadNotifications()
    expect(notif.notificationPermission.value).toBe('default')
    MockNotification.permission = 'granted'
    expect(notif.refreshNotificationPermission()).toBe('granted')
    expect(notif.notificationPermission.value).toBe('granted')
  })
})

describe('event -> notification delivery (exhaustive over NotifyEventKind)', () => {
  async function loadGrantedWithAllRulesOn() {
    installMockNotification('granted')
    const notif = await loadNotifications()
    return notif
  }

  it('delivers exactly one notification per known event kind', async () => {
    const notif = await loadGrantedWithAllRulesOn()
    const unsub = notif.initNotificationDelivery()
    const sse = await import('./sse')

    for (const kind of notif.NOTIFY_EVENT_KINDS) {
      MockNotification.instances = []
      sse.lastEvent.value = baseEvent({ type: kind, name: 'atlas', reason: 'oom' })
      expect(MockNotification.instances).toHaveLength(1)
      expect(MockNotification.instances[0]?.title).toBe(notif.NOTIFY_EVENT_LABELS[kind])
    }
    unsub()
  })

  it('keeper_guardrail body includes keeper identity and reason', async () => {
    const notif = await loadGrantedWithAllRulesOn()
    const unsub = notif.initNotificationDelivery()
    const sse = await import('./sse')

    sse.lastEvent.value = baseEvent({ type: 'keeper_guardrail', name: 'atlas', reason: 'context overflow' })
    const shown = MockNotification.instances[0]
    expect(shown?.options?.body).toContain('atlas')
    expect(shown?.options?.body).toContain('context overflow')
    expect(shown?.options?.tag).toBe('keeper_guardrail:atlas')
    unsub()
  })

  it('oas:agent_failed with a valid typed payload includes agent/task/error in the body', async () => {
    const notif = await loadGrantedWithAllRulesOn()
    const unsub = notif.initNotificationDelivery()
    const sse = await import('./sse')

    sse.lastEvent.value = baseEvent({
      type: 'oas:agent_failed',
      payload: {
        agent_name: 'gamma',
        task_id: 'task_7',
        elapsed_s: 3.0,
        error: 'boom',
        error_domain: 'api',
        error_code: 'rate_limited',
        error_retryable: true,
        error_detail: { variant: 'rate_limited', message: 'slow down' },
      },
    })
    const shown = MockNotification.instances[0]
    expect(shown?.options?.body).toContain('gamma')
    expect(shown?.options?.body).toContain('task_7')
    expect(shown?.options?.body).toContain('boom')
    expect(shown?.options?.tag).toBe('oas:agent_failed:gamma')
    unsub()
  })

  it('oas:agent_failed with a malformed payload still notifies with a generic fallback (not a silent drop)', async () => {
    const notif = await loadGrantedWithAllRulesOn()
    const unsub = notif.initNotificationDelivery()
    const sse = await import('./sse')

    sse.lastEvent.value = baseEvent({ type: 'oas:agent_failed', agent: 'delta', payload: { garbage: true } })
    expect(MockNotification.instances).toHaveLength(1)
    expect(MockNotification.instances[0]?.options?.body).toContain('did not match')
    unsub()
  })

  it('ignores event types outside the closed NotifyEventKind subset', async () => {
    const notif = await loadGrantedWithAllRulesOn()
    const unsub = notif.initNotificationDelivery()
    const sse = await import('./sse')

    sse.lastEvent.value = baseEvent({ type: 'board_post', content: 'hello' })
    expect(MockNotification.instances).toHaveLength(0)
    unsub()
  })

  it('normalizes masc/-prefixed aliases to the same notify kind', async () => {
    const notif = await loadGrantedWithAllRulesOn()
    const unsub = notif.initNotificationDelivery()
    const sse = await import('./sse')

    sse.lastEvent.value = baseEvent({ type: 'masc/keeper_handoff', name: 'atlas' })
    expect(MockNotification.instances).toHaveLength(1)
    expect(MockNotification.instances[0]?.title).toBe(notif.NOTIFY_EVENT_LABELS.keeper_handoff)
    unsub()
  })

  it('does not deliver when the operator disabled that event kind', async () => {
    const notif = await loadGrantedWithAllRulesOn()
    notif.setNotifyRuleEnabled('keeper_guardrail', false)
    const unsub = notif.initNotificationDelivery()
    const sse = await import('./sse')

    sse.lastEvent.value = baseEvent({ type: 'keeper_guardrail', name: 'atlas', reason: 'oom' })
    expect(MockNotification.instances).toHaveLength(0)
    unsub()
  })

  it('unsubscribing stops further delivery', async () => {
    const notif = await loadGrantedWithAllRulesOn()
    const unsub = notif.initNotificationDelivery()
    const sse = await import('./sse')

    unsub()
    sse.lastEvent.value = baseEvent({ type: 'keeper_guardrail', name: 'atlas', reason: 'oom' })
    expect(MockNotification.instances).toHaveLength(0)
  })
})

describe('permission-denied / unsupported surface (honest, not silent)', () => {
  it('never constructs a Notification when permission is denied, even with the rule enabled', async () => {
    installMockNotification('denied')
    const notif = await loadNotifications()
    expect(notif.notificationPermission.value).toBe('denied')
    const unsub = notif.initNotificationDelivery()
    const sse = await import('./sse')

    sse.lastEvent.value = baseEvent({ type: 'approval:pending' })
    expect(MockNotification.instances).toHaveLength(0)
    unsub()
  })

  it('never constructs a Notification when the browser has no Notification API', async () => {
    uninstallNotification()
    const notif = await loadNotifications()
    expect(notif.notificationPermission.value).toBe('unsupported')
    const unsub = notif.initNotificationDelivery()
    const sse = await import('./sse')

    sse.lastEvent.value = baseEvent({ type: 'approval:pending' })
    unsub()
    // No throw, no instance — the caller can distinguish this state via
    // notificationPermission.value === 'unsupported' for UI messaging.
  })
})
