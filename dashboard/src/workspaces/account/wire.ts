/**
 * Strict closed-shape wire parsers & epoch-fenced API clients for `/account`.
 *
 * Covers:
 * - `GET /api/v1/auth/whoami`, `POST /auth/logout`
 * - `GET/POST/DELETE /api/v1/auth/pats`
 * - `GET /api/v1/auth/members` + Stack A lifecycle (`disable`, `enable`, `revoke-admin`, `DELETE`)
 * - `GET/POST/DELETE /api/v1/auth/invites`
 * - `GET/POST/DELETE /api/v1/auth/allowlist`
 */

import { apiGet, apiMutate, type ApiError } from '../../core/transport'
import type { Result } from '../../lib/result'

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

function nonEmptyString(v: unknown): string | null {
  return typeof v === 'string' && v.length > 0 ? v : null
}

const MAX_DATE_MS = 8_640_000_000_000_000
function safeTimestampMs(v: unknown): number | null {
  return typeof v === 'number' && Number.isSafeInteger(v) && v >= 0 && v <= MAX_DATE_MS ? v : null
}

// ── Whoami & Logout ─────────────────────────────────────────────────────

export type AccountWhoRole = 'admin' | 'member' | 'unrecognised'

export interface WhoamiInfo {
  readonly id: string
  readonly role: AccountWhoRole
}

export function decodeWhoami(raw: unknown): WhoamiInfo {
  if (!isRecord(raw) || !isRecord(raw.principal)) {
    throw new Error('Invalid whoami payload: missing principal')
  }
  const id = nonEmptyString(raw.principal.id)
  const roleRaw = nonEmptyString(raw.role)
  if (!id || !roleRaw || raw.principal.kind !== 'human') {
    throw new Error('Invalid whoami payload: expected human principal')
  }
  const role: AccountWhoRole = roleRaw === 'admin'
    ? 'admin'
    : roleRaw === 'worker' || roleRaw === 'member'
      ? 'member'
      : 'unrecognised'
  return { id, role }
}

export function fetchWhoami(fetchImpl?: typeof fetch): Promise<Result<WhoamiInfo, ApiError>> {
  return apiGet<WhoamiInfo>('/api/v1/auth/whoami', { fetchImpl, decode: decodeWhoami })
}

export function postLogout(fetchImpl?: typeof fetch): Promise<Result<null, ApiError>> {
  return apiMutate<null>('POST', '/auth/logout', undefined, { fetchImpl })
}

// ── Personal Access Tokens (PATs) ───────────────────────────────────────

export type PatReach = 'all' | readonly string[]

export interface PatScope {
  readonly runtimes: PatReach
  readonly channels: PatReach
  readonly effects: PatReach
}

export type PatUsePreset = 'read_only' | 'mcp'

export type PatStatus = 'open' | 'expired' | 'revoked' | 'unknown' | 'unrecognised'

export interface PatRecord {
  readonly id: string
  readonly scope: PatScope
  readonly issuedAtMs: number
  readonly expiresAtMs: number | null
  readonly status: PatStatus
}

export interface IssuedPat {
  readonly id: string
  readonly token: string
}

const KNOWN_PAT_STATUSES: ReadonlySet<string> = new Set(['open', 'expired', 'revoked', 'unknown'])

export function scopeForPatPreset(use: PatUsePreset): PatScope {
  if (use === 'read_only') {
    return { runtimes: 'all', channels: ['direct'], effects: ['read_state'] }
  }
  return {
    runtimes: 'all',
    channels: ['direct'],
    effects: ['invoke_model', 'manage_own_keeper', 'manage_own_provider', 'read_state', 'use_tool'],
  }
}

function decodeReach(raw: unknown): PatReach {
  if (raw === 'all') return 'all'
  if (!Array.isArray(raw)) throw new Error('Invalid scope reach')
  const items: string[] = []
  for (const entry of raw) {
    const label = nonEmptyString(entry)
    if (!label) throw new Error('Invalid scope label')
    items.push(label)
  }
  return items
}

export function decodePatsList(raw: unknown): readonly PatRecord[] {
  if (!isRecord(raw) || !Array.isArray(raw.pats)) {
    throw new Error('Invalid PAT list payload')
  }
  const seen = new Set<string>()
  const out: PatRecord[] = []
  for (const row of raw.pats) {
    if (!isRecord(row) || !isRecord(row.scope)) throw new Error('Invalid PAT row')
    const id = nonEmptyString(row.pat_id)
    const issuedAtMs = safeTimestampMs(row.issued_at_ms)
    const expiresAtMs = row.expires_at_ms === null ? null : safeTimestampMs(row.expires_at_ms)
    if (!id || issuedAtMs === null || (row.expires_at_ms !== null && expiresAtMs === null)) {
      throw new Error('Invalid PAT metadata')
    }
    if (seen.has(id)) throw new Error(`Duplicate PAT id: ${id}`)
    seen.add(id)
    const statusRaw = typeof row.status === 'string' ? row.status : ''
    const status: PatStatus = KNOWN_PAT_STATUSES.has(statusRaw)
      ? (statusRaw as PatStatus)
      : 'unrecognised'
    out.push({
      id,
      scope: {
        runtimes: decodeReach(row.scope.runtimes),
        channels: decodeReach(row.scope.channels),
        effects: decodeReach(row.scope.allowed_effects),
      },
      issuedAtMs,
      expiresAtMs,
      status,
    })
  }
  return out
}

export function decodeIssuedPat(raw: unknown): IssuedPat {
  if (!isRecord(raw)) throw new Error('Invalid issued PAT payload')
  const id = nonEmptyString(raw.pat_id)
  const token = nonEmptyString(raw.token)
  if (!id || !token) throw new Error('Issued PAT missing pat_id or token')
  return { id, token }
}

export function listPats(fetchImpl?: typeof fetch): Promise<Result<readonly PatRecord[], ApiError>> {
  return apiGet<readonly PatRecord[]>('/api/v1/auth/pats', { fetchImpl, decode: decodePatsList })
}

export function issuePat(
  use: PatUsePreset,
  expiresAtMs: number | null,
  fetchImpl?: typeof fetch,
): Promise<Result<IssuedPat, ApiError>> {
  const scope = scopeForPatPreset(use)
  return apiMutate<IssuedPat>(
    'POST',
    '/api/v1/auth/pats',
    {
      scope: {
        runtimes: scope.runtimes,
        channels: scope.channels,
        allowed_effects: scope.effects,
      },
      expires_at_ms: expiresAtMs,
    },
    { fetchImpl, decode: decodeIssuedPat },
  )
}

export function revokePat(id: string, fetchImpl?: typeof fetch): Promise<Result<null, ApiError>> {
  return apiMutate<null>('DELETE', `/api/v1/auth/pats/${encodeURIComponent(id)}`, undefined, { fetchImpl })
}

// ── External Identity (Shared by Members & Allowlist) ───────────────────

export type ExternalIdentity =
  | { readonly provider: 'github'; readonly userId: number }
  | { readonly provider: 'google'; readonly sub: string }
  | { readonly provider: 'unrecognised' }

export type RegistrableIdentity = Exclude<ExternalIdentity, { readonly provider: 'unrecognised' }>

export const GOOGLE_SUB_RE = /^[!-~]{1,255}$/

export function decodeExternalIdentity(raw: unknown): ExternalIdentity {
  if (!isRecord(raw)) throw new Error('Invalid identity object')
  const provider = nonEmptyString(raw.provider)
  if (!provider) throw new Error('Identity missing provider')
  if (provider === 'github') {
    if (typeof raw.user_id !== 'number' || !Number.isSafeInteger(raw.user_id) || raw.user_id <= 0) {
      throw new Error('Invalid GitHub user_id')
    }
    return { provider: 'github', userId: raw.user_id }
  }
  if (provider === 'google') {
    const sub = nonEmptyString(raw.sub)
    if (!sub || !GOOGLE_SUB_RE.test(sub)) throw new Error('Invalid Google sub')
    return { provider: 'google', sub }
  }
  return { provider: 'unrecognised' }
}

export function formatIdentity(identity: ExternalIdentity): string {
  switch (identity.provider) {
    case 'github': return `GitHub #${identity.userId}`
    case 'google': return `Google (${identity.sub})`
    case 'unrecognised': return 'Unknown provider'
  }
}

// ── Members & Stack A Lifecycle Mutations (Admin-only) ──────────────────

export type MemberRole = 'admin' | 'member' | 'unrecognised'
export type MemberStatus = 'active' | 'disabled' | 'unrecognised'
export type HeldChange = 'revoke' | 'disable' | 'delete' | 'unrecognised'

/**
 * Strict closed-sum cause for `POST /api/v1/auth/members/:id/revoke-admin`
 * matching `lib/auth/login_member_routes.mli` (`Authz_admin_event.Revoked`).
 */
export type RevokeAdminCause = 'security_incident' | 'operational'

export const REVOKE_ADMIN_CAUSES: readonly RevokeAdminCause[] = [
  'security_incident',
  'operational',
]

export interface MemberRecord {
  readonly userId: string
  readonly identity: ExternalIdentity
  readonly role: MemberRole
  readonly status: MemberStatus
  readonly held: readonly HeldChange[]
}

const KNOWN_HELD: ReadonlySet<string> = new Set(['revoke', 'disable', 'delete'])

export function decodeMembersList(raw: unknown): readonly MemberRecord[] {
  if (!isRecord(raw) || !Array.isArray(raw.members)) {
    throw new Error('Invalid members payload')
  }
  const seen = new Set<string>()
  const out: MemberRecord[] = []
  for (const row of raw.members) {
    if (!isRecord(row) || !Array.isArray(row.held)) throw new Error('Invalid member row')
    const userId = nonEmptyString(row.user_id)
    if (!userId) throw new Error('Member missing user_id')
    if (seen.has(userId)) throw new Error(`Duplicate member user_id: ${userId}`)
    seen.add(userId)
    const role: MemberRole = row.role === 'admin'
      ? 'admin'
      : row.role === 'member'
        ? 'member'
        : 'unrecognised'
    const status: MemberStatus = row.status === 'active'
      ? 'active'
      : row.status === 'disabled'
        ? 'disabled'
        : 'unrecognised'
    const held: HeldChange[] = row.held.map((h) =>
      typeof h === 'string' && KNOWN_HELD.has(h) ? (h as HeldChange) : 'unrecognised',
    )
    out.push({
      userId,
      identity: decodeExternalIdentity(row.identity),
      role,
      status,
      held,
    })
  }
  return out
}

export function listMembers(fetchImpl?: typeof fetch): Promise<Result<readonly MemberRecord[], ApiError>> {
  return apiGet<readonly MemberRecord[]>('/api/v1/auth/members', { fetchImpl, decode: decodeMembersList })
}

export function disableMember(
  userId: string,
  fetchImpl?: typeof fetch,
): Promise<Result<{ readonly user_id: string; readonly status: string }, ApiError>> {
  return apiMutate('POST', `/api/v1/auth/members/${encodeURIComponent(userId)}/disable`, undefined, { fetchImpl })
}

export function enableMember(
  userId: string,
  fetchImpl?: typeof fetch,
): Promise<Result<{ readonly user_id: string; readonly status: string }, ApiError>> {
  return apiMutate('POST', `/api/v1/auth/members/${encodeURIComponent(userId)}/enable`, undefined, { fetchImpl })
}

export function revokeAdminMember(
  userId: string,
  cause: RevokeAdminCause,
  fetchImpl?: typeof fetch,
): Promise<Result<{ readonly user_id: string; readonly role: string; readonly cause: RevokeAdminCause }, ApiError>> {
  if (cause !== 'security_incident' && cause !== 'operational') {
    throw new Error(`Invalid revoke-admin cause: ${String(cause)}`)
  }
  return apiMutate(
    'POST',
    `/api/v1/auth/members/${encodeURIComponent(userId)}/revoke-admin`,
    { cause },
    { fetchImpl },
  )
}

export function deleteMember(userId: string, fetchImpl?: typeof fetch): Promise<Result<null, ApiError>> {
  return apiMutate<null>('DELETE', `/api/v1/auth/members/${encodeURIComponent(userId)}`, undefined, { fetchImpl })
}

// ── Invites (Admin-only) ────────────────────────────────────────────────

export type InviteRole = 'member' | 'admin'
export type InviteIssuer =
  | { readonly kind: 'local_operator' }
  | { readonly kind: 'admin'; readonly userId: string }

export type InviteStatus =
  | { readonly kind: 'open' }
  | { readonly kind: 'expired' }
  | { readonly kind: 'revocation_pending' }
  | { readonly kind: 'revoked' }
  | { readonly kind: 'consumed'; readonly joined: string }
  | { readonly kind: 'unrecognised' }

export interface InviteRecord {
  readonly id: string
  readonly role: InviteRole
  readonly issuer: InviteIssuer
  readonly expiresAtMs: number
  readonly status: InviteStatus
}

export interface IssuedInvite {
  readonly id: string
  readonly role: InviteRole
  readonly expiresAtMs: number
  readonly link: string
}

export function decodeInvitesList(raw: unknown): readonly InviteRecord[] {
  if (!isRecord(raw) || !Array.isArray(raw.invites)) throw new Error('Invalid invites payload')
  const out: InviteRecord[] = []
  for (const row of raw.invites) {
    if (!isRecord(row) || !isRecord(row.issuer)) throw new Error('Invalid invite row')
    const id = nonEmptyString(row.invite_id)
    const role: InviteRole | null = row.role === 'member' || row.role === 'admin' ? row.role : null
    const expiresAtMs = safeTimestampMs(row.expires_at_ms)
    if (!id || !role || expiresAtMs === null) throw new Error('Invalid invite metadata')

    let issuer: InviteIssuer
    if (row.issuer.kind === 'local_operator') {
      issuer = { kind: 'local_operator' }
    } else if (row.issuer.kind === 'admin' && nonEmptyString(row.issuer.user_id)) {
      issuer = { kind: 'admin', userId: String(row.issuer.user_id) }
    } else {
      throw new Error('Invalid invite issuer')
    }

    let status: InviteStatus
    switch (row.status) {
      case 'consumed': {
        const joined = nonEmptyString(row.user_id)
        if (!joined) throw new Error('Consumed invite missing user_id')
        status = { kind: 'consumed', joined }
        break
      }
      case 'open':
      case 'expired':
      case 'revocation_pending':
      case 'revoked':
        status = { kind: row.status }
        break
      default:
        status = { kind: 'unrecognised' }
    }

    out.push({ id, role, issuer, expiresAtMs, status })
  }
  return out
}

export function decodeIssuedInvite(raw: unknown): IssuedInvite {
  if (!isRecord(raw)) throw new Error('Invalid issued invite')
  const id = nonEmptyString(raw.invite_id)
  const role: InviteRole | null = raw.role === 'member' || raw.role === 'admin' ? raw.role : null
  const expiresAtMs = safeTimestampMs(raw.expires_at_ms)
  const link = nonEmptyString(raw.link)
  if (!id || !role || expiresAtMs === null || !link) throw new Error('Issued invite incomplete')
  return { id, role, expiresAtMs, link }
}

export function listInvites(fetchImpl?: typeof fetch): Promise<Result<readonly InviteRecord[], ApiError>> {
  return apiGet<readonly InviteRecord[]>('/api/v1/auth/invites', { fetchImpl, decode: decodeInvitesList })
}

export function issueInvite(role: InviteRole, fetchImpl?: typeof fetch): Promise<Result<IssuedInvite, ApiError>> {
  return apiMutate<IssuedInvite>('POST', '/api/v1/auth/invites', { role }, { fetchImpl, decode: decodeIssuedInvite })
}

export function revokeInvite(id: string, fetchImpl?: typeof fetch): Promise<Result<null, ApiError>> {
  return apiMutate<null>('DELETE', `/api/v1/auth/invites/${encodeURIComponent(id)}`, undefined, { fetchImpl })
}

// ── Allowlist (Admin-only) ──────────────────────────────────────────────

export type AllowlistStatus =
  | { readonly kind: 'open' }
  | { readonly kind: 'removal_pending' }
  | { readonly kind: 'removed' }
  | { readonly kind: 'consumed'; readonly joined: string }
  | { readonly kind: 'unrecognised' }

export interface AllowlistEntry {
  readonly id: string
  readonly identity: ExternalIdentity
  readonly registrar: string
  readonly status: AllowlistStatus
}

export interface RegisteredAllowlist {
  readonly id: string
  readonly previouslyDeleted: boolean
}

export function decodeAllowlist(raw: unknown): readonly AllowlistEntry[] {
  if (!isRecord(raw) || !Array.isArray(raw.registrations)) {
    throw new Error('Invalid allowlist payload')
  }
  const out: AllowlistEntry[] = []
  for (const row of raw.registrations) {
    if (!isRecord(row)) throw new Error('Invalid allowlist row')
    const id = nonEmptyString(row.registration_id)
    const registrar = nonEmptyString(row.registrar)
    if (!id || !registrar) throw new Error('Allowlist row missing fields')

    let status: AllowlistStatus
    switch (row.status) {
      case 'consumed': {
        const joined = nonEmptyString(row.user_id)
        if (!joined) throw new Error('Consumed allowlist entry missing user_id')
        status = { kind: 'consumed', joined }
        break
      }
      case 'open':
      case 'removal_pending':
      case 'removed':
        status = { kind: row.status }
        break
      default:
        status = { kind: 'unrecognised' }
    }

    out.push({
      id,
      identity: decodeExternalIdentity(row.identity),
      registrar,
      status,
    })
  }
  return out
}

export function decodeRegisteredAllowlist(raw: unknown): RegisteredAllowlist {
  if (!isRecord(raw)) throw new Error('Invalid allowlist registration response')
  const id = nonEmptyString(raw.registration_id)
  if (!id || typeof raw.previously_deleted !== 'boolean') {
    throw new Error('Allowlist registration missing fields')
  }
  return { id, previouslyDeleted: raw.previously_deleted }
}

export function listAllowlist(fetchImpl?: typeof fetch): Promise<Result<readonly AllowlistEntry[], ApiError>> {
  return apiGet<readonly AllowlistEntry[]>('/api/v1/auth/allowlist', { fetchImpl, decode: decodeAllowlist })
}

export function registerAllowlist(
  identity: RegistrableIdentity,
  fetchImpl?: typeof fetch,
): Promise<Result<RegisteredAllowlist, ApiError>> {
  const body = identity.provider === 'github'
    ? { provider: 'github', user_id: identity.userId }
    : { provider: 'google', sub: identity.sub }
  return apiMutate<RegisteredAllowlist>('POST', '/api/v1/auth/allowlist', body, {
    fetchImpl,
    decode: decodeRegisteredAllowlist,
  })
}

export function removeAllowlist(id: string, fetchImpl?: typeof fetch): Promise<Result<null, ApiError>> {
  return apiMutate<null>('DELETE', `/api/v1/auth/allowlist/${encodeURIComponent(id)}`, undefined, { fetchImpl })
}
