import { get, post } from './core'
import type { Integration } from './runtime-setup'
export interface Check { id: string; condition: 'satisfied' | 'needs_setup' | 'needs_verification' | 'invalid'; message: string; actions: string[] }
export interface Status { schema: 'masc.onboarding_status.v1'; base_path: string | null; selected_runtime: string | null; selected_model: string | null; checks: Check[] }
export interface RuntimeRow { id: string; provider_id: string; display_name: string; protocol: string; model: string; endpoint: string | null; max_context?: number | null }
export type AccountEmail = { integration_id: string; state: 'read'; email: string }
  | { integration_id: string; state: 'not_read'; cause: string }
export interface AccountGroup { id: string; integration_ids: string[]; runtime_ids: string[] }
export interface Inventory { source_revision: string; setup_revision?: string; runtimes: RuntimeRow[]; integrations?: Integration[]; account_groups?: AccountGroup[]; account_emails?: AccountEmail[] }

export const fetchSetupStatus = () => get<Status>('/api/v1/setup/status')
export const fetchSetupInventory = () => get<Inventory>('/api/v1/setup/inventory')
export const saveSetupCredential = (providerId: string, secret: string, sourceRevision: string) =>
  post<{ ok: true; configured: true; verification: 'not_run' }>('/api/v1/setup/credential', { provider_id: providerId, secret, source_revision: sourceRevision })
