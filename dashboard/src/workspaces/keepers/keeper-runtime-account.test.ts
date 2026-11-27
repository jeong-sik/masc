// @vitest-environment jsdom

// #41964: a provider id hashes the connection, not the account, so the Keeper
// runtime row names the account by the email the setup inventory read.

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { html } from 'htm/preact'
import { cleanup, fireEvent, render } from '@testing-library/preact'
import { observedLoading, observedValue, resourceCache } from '../../core/resource-cache'
import { authSession, resetAuthStateForTests } from '../../core/auth'
import { resetObserverStateForTests } from '../../core/observer'
import { resetPortraitCacheForTests } from '../../lib/portrait-cache'
import { resetShellStateForTests } from '../../shell/shell-state'
import { loadSetupInventory, runtimeAccountEmail, SETUP_INVENTORY_KEY } from '../runtime/setup-inventory-read'
import type { SetupInventoryPayload } from '../runtime/types'
import { KeeperHeader } from './keeper-header'
import { KeeperRoster } from './keeper-roster'
import type { KeeperRosterItem } from './types'

const READ_RUNTIME = 'claude_code_ac22e641.claude-opus'
const UNREAD_RUNTIME = 'claude_code_9d3a2e70.claude-opus'
const NO_ROW_RUNTIME = 'claude_code_5b7f0c19.claude-opus'
const EMAIL = 'alice@example.com'

const integration = (id: string, runtimeIds: readonly string[]) => ({
  id,
  display_name: 'Claude Code',
  protocol: 'claude-code-cli',
  origin: 'runtime_config',
  setup_support: 'existing_binding',
  configured_runtime_ids: runtimeIds,
})

// The inventory as `GET /api/v1/setup/inventory` sends it.
const INVENTORY_WIRE = {
  source_revision: 'rev-1',
  setup_revision: 'setup-1',
  default_runtime_id: READ_RUNTIME,
  runtimes: [],
  integrations: [
    integration('claude_code_ac22e641', [READ_RUNTIME, 'claude_code_ac22e641.claude-sonnet']),
    integration('claude_code_5b7f0c19', [NO_ROW_RUNTIME]),
    integration('claude_code_9d3a2e70', [UNREAD_RUNTIME]),
  ],
  account_emails: [
    { integration_id: 'claude_code_ac22e641', state: 'read', email: EMAIL, plan: ['max'] },
    { integration_id: 'claude_code_9d3a2e70', state: 'not_read', cause: 'source_unavailable' },
  ],
}

const INVENTORY: SetupInventoryPayload = {
  integrations: INVENTORY_WIRE.integrations,
  account_emails: [
    { integration_id: 'claude_code_ac22e641', state: 'read', email: EMAIL, plan: ['max'] },
    { integration_id: 'claude_code_9d3a2e70', state: 'not_read', cause: 'source_unavailable' },
  ],
}

function keeper(name: string, runtimeId: string): KeeperRosterItem {
  return {
    name,
    status: 'running',
    phase: 'idle',
    health: 'healthy',
    paused: false,
    keepalive_running: true,
    activation_mode: 'autonomous',
    runtime_id: runtimeId,
    sandbox_profile: 'microvm',
    company: 'code',
    context_ratio: 0.4,
    context_tokens: 80_000,
    context_max: 200_000,
    context_unavailable_reason: null,
    runtime_blocker_summary: null,
    last_failure: null,
    directory_issue: null,
    turns_24h: 3,
    candle_balance_milli: null,
    portrait_equipment: null,
    chat_control_token: null,
    active_turn: null,
  }
}

function stubInventoryFetch(inventoryWire: unknown = INVENTORY_WIRE) {
  const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
    const url = String(input)
    if (url.startsWith('/api/v1/setup/inventory')) {
      return new Response(JSON.stringify(inventoryWire), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })
    }
    return new Response(JSON.stringify({ default: 'auto', overrides: [], restore_error: null }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    })
  })
  vi.stubGlobal('fetch', fetchMock)
  return fetchMock
}

function rosterRowText(items: readonly KeeperRosterItem[], name: string): string {
  const view = render(
    html`<${KeeperRoster} roster=${observedValue(items)} turnsObservation=${null} selectedKeeper=${null} onSelectKeeper=${vi.fn()} onCreatedKeeper=${vi.fn()} />`,
  )
  const text = view.container.querySelector(`[data-keeper="${name}"]`)?.textContent ?? ''
  view.unmount()
  return text
}

function headerRuntimeRow(item: KeeperRosterItem): string {
  const view = render(
    html`<${KeeperHeader} keeper=${item} activeTab="chat" onSelectTab=${vi.fn()} onLifecycleMutated=${vi.fn()} onDeleted=${vi.fn()} />`,
  )
  fireEvent.click(view.getByTestId('keeper-meta-menu'))
  const rows = [...view.getByTestId('keeper-meta-popover').querySelectorAll('.kp-meta-row')]
  const runtimeRow = rows.find((row) => row.querySelector('.kp-meta-key')?.textContent === 'Runtime')
  const text = runtimeRow?.querySelector('.kp-meta-val')?.textContent ?? ''
  view.unmount()
  return text
}

describe('Keeper runtime account', () => {
  beforeEach(() => {
    resetAuthStateForTests()
    resetObserverStateForTests()
    resetPortraitCacheForTests()
    resetShellStateForTests()
    resourceCache.clearAll()
    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: true,
      authMethods: { google: false, github: false, dev_token: false },
      workspaceId: 'default',
    }
  })

  afterEach(() => {
    cleanup()
    resourceCache.clearAll()
    vi.unstubAllGlobals()
    vi.restoreAllMocks()
  })

  it('names only the email the inventory read for the runtime\'s own provider', () => {
    const inventory = observedValue(INVENTORY)
    expect(runtimeAccountEmail(inventory, READ_RUNTIME)).toBe(EMAIL)
    expect(runtimeAccountEmail(inventory, 'claude_code_ac22e641.claude-sonnet')).toBe(EMAIL)
    expect(runtimeAccountEmail(inventory, NO_ROW_RUNTIME)).toBeNull()
    expect(runtimeAccountEmail(inventory, UNREAD_RUNTIME)).toBeNull()
    expect(runtimeAccountEmail(inventory, 'claude_code_ac22e641.unknown-model')).toBeNull()
    expect(runtimeAccountEmail(observedLoading<SetupInventoryPayload>(), READ_RUNTIME)).toBeNull()
  })

  it('shows the email on the roster row and the header Runtime row once the inventory is read', async () => {
    const fetchMock = stubInventoryFetch()
    const alpha = keeper('alpha', READ_RUNTIME)
    const beta = keeper('beta', UNREAD_RUNTIME)
    const items = [alpha, beta, keeper('gamma', NO_ROW_RUNTIME)]

    expect(rosterRowText(items, 'alpha')).not.toContain(EMAIL)
    expect(headerRuntimeRow(alpha)).toBe(READ_RUNTIME)

    const read = await loadSetupInventory('mount')
    expect(read.kind).toBe('value')
    expect(fetchMock.mock.calls.filter(([input]) => String(input).startsWith('/api/v1/setup/inventory'))).toHaveLength(1)

    expect(rosterRowText(items, 'alpha')).toContain(`${READ_RUNTIME} · ${EMAIL}`)
    expect(rosterRowText(items, 'beta')).toContain(UNREAD_RUNTIME)
    expect(rosterRowText(items, 'beta')).not.toContain('@')
    expect(rosterRowText(items, 'gamma')).not.toContain('@')
    expect(headerRuntimeRow(alpha)).toBe(`${READ_RUNTIME} · ${EMAIL}`)
    expect(headerRuntimeRow(beta)).toBe(UNREAD_RUNTIME)
  })

  it('refuses a read row without an email and a state the server does not send', async () => {
    const withRows = (rows: readonly unknown[]) => ({ ...INVENTORY_WIRE, account_emails: rows })
    for (const row of [
      { integration_id: 'claude_code_ac22e641', state: 'read' },
      { integration_id: 'claude_code_ac22e641', state: 'read', email: ' ' },
      { integration_id: 'claude_code_ac22e641', state: 'signed_in', email: EMAIL },
    ]) {
      resourceCache.clearAll()
      stubInventoryFetch(withRows([row]))
      const read = await loadSetupInventory('mount')
      expect(read.kind).toBe('failed')
      const text = rosterRowText([keeper('alpha', READ_RUNTIME)], 'alpha')
      expect(text).toContain(READ_RUNTIME)
      expect(text).not.toContain(EMAIL)
    }
  })

  it('hides a read email from a session that lost Admin after the read', async () => {
    stubInventoryFetch()
    const alpha = keeper('alpha', READ_RUNTIME)
    await loadSetupInventory('mount')
    expect(rosterRowText([alpha], 'alpha')).toContain(EMAIL)
    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: true,
      canTokenAdmin: false,
      authMethods: { google: false, github: false, dev_token: false },
      workspaceId: 'default',
    }
    // The cached read is still there; only the session decides it is not shown.
    expect(resourceCache.peek(SETUP_INVENTORY_KEY)?.kind).toBe('value')
    expect(rosterRowText([alpha], 'alpha')).not.toContain(EMAIL)
    expect(headerRuntimeRow(alpha)).toBe(READ_RUNTIME)
  })

  it('does not read the inventory for a multi-account session', async () => {
    const fetchMock = stubInventoryFetch()
    authSession.value = {
      kind: 'multi_account_signed_in',
      mode: 'multi_account',
      accountId: 'user-1',
      email: null,
      displayName: 'user-1',
      role: 'admin',
      csrfToken: 'csrf-1',
      authMethods: { google: true, github: false, dev_token: false },
      workspaceId: 'default',
    }
    const read = await loadSetupInventory('mount')
    expect(read.kind).toBe('absent')
    expect(fetchMock).not.toHaveBeenCalled()
  })
})
