/**
 * Epoch-Scoped, In-Flight Deduplicated, Byte-Bounded Workspace Media Runtime Cache.
 *
 * Replaces per-component `FileReader.readAsDataURL` fetching with:
 * - Keyed by `${epoch}:${path}` so switching workspaces/sessions immediately isolates
 *   and revokes prior workspace blobs.
 * - In-flight request deduplication with reference-counted waiter tracking: aborting one
 *   caller detaches that waiter without cancelling sibling callers, while aborting all
 *   waiters (or bumping `sessionEpoch`) aborts the underlying HTTP stream cleanly.
 * - Byte-bounded (64 MiB) + entry-bounded (128 entries) LRU cache using `URL.createObjectURL`
 *   with explicit ref-counted leases (`release()`); `URL.revokeObjectURL` is called
 *   deterministically when `refCount === 0` upon eviction, epoch bump, or cache clear.
 * - On-demand `acquireWorkspaceMediaDataUrl` and inert `DOMParser`-based
 *   `hydrateSandboxedHtmlMedia` strictly for `<iframe sandbox="" srcDoc>` HTML artifacts.
 */

import { fetchWithTimeout } from '../api/core'
import { DEFAULT_GET_TIMEOUT_MS } from '../config/constants'
import {
  authSession,
  currentSessionEpoch,
  getSingleUserToken,
  isEpochCurrent,
  resolveWorkspaceUrl,
  sessionEpoch,
} from '../core/auth'
import { isAbortError } from './async-state'
import {
  WORKSPACE_MEDIA_MAX_BYTES,
  containsWorkspaceMediaRef,
  hasWorkspaceMediaPrefix,
  isWorkspaceMediaPath,
  parseWorkspaceRasterMime,
  type WorkspaceRasterMime,
} from './keeper-media'
import { parseUrl } from './parse-url'
import { err, ok, type Result } from './result'

export const WORKSPACE_MEDIA_CACHE_MAX_BYTES = 64 * 1024 * 1024
export const WORKSPACE_MEDIA_CACHE_MAX_ENTRIES = 128

export const SANDBOX_HTML_MAX_MEDIA_ITEMS = 32
export const SANDBOX_HTML_MAX_TOTAL_BYTES = 32 * 1024 * 1024
const SANDBOX_HTML_FETCH_CONCURRENCY = 4
const BASE64_CHUNK_BYTES = 0x8000

export type WorkspaceMediaError =
  | { readonly kind: 'invalid_path'; readonly path: string }
  | { readonly kind: 'cross_origin'; readonly path: string }
  | { readonly kind: 'stale_epoch'; readonly expected: number; readonly actual: number }
  | { readonly kind: 'aborted' }
  | { readonly kind: 'http_error'; readonly status: number }
  | { readonly kind: 'unsupported_mime'; readonly contentType: string | null }
  | { readonly kind: 'too_large'; readonly maxBytes: number }
  | { readonly kind: 'empty_body' }
  | { readonly kind: 'network_error'; readonly message: string }

export interface WorkspaceMediaObjectUrlLease {
  readonly url: string
  readonly mime: WorkspaceRasterMime
  readonly bytes: number
  readonly epoch: number
  readonly path: string
  readonly retain: () => WorkspaceMediaObjectUrlLease
  readonly release: () => void
}

export interface WorkspaceMediaDataUrlResult {
  readonly dataUrl: string
  readonly mime: WorkspaceRasterMime
  readonly bytes: number
  readonly epoch: number
  readonly path: string
}

export interface AcquireMediaOptions {
  readonly epoch?: number
  readonly signal?: AbortSignal
}

export interface WorkspaceMediaCacheStats {
  readonly entries: number
  readonly totalBytes: number
  readonly inFlight: number
  readonly activeLeases: number
}

interface CacheEntry {
  readonly key: string
  readonly epoch: number
  readonly path: string
  readonly mime: WorkspaceRasterMime
  readonly bytes: number
  readonly blob: Blob
  objectUrl: string | null
  objectUrlRevocable: boolean
  refCount: number
  evicted: boolean
}

interface InFlightFetch {
  readonly key: string
  readonly epoch: number
  readonly controller: AbortController
  readonly waiters: Set<symbol>
  readonly promise: Promise<Result<CacheEntry, WorkspaceMediaError>>
}

const cacheEntries = new Map<string, CacheEntry>()
const inFlightFetches = new Map<string, InFlightFetch>()
let totalCachedBytes = 0
let totalActiveLeases = 0
let lastObservedEpoch = sessionEpoch.peek()

function cacheKey(epoch: number, path: string): string {
  return `${epoch}:${path}`
}

function canUseObjectUrlApi(): boolean {
  return typeof URL !== 'undefined'
    && typeof URL.createObjectURL === 'function'
    && typeof URL.revokeObjectURL === 'function'
}

function revokeEntryObjectUrl(entry: CacheEntry): void {
  if (entry.objectUrl !== null && entry.objectUrlRevocable) {
    try {
      URL.revokeObjectURL(entry.objectUrl)
    } catch {
      // Best-effort revocation when test harnesses stub or replace URL.
    }
  }
  entry.objectUrl = null
  entry.objectUrlRevocable = false
}

function dropEntryFromMap(entry: CacheEntry): void {
  if (cacheEntries.delete(entry.key)) {
    totalCachedBytes = Math.max(0, totalCachedBytes - entry.bytes)
  }
  entry.evicted = true
  if (entry.refCount === 0) {
    revokeEntryObjectUrl(entry)
  }
}

function evictOverflow(): void {
  if (
    totalCachedBytes <= WORKSPACE_MEDIA_CACHE_MAX_BYTES
    && cacheEntries.size <= WORKSPACE_MEDIA_CACHE_MAX_ENTRIES
  ) {
    return
  }

  // Pass 1: evict least-recently-used entries that hold zero active leases.
  for (const entry of [...cacheEntries.values()]) {
    if (
      totalCachedBytes <= WORKSPACE_MEDIA_CACHE_MAX_BYTES
      && cacheEntries.size <= WORKSPACE_MEDIA_CACHE_MAX_ENTRIES
    ) {
      return
    }
    if (entry.refCount === 0) {
      dropEntryFromMap(entry)
    }
  }

  // Pass 2: if still over budget (all remaining entries are mounted), detach the
  // oldest entries from the lookup map and mark them evicted so their object URLs
  // are revoked the instant their final lease calls `release()`.
  for (const entry of [...cacheEntries.values()]) {
    if (
      totalCachedBytes <= WORKSPACE_MEDIA_CACHE_MAX_BYTES
      && cacheEntries.size <= WORKSPACE_MEDIA_CACHE_MAX_ENTRIES
    ) {
      return
    }
    dropEntryFromMap(entry)
  }
}

function touchEntry(entry: CacheEntry): void {
  if (!cacheEntries.has(entry.key)) return
  cacheEntries.delete(entry.key)
  cacheEntries.set(entry.key, entry)
}

function insertEntry(entry: CacheEntry): void {
  const existing = cacheEntries.get(entry.key)
  if (existing && existing !== entry) {
    dropEntryFromMap(existing)
  }
  if (entry.bytes > WORKSPACE_MEDIA_CACHE_MAX_BYTES) {
    // Larger than the whole cache budget: serve once without storing in LRU;
    // `evicted = true` guarantees immediate revocation when its lease releases.
    entry.evicted = true
    return
  }
  cacheEntries.set(entry.key, entry)
  totalCachedBytes += entry.bytes
  evictOverflow()
}

function purgeNonMatchingEpoch(activeEpoch: number): void {
  for (const [key, inflight] of [...inFlightFetches.entries()]) {
    if (inflight.epoch !== activeEpoch) {
      inFlightFetches.delete(key)
      inflight.controller.abort()
    }
  }
  for (const entry of [...cacheEntries.values()]) {
    if (entry.epoch !== activeEpoch) {
      dropEntryFromMap(entry)
    }
  }
}

sessionEpoch.subscribe((nextEpoch) => {
  if (nextEpoch === lastObservedEpoch) return
  lastObservedEpoch = nextEpoch
  purgeNonMatchingEpoch(nextEpoch)
})

export function clearWorkspaceMediaCache(): void {
  for (const [key, inflight] of [...inFlightFetches.entries()]) {
    inFlightFetches.delete(key)
    inflight.controller.abort()
  }
  for (const entry of [...cacheEntries.values()]) {
    dropEntryFromMap(entry)
  }
  totalCachedBytes = 0
}

export function getWorkspaceMediaCacheStats(): WorkspaceMediaCacheStats {
  return {
    entries: cacheEntries.size,
    totalBytes: totalCachedBytes,
    inFlight: inFlightFetches.size,
    activeLeases: totalActiveLeases,
  }
}

async function readValidatedRasterResponse(
  response: Response,
): Promise<Result<{ readonly blob: Blob; readonly mime: WorkspaceRasterMime; readonly bytes: number }, WorkspaceMediaError>> {
  if (!response.ok) {
    await response.body?.cancel().catch(() => undefined)
    return err({ kind: 'http_error', status: response.status })
  }

  const rawContentType = response.headers.get('content-type')
  const mime = parseWorkspaceRasterMime(rawContentType)
  if (mime === null) {
    await response.body?.cancel().catch(() => undefined)
    return err({ kind: 'unsupported_mime', contentType: rawContentType })
  }

  const declaredLengthHeader = response.headers.get('content-length')
  if (declaredLengthHeader !== null) {
    const declaredBytes = Number(declaredLengthHeader)
    if (Number.isFinite(declaredBytes) && declaredBytes > WORKSPACE_MEDIA_MAX_BYTES) {
      await response.body?.cancel().catch(() => undefined)
      return err({ kind: 'too_large', maxBytes: WORKSPACE_MEDIA_MAX_BYTES })
    }
  }

  if (!response.body) {
    return err({ kind: 'empty_body' })
  }

  const reader = response.body.getReader()
  const chunks: ArrayBuffer[] = []
  let size = 0
  try {
    for (;;) {
      const { done, value } = await reader.read()
      if (done) {
        if (size === 0) return err({ kind: 'empty_body' })
        return ok({
          blob: new Blob(chunks, { type: mime }),
          mime,
          bytes: size,
        })
      }
      size += value.byteLength
      if (size > WORKSPACE_MEDIA_MAX_BYTES) {
        await reader.cancel().catch(() => undefined)
        return err({ kind: 'too_large', maxBytes: WORKSPACE_MEDIA_MAX_BYTES })
      }
      chunks.push(value.slice().buffer)
    }
  } finally {
    reader.releaseLock()
  }
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = ''
  for (let offset = 0; offset < bytes.byteLength; offset += BASE64_CHUNK_BYTES) {
    const slice = bytes.subarray(offset, offset + BASE64_CHUNK_BYTES)
    binary += String.fromCharCode(...slice)
  }
  return btoa(binary)
}

async function blobToDataUrl(blob: Blob, mime: WorkspaceRasterMime): Promise<string> {
  if (typeof blob.arrayBuffer === 'function' && typeof btoa === 'function') {
    const buffer = await blob.arrayBuffer()
    return `data:${mime};base64,${bytesToBase64(new Uint8Array(buffer))}`
  }
  return new Promise<string>((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => {
      if (typeof reader.result === 'string') resolve(reader.result)
      else reject(new Error('Failed to encode media blob as data URL'))
    }
    reader.onerror = () => reject(reader.error ?? new Error('FileReader failed'))
    reader.readAsDataURL(blob)
  })
}

async function fetchMediaEntry(
  path: string,
  epoch: number,
  key: string,
  signal: AbortSignal,
): Promise<Result<CacheEntry, WorkspaceMediaError>> {
  const origin = typeof window !== 'undefined' && window.location?.origin
    ? window.location.origin
    : 'http://localhost'
  const destination = parseUrl(resolveWorkspaceUrl(path), origin)
  if (!destination || destination.origin !== origin) {
    return err({ kind: 'cross_origin', path })
  }

  const token = authSession.peek().kind === 'multi_account_signed_in'
    ? null
    : getSingleUserToken()

  try {
    const consumed = await fetchWithTimeout(
      destination.href,
      {
        credentials: 'same-origin',
        mode: 'same-origin',
        redirect: 'error',
        cache: 'default',
        signal,
        headers: token ? { Authorization: `Bearer ${token}` } : undefined,
      },
      DEFAULT_GET_TIMEOUT_MS,
      readValidatedRasterResponse,
    )
    if (signal.aborted) return err({ kind: 'aborted' })
    const currentEpoch = currentSessionEpoch()
    if (currentEpoch !== epoch) {
      return err({ kind: 'stale_epoch', expected: epoch, actual: currentEpoch })
    }
    if (!consumed.ok) return consumed

    const entry: CacheEntry = {
      key,
      epoch,
      path,
      mime: consumed.value.mime,
      bytes: consumed.value.bytes,
      blob: consumed.value.blob,
      objectUrl: null,
      objectUrlRevocable: false,
      refCount: 0,
      evicted: false,
    }
    insertEntry(entry)
    return ok(entry)
  } catch (error) {
    if (signal.aborted || isAbortError(error)) {
      return err({ kind: 'aborted' })
    }
    return err({
      kind: 'network_error',
      message: error instanceof Error ? error.message : String(error),
    })
  }
}

async function acquireEntry(
  path: string,
  options: AcquireMediaOptions = {},
): Promise<Result<CacheEntry, WorkspaceMediaError>> {
  if (!isWorkspaceMediaPath(path)) {
    return err({ kind: 'invalid_path', path })
  }

  const epoch = options.epoch ?? currentSessionEpoch()
  const actualEpoch = currentSessionEpoch()
  if (actualEpoch !== epoch) {
    return err({ kind: 'stale_epoch', expected: epoch, actual: actualEpoch })
  }
  if (options.signal?.aborted) {
    return err({ kind: 'aborted' })
  }

  const key = cacheKey(epoch, path)
  const cached = cacheEntries.get(key)
  if (cached && !cached.evicted && cached.epoch === epoch) {
    touchEntry(cached)
    return ok(cached)
  }

  let inflight = inFlightFetches.get(key)
  if (!inflight) {
    const controller = new AbortController()
    const waiters = new Set<symbol>()
    const promise = fetchMediaEntry(path, epoch, key, controller.signal).finally(() => {
      if (inFlightFetches.get(key) === inflight) {
        inFlightFetches.delete(key)
      }
    })
    inflight = { key, epoch, controller, waiters, promise }
    inFlightFetches.set(key, inflight)
  }

  const waiterId = Symbol('media-waiter')
  inflight.waiters.add(waiterId)

  const callerSignal = options.signal
  if (!callerSignal) {
    try {
      const result = await inflight.promise
      const afterEpoch = currentSessionEpoch()
      if (afterEpoch !== epoch) {
        return err({ kind: 'stale_epoch', expected: epoch, actual: afterEpoch })
      }
      return result
    } finally {
      inflight.waiters.delete(waiterId)
    }
  }

  return new Promise<Result<CacheEntry, WorkspaceMediaError>>((resolve) => {
    let settled = false
    const onAbort = () => {
      if (settled) return
      settled = true
      inflight.waiters.delete(waiterId)
      if (inflight.waiters.size === 0) {
        if (inFlightFetches.get(key) === inflight) {
          inFlightFetches.delete(key)
        }
        inflight.controller.abort()
      }
      resolve(err({ kind: 'aborted' }))
    }

    if (callerSignal.aborted) {
      onAbort()
      return
    }
    callerSignal.addEventListener('abort', onAbort, { once: true })

    void inflight.promise.then((result) => {
      callerSignal.removeEventListener('abort', onAbort)
      inflight.waiters.delete(waiterId)
      if (settled) return
      settled = true
      if (callerSignal.aborted) {
        resolve(err({ kind: 'aborted' }))
        return
      }
      const afterEpoch = currentSessionEpoch()
      if (afterEpoch !== epoch) {
        resolve(err({ kind: 'stale_epoch', expected: epoch, actual: afterEpoch }))
        return
      }
      resolve(result)
    })
  })
}

function createLeaseSync(entry: CacheEntry, url: string): WorkspaceMediaObjectUrlLease {
  entry.refCount += 1
  totalActiveLeases += 1
  let released = false

  return {
    url,
    mime: entry.mime,
    bytes: entry.bytes,
    epoch: entry.epoch,
    path: entry.path,
    retain: () => {
      if (released) {
        throw new Error('Cannot retain a released WorkspaceMediaObjectUrlLease')
      }
      return createLeaseSync(entry, url)
    },
    release: () => {
      if (released) return
      released = true
      entry.refCount = Math.max(0, entry.refCount - 1)
      totalActiveLeases = Math.max(0, totalActiveLeases - 1)
      if (entry.evicted && entry.refCount === 0) {
        revokeEntryObjectUrl(entry)
      } else if (entry.refCount === 0) {
        evictOverflow()
      }
    },
  }
}

async function createLease(entry: CacheEntry): Promise<WorkspaceMediaObjectUrlLease> {
  if (entry.objectUrl === null) {
    if (canUseObjectUrlApi()) {
      entry.objectUrl = URL.createObjectURL(entry.blob)
      entry.objectUrlRevocable = true
    } else {
      entry.objectUrl = await blobToDataUrl(entry.blob, entry.mime)
      entry.objectUrlRevocable = false
    }
  }
  return createLeaseSync(entry, entry.objectUrl)
}

/**
 * Acquires a ref-counted `blob:` object URL lease for a workspace raster image.
 * Callers MUST call `result.value.release()` when unmounting or swapping images.
 */
export async function acquireWorkspaceMediaObjectUrl(
  path: string,
  options: AcquireMediaOptions = {},
): Promise<Result<WorkspaceMediaObjectUrlLease, WorkspaceMediaError>> {
  const epoch = options.epoch ?? currentSessionEpoch()
  const entryRes = await acquireEntry(path, { epoch, signal: options.signal })
  if (!entryRes.ok) return entryRes

  const entry = entryRes.value
  const lease = await createLease(entry)
  if (options.signal?.aborted) {
    lease.release()
    return err({ kind: 'aborted' })
  }
  const actualEpoch = currentSessionEpoch()
  if (actualEpoch !== epoch) {
    lease.release()
    return err({ kind: 'stale_epoch', expected: epoch, actual: actualEpoch })
  }
  return ok(lease)
}

/**
 * Acquires an inline `data:<mime>;base64,...` URI for `<iframe sandbox="" srcDoc>`
 * hydration ONLY. Reuses the same epoch-scoped, in-flight deduplicated blob cache
 * without pinning base64 copies in the LRU.
 */
export async function acquireWorkspaceMediaDataUrl(
  path: string,
  options: AcquireMediaOptions = {},
): Promise<Result<WorkspaceMediaDataUrlResult, WorkspaceMediaError>> {
  const epoch = options.epoch ?? currentSessionEpoch()
  const entryRes = await acquireEntry(path, { epoch, signal: options.signal })
  if (!entryRes.ok) return entryRes

  try {
    const dataUrl = await blobToDataUrl(entryRes.value.blob, entryRes.value.mime)
    if (options.signal?.aborted) return err({ kind: 'aborted' })
    const actualEpoch = currentSessionEpoch()
    if (actualEpoch !== epoch) {
      return err({ kind: 'stale_epoch', expected: epoch, actual: actualEpoch })
    }
    return ok({
      dataUrl,
      mime: entryRes.value.mime,
      bytes: entryRes.value.bytes,
      epoch: entryRes.value.epoch,
      path: entryRes.value.path,
    })
  } catch (error) {
    return err({
      kind: 'network_error',
      message: error instanceof Error ? error.message : String(error),
    })
  }
}

export interface SandboxedHtmlMediaHydrationResult {
  readonly html: string
  readonly resolvedCount: number
  readonly failedCount: number
  readonly skippedCount: number
  readonly totalBytes: number
}

/**
 * Resolves authenticated `/api/v1/media/<sha256>` `img[src]` references inside an HTML
 * artifact before assigning it to `<iframe sandbox="" srcDoc>`.
 *
 * Security & resource invariants:
 * - Parses with inert `DOMParser` (scripts never execute, zero network requests on parse).
 * - Never relaxes `sandbox=""` (returns self-contained HTML with inlined `data:` URIs).
 * - Strictly caps unique media paths (32) and cumulative raw bytes (32 MiB).
 * - Only touches strict `isWorkspaceMediaPath` `img[src]` values; external/invalid URLs are untouched.
 */
export async function hydrateSandboxedHtmlMedia(
  rawHtml: string,
  options: AcquireMediaOptions = {},
): Promise<Result<SandboxedHtmlMediaHydrationResult, WorkspaceMediaError>> {
  const epoch = options.epoch ?? currentSessionEpoch()
  if (!isEpochCurrent(epoch)) {
    return err({ kind: 'stale_epoch', expected: epoch, actual: currentSessionEpoch() })
  }
  if (options.signal?.aborted) {
    return err({ kind: 'aborted' })
  }
  if (!containsWorkspaceMediaRef(rawHtml) || typeof DOMParser === 'undefined') {
    return ok({ html: rawHtml, resolvedCount: 0, failedCount: 0, skippedCount: 0, totalBytes: 0 })
  }

  const parsed = new DOMParser().parseFromString(rawHtml, 'text/html')
  const doctypePrefix = parsed.doctype
    ? `<!DOCTYPE ${parsed.doctype.name}${parsed.doctype.publicId ? ` PUBLIC "${parsed.doctype.publicId}"` : ''}${parsed.doctype.systemId ? ` "${parsed.doctype.systemId}"` : ''}>\n`
    : ''

  const elementsByPath = new Map<string, HTMLImageElement[]>()
  let invalidCount = 0
  for (const img of parsed.querySelectorAll('img[src]')) {
    const src = img.getAttribute('src')?.trim() ?? ''
    if (!hasWorkspaceMediaPrefix(src)) continue
    if (!isWorkspaceMediaPath(src)) {
      img.removeAttribute('src')
      img.setAttribute('data-masc-media-status', 'invalid')
      invalidCount += 1
      continue
    }
    const list = elementsByPath.get(src)
    if (list) list.push(img as HTMLImageElement)
    else elementsByPath.set(src, [img as HTMLImageElement])
  }

  if (elementsByPath.size === 0) {
    if (invalidCount === 0) {
      return ok({ html: rawHtml, resolvedCount: 0, failedCount: 0, skippedCount: 0, totalBytes: 0 })
    }
    return ok({
      html: doctypePrefix + parsed.documentElement.outerHTML,
      resolvedCount: 0,
      failedCount: invalidCount,
      skippedCount: 0,
      totalBytes: 0,
    })
  }

  const allPaths = [...elementsByPath.keys()]
  const selectedPaths = allPaths.slice(0, SANDBOX_HTML_MAX_MEDIA_ITEMS)
  const overflowPaths = allPaths.slice(SANDBOX_HTML_MAX_MEDIA_ITEMS)

  let skippedCount = overflowPaths.length
  for (const skippedPath of overflowPaths) {
    for (const img of elementsByPath.get(skippedPath) ?? []) {
      img.removeAttribute('src')
      img.setAttribute('data-masc-media-status', 'skipped_limit')
    }
  }

  const resolvedMap = new Map<string, WorkspaceMediaDataUrlResult>()
  const budgetSkippedPaths = new Set<string>()
  let failedCount = invalidCount
  let fetchedBytes = 0
  let cursor = 0

  const worker = async (): Promise<void> => {
    while (cursor < selectedPaths.length) {
      if (options.signal?.aborted || !isEpochCurrent(epoch)) return
      const path = selectedPaths[cursor]!
      cursor += 1
      if (fetchedBytes >= SANDBOX_HTML_MAX_TOTAL_BYTES) {
        budgetSkippedPaths.add(path)
        continue
      }
      const res = await acquireWorkspaceMediaDataUrl(path, { epoch, signal: options.signal })
      if (options.signal?.aborted || !isEpochCurrent(epoch)) return
      if (res.ok) {
        fetchedBytes += res.value.bytes
        resolvedMap.set(path, res.value)
      } else if (res.error.kind !== 'aborted') {
        failedCount += 1
      }
    }
  }

  const concurrency = Math.min(SANDBOX_HTML_FETCH_CONCURRENCY, selectedPaths.length)
  await Promise.all(Array.from({ length: concurrency }, () => worker()))

  if (options.signal?.aborted) {
    return err({ kind: 'aborted' })
  }
  const actualEpoch = currentSessionEpoch()
  if (actualEpoch !== epoch) {
    return err({ kind: 'stale_epoch', expected: epoch, actual: actualEpoch })
  }

  let resolvedCount = 0
  let totalBytes = 0
  for (const path of selectedPaths) {
    const imgs = elementsByPath.get(path) ?? []
    if (budgetSkippedPaths.has(path)) {
      skippedCount += 1
      for (const img of imgs) {
        img.removeAttribute('src')
        img.setAttribute('data-masc-media-status', 'skipped_budget')
      }
      continue
    }
    const item = resolvedMap.get(path)
    if (!item) {
      for (const img of imgs) {
        img.removeAttribute('src')
        img.setAttribute('data-masc-media-status', 'unavailable')
      }
      continue
    }
    if (totalBytes + item.bytes > SANDBOX_HTML_MAX_TOTAL_BYTES) {
      skippedCount += 1
      for (const img of imgs) {
        img.removeAttribute('src')
        img.setAttribute('data-masc-media-status', 'skipped_budget')
      }
      continue
    }
    totalBytes += item.bytes
    resolvedCount += 1
    for (const img of imgs) {
      img.setAttribute('src', item.dataUrl)
    }
  }

  const serialized = doctypePrefix + parsed.documentElement.outerHTML
  return ok({
    html: serialized,
    resolvedCount,
    failedCount,
    skippedCount,
    totalBytes,
  })
}
