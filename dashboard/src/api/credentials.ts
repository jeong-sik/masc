export type CredentialType = 'github' | 'gitlab' | 'local'
export type CredentialOauthMethod = 'web' | 'with_token'

export interface CredentialState {
  kind: 'Unmaterialized' | 'Materialized' | 'Stale' | string
  last_verified_at_unix_ms?: string | number | null
  reason?: string | null
}

export interface Credential {
  id: string
  name: string
  type: CredentialType
  username: string
  gh_config_dir?: string | null
  ssh_key_path?: string | null
  gpg_key_id?: string | null
  state?: CredentialState | null
  token_sha256_prefix?: string | null
  description?: string
  config?: Record<string, unknown>
  created_at?: string
}

export interface CredentialCreatePayload {
  id: string
  name: string
  type: CredentialType
  username: string
  gh_config_dir?: string | null
  ssh_key_path?: string | null
  gpg_key_id?: string | null
  oauth_method?: CredentialOauthMethod
  token?: string | null
  description?: string
  config?: Record<string, unknown>
}

export function coerceCredentialType(raw: unknown): CredentialType {
  if (raw === 'gitlab') return 'gitlab'
  if (raw === 'local') return 'local'
  return 'github'
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

export function parseCredentialState(raw: unknown): CredentialState | null {
  if (!isRecord(raw)) return null
  const kind = typeof raw.kind === 'string' ? raw.kind : null
  if (!kind) return null
  return {
    kind,
    last_verified_at_unix_ms:
      typeof raw.last_verified_at_unix_ms === 'string' || typeof raw.last_verified_at_unix_ms === 'number'
        ? raw.last_verified_at_unix_ms
        : null,
    reason: typeof raw.reason === 'string' ? raw.reason : null,
  }
}

export function normalizeCredentialsResponse(data: unknown): Credential[] {
  const rows = Array.isArray(data)
    ? data
    : data && typeof data === 'object' && Array.isArray((data as Record<string, unknown>).credentials)
      ? (data as Record<string, unknown>).credentials as unknown[]
      : []
  if (Array.isArray(rows)) {
    return rows.map((row: unknown): Credential => {
      const r = row as Record<string, unknown>
      const username = String(r.username ?? r.name ?? '')
      return {
        id: String(r.id ?? ''),
        name: String(r.name ?? username ?? r.id ?? ''),
        type: coerceCredentialType(r.type ?? r.cred_type),
        username,
        gh_config_dir: typeof r.gh_config_dir === 'string' ? r.gh_config_dir : null,
        ssh_key_path: typeof r.ssh_key_path === 'string' ? r.ssh_key_path : null,
        gpg_key_id: typeof r.gpg_key_id === 'string' ? r.gpg_key_id : null,
        state: parseCredentialState(r.state),
        token_sha256_prefix: typeof r.token_sha256_prefix === 'string' ? r.token_sha256_prefix : null,
        description: r.description ? String(r.description) : undefined,
        config: isRecord(r.config) ? r.config : undefined,
        created_at: r.created_at ? String(r.created_at) : undefined,
      }
    })
  }
  return []
}
