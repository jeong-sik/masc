import { signal, type ReadonlySignal } from '@preact/signals'
import type { DashboardAuthErrorCode } from '../types/dashboard-execution'
import {
  clearStoredToken,
  currentDashboardActor,
  currentStoredTokenRevision,
  fetchWithTimeout,
  getStoredToken,
  getStoredTokenMeta,
  isRemoteAccess,
  setRejectedCredentialListener,
  setStoredToken,
  subscribeStoredTokenChanges,
  type RejectedCredential,
} from './core'
import { currentCanonicalDashboardActor, currentDashboardActorName, dashboardActorRevision, managedDashboardActorRevision,
  managedDashboardAuthRevision, managedDashboardRefusal, managedDashboardUnverified, recordManagedCredentialRefusal } from '../lib/dashboard-session-actor'
import { WARM_RETRY_DELAYS_MS, warmRetryDelayFor } from '../lib/warm-retry'
import type { ArtifactWorkspace } from './published-artifacts'

const DEV_TOKEN_FETCH_TIMEOUT_MS = 3000

type TokenOwner = { token: string | null; revision: number; actor: string; actorRevision: number; managed: boolean }
type OwnedPromise<T> = { owner: TokenOwner; promise: Promise<T>; abort?: () => void }
let devTokenBootstrapPromise: OwnedPromise<void> | null = null
let devTokenRefreshPromise: OwnedPromise<boolean> | null = null
type ManagedRecoveryClaim = { owner: TokenOwner; authRevision: number; retries: number; inFlight: boolean;
  notBefore: number; timer: ReturnType<typeof setTimeout> | null; controller: AbortController | null }
let managedRecoveryAttempt: ManagedRecoveryClaim | null = null
let bootstrapGeneration = 0
let bootstrapRetryAfterMs = 0
let bootstrapFailureDeadline: { owner: TokenOwner; notBefore: number } | null = null
let bootstrapApplication: { generation: number; before: TokenOwner; after: TokenOwner } | null = null

function tokenOwner(): TokenOwner {
  const token = getStoredToken()
  const managed = token !== null && getStoredTokenMeta()?.source === 'dev'
  return { token, revision: currentStoredTokenRevision(), actor: currentDashboardActor(),
    actorRevision: managed ? managedDashboardActorRevision.peek() : dashboardActorRevision.peek(), managed }
}

function sameTokenOwner(left: TokenOwner, right: TokenOwner): boolean {
  return left.token === right.token && left.revision === right.revision
    && left.actor === right.actor && left.managed === right.managed && left.actorRevision === right.actorRevision
}

function claimManagedRecovery(owner: TokenOwner): ManagedRecoveryClaim | null {
  const authRevision = managedDashboardAuthRevision.peek()
  if (managedRecoveryAttempt?.owner.revision === owner.revision && managedRecoveryAttempt.authRevision === authRevision) {
    if (Date.now() < managedRecoveryAttempt.notBefore || sameTokenOwner(managedRecoveryAttempt.owner, owner)
      || (!managedRecoveryAttempt.inFlight && managedRecoveryAttempt.timer === null)) return null
  }
  if (managedRecoveryAttempt) releaseManagedRecovery(managedRecoveryAttempt)
  managedRecoveryAttempt = { owner, authRevision, retries: 0, inFlight: false, notBefore: 0, timer: null, controller: null }
  return managedRecoveryAttempt
}

function releaseManagedRecovery(claim: ManagedRecoveryClaim): void {
  if (managedRecoveryAttempt !== claim) return
  if (claim.timer) clearTimeout(claim.timer)
  claim.controller?.abort()
  managedRecoveryAttempt = null
}

function managedRecoveryIsCurrent(claim: ManagedRecoveryClaim, generation: number): boolean {
  return managedRecoveryAttempt === claim && claim.authRevision === managedDashboardAuthRevision.peek()
    && sameTokenOwner(claim.owner, tokenOwner()) && generation === bootstrapGeneration
}

function scheduleManagedRecovery(claim: ManagedRecoveryClaim, generation: number, retry: () => void,
  retryAfterMs = 0): void {
  if (!managedRecoveryIsCurrent(claim, generation)) return
  claim.notBefore = Math.max(claim.notBefore, Date.now() + retryAfterMs)
  if (claim.timer) return
  claim.retries = Math.min(claim.retries + 1, WARM_RETRY_DELAYS_MS.length)
  claim.timer = setTimeout(() => {
    claim.timer = null
    if (managedRecoveryIsCurrent(claim, generation)) retry()
    else releaseManagedRecovery(claim)
  }, Math.max(warmRetryDelayFor(claim.retries), retryAfterMs))
}

function retryAfterMs(response: Response): number {
  const maxTimerDelayMs = 2_147_483_647
  const value = response.headers.get('retry-after')?.trim()
  if (!value) return 0
  if (/^\d+$/.test(value)) return Math.min(Number(value) * 1000, maxTimerDelayMs)
  const time = Date.parse(value)
  return Number.isFinite(time) ? Math.min(Math.max(0, time - Date.now()), maxTimerDelayMs) : 0
}

/**
 * Tracks the outcome of the loopback dev-token bootstrap so the UI can
 * distinguish "auth required but no token" from "network error" etc.
 *   idle       — not yet attempted
 *   fetching   — in-flight
 *   warming    — server is initializing or explicitly reports temporary unavailability
 *   ok         — token stored
 *   no_endpoint — /dev-token returned 404 (loopback disabled or strict auth)
 *   invalid_response — endpoint response violated the exact token contract
 *   network    — fetch threw (server down, CORS, DNS)
 */
export type DevTokenBootstrapStatus =
  | 'idle'
  | 'fetching'
  | 'warming'
  | 'ok'
  | 'no_endpoint'
  | 'invalid_response'
  | 'network'

export const devTokenBootstrapStatus: ReadonlySignal<DevTokenBootstrapStatus> =
  signal<DevTokenBootstrapStatus>('idle')

export function hasPendingDevTokenFailure(): boolean {
  return shouldRefreshDevToken()
    && !currentManagedDevTokenRefused()
    && (devTokenBootstrapStatus.value === 'warming'
      || devTokenBootstrapStatus.value === 'network')
}

export function pendingDevTokenRetryDelayMs(): number {
  return bootstrapFailureDeadline && sameTokenOwner(bootstrapFailureDeadline.owner, tokenOwner())
    ? Math.max(0, bootstrapFailureDeadline.notBefore - Date.now()) : 0
}

function currentManagedDevTokenRefused(): boolean {
  return getStoredToken() !== null && getStoredTokenMeta()?.source === 'dev'
    && (managedDashboardRefusal.peek() === currentStoredTokenRevision()
      || managedDashboardUnverified.peek() === currentStoredTokenRevision())
}

interface DevTokenBootstrapPayload {
  token?: unknown
  actor?: unknown
  role?: unknown
}

function retryableTokenFailure(status: number): boolean {
  return status === 429 || status === 503
}

const REFRESHABLE_AUTH_CODES: ReadonlySet<DashboardAuthErrorCode> = new Set([
  'invalid_token',
  'token_expired',
  'actor_mismatch',
])

/* Codes that say the server refused the credential itself. `actor_mismatch`
   is about the actor the request named, so the token stays. */
const CREDENTIAL_REJECTION_CODES: ReadonlySet<DashboardAuthErrorCode> = new Set([
  'invalid_token',
  'token_expired',
])

function isCredentialRejectionCode(value: unknown): boolean {
  return typeof value === 'string'
    && CREDENTIAL_REJECTION_CODES.has(value as DashboardAuthErrorCode)
}

export function isRefreshableDashboardAuthCode(
  value: unknown,
): value is DashboardAuthErrorCode {
  return typeof value === 'string'
    && REFRESHABLE_AUTH_CODES.has(value as DashboardAuthErrorCode)
}

export function shouldRefreshDevToken(): boolean {
  const token = getStoredToken()
  const meta = getStoredTokenMeta()
  // An explicitly selected operator without a token must not silently be
  // replaced by the local dashboard administrator on the next MCP request.
  if (!token) return !isRemoteAccess() && currentDashboardActorName() === 'dashboard'
  if (meta?.source === 'dev') return true
  // A manually-pasted token should never be silently overwritten by the
  // loopback dev-token bootstrapper.  (Issue: token appeared reset after
  // page refresh because ensureDevToken() re-fetched and replaced it.)
  if (meta?.source === 'manual') return false
  const actor = currentDashboardActor()
  if (isRemoteAccess() || actor !== 'dashboard') return false
  // Loopback dashboard sessions should self-heal if they are still holding
  // a borrowed non-dashboard token (for example an old MCP-client paste/URL token).
  return meta == null || meta.source === 'url'
}

/** Fetch the loopback-only dev token once per page load and stash it so
    subsequent `/mcp` requests include `Authorization: Bearer ...`. The server
    only exposes `/api/v1/dashboard/dev-token` when bound to loopback with
    strict-auth overrides disabled; in every other case this quietly no-ops
    and existing flows (URL `?token=...`, manual paste) continue to work. */
export async function ensureDevToken(): Promise<void> {
  await ensureDevTokenImpl(false)
}

async function ensureDevTokenImpl(allowRefused: boolean): Promise<void> {
  if (!allowRefused && currentManagedDevTokenRefused()) return
  if (!shouldRefreshDevToken()) return
  if (pendingDevTokenRetryDelayMs() > 0) return
  const owner = tokenOwner()
  if (devTokenBootstrapPromise && sameTokenOwner(devTokenBootstrapPromise.owner, owner)) return devTokenBootstrapPromise.promise
  devTokenBootstrapPromise?.abort?.()
  const generation = ++bootstrapGeneration
  const controller = new AbortController()
  bootstrapApplication = null
  const current = () => generation === bootstrapGeneration && sameTokenOwner(owner, tokenOwner())
  const forget = () => { if (generation === bootstrapGeneration) devTokenBootstrapPromise = null }
  const continueForChangedOwner = async (): Promise<void> => {
    if (generation !== bootstrapGeneration) return
    forget()
    ;(devTokenBootstrapStatus as { value: DevTokenBootstrapStatus }).value = 'idle'
    // An explicitly selected non-dashboard actor must not be replaced by an
    // automatic dashboard token, nor may an older request replace a token
    // that another owner installed while it was in flight.
    const nextOwner = tokenOwner()
    if (nextOwner.token === owner.token && nextOwner.revision === owner.revision
      && !isRemoteAccess() && nextOwner.actor === 'dashboard' && shouldRefreshDevToken()) {
      await ensureDevTokenImpl(allowRefused)
    }
  }
  const rememberCurrentOwner = () => {
    if (generation === bootstrapGeneration && devTokenBootstrapPromise) devTokenBootstrapPromise.owner = tokenOwner()
  }
  const promise: Promise<void> = (async () => {
    const storedMeta = getStoredTokenMeta()
    bootstrapRetryAfterMs = 0
    ;(devTokenBootstrapStatus as { value: DevTokenBootstrapStatus }).value = 'fetching'
    if (getStoredTokenMeta()?.source === 'manual' && getStoredToken()) return
    try {
        const { res, payload } = await fetchWithTimeout(
          '/api/v1/dashboard/dev-token',
          { method: 'GET', headers: { Accept: 'application/json' }, signal: controller.signal },
          DEV_TOKEN_FETCH_TIMEOUT_MS,
          async res => ({ res, payload: res.ok ? await res.json() as DevTokenBootstrapPayload : null }),
        )
        if (!current()) return continueForChangedOwner()
        if (!res.ok) {
          bootstrapRetryAfterMs = retryAfterMs(res)
          if (res.status === 404 && storedMeta?.source === 'dev') {
            clearStoredToken()
          }
          if (generation !== bootstrapGeneration) return
          if (retryableTokenFailure(res.status)) {
            bootstrapFailureDeadline = { owner, notBefore: Date.now() + bootstrapRetryAfterMs }
            ;(devTokenBootstrapStatus as { value: DevTokenBootstrapStatus }).value = 'warming'
            forget()
          } else {
            bootstrapFailureDeadline = null
            ;(devTokenBootstrapStatus as { value: DevTokenBootstrapStatus }).value = res.status === 404
              ? 'no_endpoint'
              : 'invalid_response'
          }
          rememberCurrentOwner()
          return
        }
        if (payload === null || typeof payload !== 'object') {
          ;(devTokenBootstrapStatus as { value: DevTokenBootstrapStatus }).value = 'invalid_response'
          return
        }
        const token = typeof payload.token === 'string' ? payload.token.trim() : ''
        if (!token || payload.actor !== 'dashboard' || payload.role !== 'admin') {
          ;(devTokenBootstrapStatus as { value: DevTokenBootstrapStatus }).value = 'invalid_response'
          return
        }
        bootstrapFailureDeadline = null
        const currentMeta = getStoredTokenMeta()
        const currentToken = getStoredToken()
        // Same rule as the pre-fetch guard above: a manually-pasted token is
        // never silently overwritten. It needs the token as well as the meta —
        // meta alone can outlive the token it described, and then there is
        // nothing to protect while this return would block the bootstrap
        // forever. shouldRefreshDevToken already admits that case (`!token`
        // returns true), so dropping the token from this check contradicted it.
        if (currentMeta?.source === 'manual' && currentToken) return
        if (
          token !== currentToken
          || currentMeta?.source !== 'dev'
        ) {
          const actorRevisionBeforeSet = managedDashboardActorRevision.peek()
          const actorReset = currentCanonicalDashboardActor() === null ? 0 : 1
          // Token listeners may synchronously open another observer. Let that
          // exact installed owner join this read before publishing the token.
          if (generation === bootstrapGeneration && devTokenBootstrapPromise) devTokenBootstrapPromise.owner = {
            token, revision: currentStoredTokenRevision() + 1, actor: 'dashboard',
            actorRevision: actorRevisionBeforeSet + actorReset, managed: true,
          }
          setStoredToken(token, {
            source: 'dev',
            actor: 'dashboard',
            role: 'admin',
          })
          const after = tokenOwner()
          if (generation === bootstrapGeneration && after.token === token && after.revision === owner.revision + 1
            && after.actor === 'dashboard' && after.actorRevision === actorRevisionBeforeSet + actorReset) {
            bootstrapApplication = { generation, before: owner, after }
          }
        }
        if (generation !== bootstrapGeneration) return
        ;(devTokenBootstrapStatus as { value: DevTokenBootstrapStatus }).value = 'ok'
        rememberCurrentOwner()
        return
    } catch (error) {
      if (!current()) return continueForChangedOwner()
      ;(devTokenBootstrapStatus as { value: DevTokenBootstrapStatus }).value = error instanceof SyntaxError
        ? 'invalid_response' : 'network'
      bootstrapFailureDeadline = null
      if (!(error instanceof SyntaxError)) forget()
      return
    }
  })()
  devTokenBootstrapPromise = { owner, promise, abort: () => controller.abort() }
  return promise
}

export function resetDevTokenBootstrap(): void {
  bootstrapGeneration += 1
  devTokenBootstrapPromise?.abort?.()
  devTokenBootstrapPromise = null
  bootstrapApplication = null
  if (devTokenBootstrapStatus.peek() === 'fetching') {
    ;(devTokenBootstrapStatus as { value: DevTokenBootstrapStatus }).value = 'idle'
  }
}

export async function refreshDevTokenAfterAuthError(code: unknown): Promise<boolean> {
  return refreshDevTokenAfterAuthErrorWithClaim(code)
}

async function refreshDevTokenAfterAuthErrorWithClaim(code: unknown, claim?: ManagedRecoveryClaim | null): Promise<boolean> {
  if (!isRefreshableDashboardAuthCode(code)) return false
  if (isRemoteAccess()) return false
  if (getStoredTokenMeta()?.source === 'manual') return false
  if (!getStoredToken()) return false
  if (currentManagedDevTokenRefused() && (!claim || managedRecoveryAttempt !== claim)) return false
  const owner = tokenOwner()
  if (devTokenRefreshPromise && sameTokenOwner(devTokenRefreshPromise.owner, owner)) return devTokenRefreshPromise.promise

  const refresh = (async () => {
    // Re-fetch in place instead of clearing first. `clearStoredToken()` +
    // `setStoredToken()` are two token-revision changes, and every change
    // tears down and re-dials the dashboard websocket
    // (`subscribeStoredTokenChanges` -> `reconnectAfterAuthTokenChange`), so
    // one recovery produced two reconnects and two "서버 연결 복구됨"
    // toasts. It also left a window where in-flight requests carried no
    // Authorization header at all. `shouldRefreshDevToken()` already returns
    // true for a stored `dev` token, so dropping the clear does not stop the
    // re-fetch — and `ensureDevToken` only writes when the token differs.
    const rejectedToken = getStoredToken()
    const existing = devTokenBootstrapPromise
    const pending = existing && sameTokenOwner(existing.owner, owner) && devTokenBootstrapStatus.peek() === 'fetching'
      ? existing.promise : (() => { resetDevTokenBootstrap(); return ensureDevTokenImpl(true) })()
    const generation = bootstrapGeneration
    await pending
    const applied = bootstrapApplication
    // Recovery means the caller now holds a *different* credential. Getting
    // the same token back proves the token was not the reason the request
    // was rejected; reporting success there makes the caller retry the
    // identical request, fail identically, and refresh again — a loop that
    // reconnects the websocket on every pass and never terminates.
    return applied !== null && applied.generation === generation
      && sameTokenOwner(applied.before, owner) && sameTokenOwner(applied.after, tokenOwner())
      && getStoredTokenMeta()?.source === 'dev' && applied.after.token !== rejectedToken
  })()
  devTokenRefreshPromise = { owner, promise: refresh }
  try {
    return await refresh
  } finally {
    if (devTokenRefreshPromise?.promise === refresh) devTokenRefreshPromise = null
  }
}

/**
 * The server refused the token a request carried. A loopback dev token is
 * re-minted in place. Any other token the server called invalid or expired
 * (pasted, from `?token=`, or used from a remote host) is dropped, because
 * every later request would carry it and be refused the same way. Dropping it
 * also lets the dev-token bootstrap run again, so a loopback tab picks up a
 * fresh dev token and a remote tab shows "Login required".
 *
 * Nothing happens when the stored token is no longer the refused one: a late
 * reply must not drop a token set after its request left. A dev token whose
 * re-mint returned the same value is kept, because dropping it would only
 * fetch it again and be refused again.
 */
export async function recoverFromRejectedCredential(
  rejection: RejectedCredential,
): Promise<void> {
  await recoverFromRejectedCredentialAttempt(rejection)
}

async function recoverFromRejectedCredentialAttempt(
  rejection: RejectedCredential,
  retry?: { claim: ManagedRecoveryClaim; generation: number },
): Promise<void> {
  const owner = retry?.claim.owner ?? tokenOwner()
  if (retry && !managedRecoveryIsCurrent(retry.claim, retry.generation)) {
    releaseManagedRecovery(retry.claim)
    return
  }
  if (owner.token !== rejection.token) return
  let claim = retry?.claim ?? null
  if (!retry && owner.managed && isCredentialRejectionCode(rejection.authErrorCode) && !isRemoteAccess()) {
    claim = claimManagedRecovery(owner)
    if (!claim) return
  }
  if (claim) claim.inFlight = true
  const pending = refreshDevTokenAfterAuthErrorWithClaim(rejection.authErrorCode, claim)
  const generation = bootstrapGeneration
  const refreshed = await pending
  if (claim && managedRecoveryAttempt === claim) claim.inFlight = false
  if (refreshed) return
  if (claim && !managedRecoveryIsCurrent(claim, generation)) {
    releaseManagedRecovery(claim)
    return
  }
  if (claim && (devTokenBootstrapStatus.peek() === 'warming' || devTokenBootstrapStatus.peek() === 'network')) {
    scheduleManagedRecovery(claim, generation, () => {
      void recoverFromRejectedCredentialAttempt(rejection, { claim, generation })
    }, bootstrapRetryAfterMs)
  }
  if (!isCredentialRejectionCode(rejection.authErrorCode)) return
  if (!sameTokenOwner(owner, tokenOwner())) return
  if (getStoredTokenMeta()?.source === 'dev' && !isRemoteAccess()) return
  clearStoredToken()
  resetDevTokenBootstrap()
}

/** An explicit retry can restart a terminal managed recovery. */
export async function retryRejectedDevToken(workspace: ArtifactWorkspace, isCurrent: () => boolean): Promise<boolean> {
  const owner = tokenOwner()
  if (!owner.managed || !owner.token || isRemoteAccess() || managedDashboardRefusal.peek() !== owner.revision || !isCurrent()) return false
  const existing = managedRecoveryAttempt
  if (existing && existing.owner.revision === owner.revision && existing.authRevision === managedDashboardAuthRevision.peek()) {
    if (existing.inFlight || Date.now() < existing.notBefore) return false
    releaseManagedRecovery(existing)
  }
  let applied = false
  await recoverScopedRejectedCredentialAttempt({ token: owner.token, authErrorCode: undefined }, isCurrent, undefined, workspace,
    undefined, true, () => { applied = true })
  const pending = managedRecoveryAttempt
  const recoveryPending = pending && pending.owner.revision === owner.revision
    && pending.authRevision === managedDashboardAuthRevision.peek() && (pending.inFlight || pending.timer !== null)
  return applied || (isCurrent() && !recoveryPending)
}

/** Recover a refusal only while the requesting surface still owns it.
    A scoped request does not reuse another owner's bootstrap promise. */
export async function recoverScopedRejectedCredential(
  rejection: RejectedCredential,
  isCurrent: () => boolean,
  waitForCurrent?: () => Promise<boolean>,
  workspace?: ArtifactWorkspace,
): Promise<void> {
  await recoverScopedRejectedCredentialAttempt(rejection, isCurrent, waitForCurrent, workspace)
}

async function recoverScopedRejectedCredentialAttempt(
  rejection: RejectedCredential,
  isCurrent: () => boolean,
  waitForCurrent: (() => Promise<boolean>) | undefined,
  workspace: ArtifactWorkspace | undefined,
  retry?: { claim: ManagedRecoveryClaim; generation: number },
  explicit = false,
  onApplied?: () => void,
): Promise<void> {
  const owner = retry?.claim.owner ?? tokenOwner()
  if (retry && !managedRecoveryIsCurrent(retry.claim, retry.generation)) {
    releaseManagedRecovery(retry.claim)
    return
  }
  const current = () => isCurrent() && sameTokenOwner(owner, tokenOwner())
  const applyWhenCurrent = async (apply: () => void): Promise<void> => {
    while (sameTokenOwner(owner, tokenOwner())) {
      // There is no await between this check and applying the change.
      if (isCurrent()) { apply(); return }
      if (!waitForCurrent) return
      try { if (!await waitForCurrent()) return } catch { return }
    }
  }
  const resetForRecovery = (expectedGeneration: number | null): boolean => {
    if (expectedGeneration !== null && expectedGeneration !== bootstrapGeneration) return false
    const resetGeneration = bootstrapGeneration + 1
    resetDevTokenBootstrap()
    return bootstrapGeneration === resetGeneration && current()
  }
  if (owner.token !== rejection.token) return
  if (!current()) {
    if (!waitForCurrent) { if (retry) releaseManagedRecovery(retry.claim); return }
    try {
      if (!await waitForCurrent() || !current()) { if (retry) releaseManagedRecovery(retry.claim); return }
    } catch { if (retry) releaseManagedRecovery(retry.claim); return }
  }
  if (retry && !managedRecoveryIsCurrent(retry.claim, retry.generation)) {
    releaseManagedRecovery(retry.claim)
    return
  }
  if (!retry && !explicit && owner.managed && rejection.httpStatus === 401 && isCredentialRejectionCode(rejection.authErrorCode)) {
    const beforeRefusal = bootstrapGeneration
    recordManagedCredentialRefusal(owner.revision)
    if (bootstrapGeneration !== beforeRefusal || !current()) return
  }
  const meta = getStoredTokenMeta()
  let scopedGeneration: number | null = null
  if ((explicit || isRefreshableDashboardAuthCode(rejection.authErrorCode)) && !isRemoteAccess() && shouldRefreshDevToken()) {
    if (owner.managed && !workspace) { if (retry) releaseManagedRecovery(retry.claim); return }
    let claim = retry?.claim ?? null
    if (!retry && owner.managed && (explicit || (rejection.httpStatus === 401 && isCredentialRejectionCode(rejection.authErrorCode)))) {
      claim = claimManagedRecovery(owner)
      if (!claim) return
    }
    // A prior unscoped bootstrap must not publish after this recovery starts.
    const generation = bootstrapGeneration + 1
    resetDevTokenBootstrap()
    if (bootstrapGeneration !== generation || !current()) { if (claim) releaseManagedRecovery(claim); return }
    scopedGeneration = generation
    if (claim) claim.inFlight = true
    const controller = new AbortController()
    if (claim) claim.controller = controller
    const scheduleRetry = (delay = 0) => {
      if (!claim) return
      claim.inFlight = false
      scheduleManagedRecovery(claim, generation, () => {
        void recoverScopedRejectedCredentialAttempt(rejection, isCurrent, waitForCurrent, workspace, { claim, generation }, explicit, onApplied)
      }, delay)
    }
    try {
      const query = workspace ? `?${new URLSearchParams({ expected_base_path: workspace.basePath, expected_masc_root: workspace.mascRoot })}` : ''
      const { res, payload } = await fetchWithTimeout(
        `/api/v1/dashboard/dev-token${query}`,
        { method: 'GET', headers: { Accept: 'application/json' }, signal: controller.signal },
        DEV_TOKEN_FETCH_TIMEOUT_MS,
        async res => ({ res, payload: res.ok ? await res.json() as DevTokenBootstrapPayload : null }),
      )
      if (claim && managedRecoveryAttempt === claim) claim.inFlight = false
      if (claim?.controller === controller) claim.controller = null
      if (claim && !managedRecoveryIsCurrent(claim, generation)) {
        releaseManagedRecovery(claim)
        return
      }
      if (retryableTokenFailure(res.status)) {
        scheduleRetry(retryAfterMs(res))
        return
      }
      if (res.status === 404 && meta?.source === 'dev') {
        let applied = false
        await applyWhenCurrent(() => {
          if (resetForRecovery(scopedGeneration)) {
            clearStoredToken()
            applied = currentStoredTokenRevision() === owner.revision + 1 && getStoredToken() === null
            if (applied) onApplied?.()
          }
        })
        if (claim) releaseManagedRecovery(claim)
        return
      }
      if (res.ok && payload && typeof payload === 'object' && payload.actor === 'dashboard' && payload.role === 'admin') {
        const token = typeof payload.token === 'string' ? payload.token.trim() : ''
        if (token && token !== owner.token) {
          let applied = false
          await applyWhenCurrent(() => {
            if (resetForRecovery(scopedGeneration)) {
              setStoredToken(token, { source: 'dev', actor: 'dashboard', role: 'admin' })
              applied = currentStoredTokenRevision() === owner.revision + 1 && getStoredToken() === token
                && getStoredTokenMeta()?.source === 'dev'
              if (applied) onApplied?.()
            }
          })
          if (claim) releaseManagedRecovery(claim)
        }
        if (claim && token === owner.token && !current()) releaseManagedRecovery(claim)
        if (token) return
      }
      if (res.ok) (devTokenBootstrapStatus as { value: DevTokenBootstrapStatus }).value = 'invalid_response'
    } catch (error) {
      // A failed re-mint is not evidence that a loopback dev token should be cleared.
      if (claim && managedRecoveryAttempt === claim) claim.inFlight = false
      if (claim?.controller === controller) claim.controller = null
      if (claim && !managedRecoveryIsCurrent(claim, generation)) {
        releaseManagedRecovery(claim)
        return
      }
      if (error instanceof SyntaxError) (devTokenBootstrapStatus as { value: DevTokenBootstrapStatus }).value = 'invalid_response'
      else scheduleRetry()
    }
  }
  if (!isCredentialRejectionCode(rejection.authErrorCode)) return
  if (meta?.source === 'dev' && !isRemoteAccess()) return
  await applyWhenCurrent(() => {
    if (resetForRecovery(scopedGeneration)) clearStoredToken()
  })
}

let credentialRecoverySubscriptions = 0
let stopCredentialRecovery: (() => void) | null = null

export function installRejectedCredentialRecovery(): () => void {
  credentialRecoverySubscriptions += 1
  if (credentialRecoverySubscriptions === 1) {
    setRejectedCredentialListener(rejection => {
      void recoverFromRejectedCredential(rejection).catch(err => {
        console.warn('[dashboard-auth] rejected credential recovery failed', err)
      })
    })
    const observeOwner = () => {
      const claim = managedRecoveryAttempt
      const owner = tokenOwner()
      if (claim && (claim.authRevision !== managedDashboardAuthRevision.peek()
        || claim.owner.revision !== owner.revision
        || (!sameTokenOwner(claim.owner, owner)
          && (claim.inFlight || claim.timer !== null || claim.controller !== null)))) releaseManagedRecovery(claim)
      // Actor signals can fire inside setStoredToken before its final token
      // revision notification. Check the completed publication on this turn.
      queueMicrotask(() => {
        const pending = devTokenBootstrapPromise
        if (credentialRecoverySubscriptions > 0 && pending && devTokenBootstrapStatus.peek() === 'fetching'
          && !sameTokenOwner(pending.owner, tokenOwner())) resetDevTokenBootstrap()
      })
    }
    const unsubToken = subscribeStoredTokenChanges(observeOwner)
    const unsubActor = dashboardActorRevision.subscribe(observeOwner)
    const unsubManagedActor = managedDashboardActorRevision.subscribe(observeOwner)
    const unsubAuth = managedDashboardAuthRevision.subscribe(observeOwner)
    stopCredentialRecovery = () => {
      setRejectedCredentialListener(null)
      unsubToken(); unsubActor(); unsubManagedActor(); unsubAuth()
      if (managedRecoveryAttempt) releaseManagedRecovery(managedRecoveryAttempt)
      resetDevTokenBootstrap()
    }
  }
  let released = false
  return () => {
    if (released) return
    released = true
    credentialRecoverySubscriptions -= 1
    if (credentialRecoverySubscriptions === 0) { stopCredentialRecovery?.(); stopCredentialRecovery = null }
  }
}
