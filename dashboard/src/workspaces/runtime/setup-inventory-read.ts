/**
 * The setup inventory read (`GET /api/v1/setup/inventory`) that the Quotas tab
 * and the Keepers workspace share through one cache key: whichever surface
 * opens second reuses the first one's read.
 *
 * A provider id hashes the connection, not the account, so a runtime id does
 * not say which login it runs on. The inventory lists each provider's runtime
 * ids (`integrations[].configured_runtime_ids`) and the email its login file
 * reports (`account_emails`), so one read names the account of a runtime.
 */

import { authSession, type AuthSession } from '../../core/auth'
import { apiGet } from '../../core/transport'
import {
  observedAbsent,
  resourceCache,
  type FetchReason,
  type Observed,
} from '../../core/resource-cache'
import { isAdminLockedForSession } from '../../routes/router'
import { decodeSetupInventoryPayload, type SetupInventoryPayload } from './types'

export const SETUP_INVENTORY_KEY = 'runtime:setup-inventory'

const NEEDS_SINGLE_USER_ADMIN = 'setup_inventory_needs_single_user_admin'

// The route needs Admin, and a multi-account session has no setup inventory.
function canReadSetupInventory(session: AuthSession): boolean {
  return session.kind === 'single_user_local' && !isAdminLockedForSession('admin', session)
}

export function loadSetupInventory(reason: FetchReason): Promise<Observed<SetupInventoryPayload>> {
  if (!canReadSetupInventory(authSession.peek())) {
    return Promise.resolve(observedAbsent(NEEDS_SINGLE_USER_ADMIN))
  }
  return resourceCache.fetch<SetupInventoryPayload>(
    SETUP_INVENTORY_KEY,
    (signal) => apiGet<SetupInventoryPayload>('/api/v1/setup/inventory', {
      signal,
      decode: decodeSetupInventoryPayload,
    }),
    { ttlMs: 20_000, topics: ['setup_inventory', 'config'], reason },
  )
}

/** An email is personal data: a session that lost Admin after the read sees none. */
export function readSetupInventory(): Observed<SetupInventoryPayload> {
  if (!canReadSetupInventory(authSession.value)) return observedAbsent(NEEDS_SINGLE_USER_ADMIN)
  return resourceCache.observe<SetupInventoryPayload>(SETUP_INVENTORY_KEY).value
}

/**
 * The email of the login a runtime's provider runs on. `null` while the
 * inventory is not read, for a runtime no provider lists, and for a login the
 * server could not read: never another provider's email.
 */
export function runtimeAccountEmail(
  inventory: Observed<SetupInventoryPayload>,
  runtimeId: string,
): string | null {
  if (inventory.kind !== 'value') return null
  const provider = inventory.data.integrations.find((integration) =>
    (integration.configured_runtime_ids ?? []).includes(runtimeId))
  if (provider === undefined) return null
  const account = (inventory.data.account_emails ?? []).find((row) => row.integration_id === provider.id)
  if (account === undefined) return null
  switch (account.state) {
    case 'read':
      return account.email
    case 'not_read':
      return null
  }
}

/** `runtimeId · email` when the email is known, the runtime id alone otherwise. */
export function runtimeWithAccount(inventory: Observed<SetupInventoryPayload>, runtimeId: string): string {
  const email = runtimeAccountEmail(inventory, runtimeId)
  return email === null ? runtimeId : `${runtimeId} · ${email}`
}
