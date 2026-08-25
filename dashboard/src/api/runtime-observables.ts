// MASC Dashboard — Runtime observables read surface.
// Backend: lib/server/server_dashboard_http_runtime_observables.ml
// Route:   GET /api/v1/dashboard/runtime-observables
//
// The store writer (Otel_runtime_observables, masc#29023) lands process
// runtime health in Otel_metric_store every 30s; this endpoint re-groups
// the cells into typed blocks. Numbers are null when the writer has not
// landed the cell yet — absence stays distinguishable from a written zero.

import { get } from './core'
import { asNumber, isRecord } from '../components/common/normalize'

export interface RuntimeObservablesConsoleSink {
  queue_depth: number | null
  dropped_total: number | null
}

export interface RuntimeObservablesTransitionAudit {
  queue_depth: number | null
}

export interface RuntimeObservablesFdOperation {
  kind: string
  count: number
}

export interface RuntimeObservablesFdError {
  kind: string
  error: string
  count: number
}

export interface RuntimeObservablesFd {
  open: number | null
  limit: number | null
  active_operations: RuntimeObservablesFdOperation[]
  resource_errors: RuntimeObservablesFdError[]
}

export interface RuntimeObservablesStoreEntry {
  store: string
  bytes: number
  files: number | null
}

export interface RuntimeObservablesBusContract {
  purpose: string
  capacity: number | null
  overflow: string
  depth: number
  dropped_total: number | null
  capacity_total: number | null
}

export interface RuntimeObservablesBus {
  bus: string
  subscribers: number
  contracts: RuntimeObservablesBusContract[]
}

export interface RuntimeObservablesPool {
  idle: number | null
  inflight: number | null
  reuse_total: number | null
  evict_total: number | null
  evict_failure_total: number | null
  create_total: number | null
}

export interface RuntimeObservablesSnapshot {
  last_write_unixtime: number | null
  age_seconds: number | null
  console_sink: RuntimeObservablesConsoleSink
  transition_audit: RuntimeObservablesTransitionAudit
  fd: RuntimeObservablesFd
  stores: RuntimeObservablesStoreEntry[]
  event_bus: RuntimeObservablesBus[]
  pool: RuntimeObservablesPool
}

function numberOrNull(value: unknown): number | null {
  if (value === null || value === undefined) return null
  return asNumber(value) ?? null
}

function requiredNumber(value: unknown): number | undefined {
  return asNumber(value)
}

function requiredString(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined
}

function decodeFdOperation(raw: unknown): RuntimeObservablesFdOperation | null {
  if (!isRecord(raw)) return null
  const kind = requiredString(raw.kind)
  const count = requiredNumber(raw.count)
  if (kind === undefined || count === undefined) return null
  return { kind, count }
}

function decodeFdError(raw: unknown): RuntimeObservablesFdError | null {
  if (!isRecord(raw)) return null
  const kind = requiredString(raw.kind)
  const error = requiredString(raw.error)
  const count = requiredNumber(raw.count)
  if (kind === undefined || error === undefined || count === undefined) return null
  return { kind, error, count }
}

function decodeStoreEntry(raw: unknown): RuntimeObservablesStoreEntry | null {
  if (!isRecord(raw)) return null
  const store = requiredString(raw.store)
  const bytes = requiredNumber(raw.bytes)
  if (store === undefined || bytes === undefined) return null
  return { store, bytes, files: numberOrNull(raw.files) }
}

function decodeBusContract(raw: unknown): RuntimeObservablesBusContract | null {
  if (!isRecord(raw)) return null
  const purpose = requiredString(raw.purpose)
  const overflow = requiredString(raw.overflow)
  const depth = requiredNumber(raw.depth)
  if (purpose === undefined || overflow === undefined || depth === undefined) return null
  return {
    purpose,
    overflow,
    depth,
    capacity: numberOrNull(raw.capacity),
    dropped_total: numberOrNull(raw.dropped_total),
    capacity_total: numberOrNull(raw.capacity_total),
  }
}

function decodeBus(raw: unknown): RuntimeObservablesBus | null {
  if (!isRecord(raw)) return null
  const bus = requiredString(raw.bus)
  const subscribers = requiredNumber(raw.subscribers)
  if (bus === undefined || subscribers === undefined) return null
  if (!Array.isArray(raw.contracts)) return null
  const contracts: RuntimeObservablesBusContract[] = []
  for (const entry of raw.contracts) {
    const contract = decodeBusContract(entry)
    if (contract === null) return null
    contracts.push(contract)
  }
  return { bus, subscribers, contracts }
}

function decodeAll<T>(raw: unknown, decode: (entry: unknown) => T | null): T[] | null {
  if (!Array.isArray(raw)) return null
  const out: T[] = []
  for (const entry of raw) {
    const decoded = decode(entry)
    if (decoded === null) return null
    out.push(decoded)
  }
  return out
}

export function decodeRuntimeObservables(raw: unknown): RuntimeObservablesSnapshot | null {
  if (!isRecord(raw)) return null
  if (!isRecord(raw.console_sink)) return null
  if (!isRecord(raw.transition_audit)) return null
  if (!isRecord(raw.fd)) return null
  if (!isRecord(raw.pool)) return null
  const activeOperations = decodeAll(raw.fd.active_operations, decodeFdOperation)
  const resourceErrors = decodeAll(raw.fd.resource_errors, decodeFdError)
  const stores = decodeAll(raw.stores, decodeStoreEntry)
  const eventBus = decodeAll(raw.event_bus, decodeBus)
  if (
    activeOperations === null
    || resourceErrors === null
    || stores === null
    || eventBus === null
  ) return null
  return {
    last_write_unixtime: numberOrNull(raw.last_write_unixtime),
    age_seconds: numberOrNull(raw.age_seconds),
    console_sink: {
      queue_depth: numberOrNull(raw.console_sink.queue_depth),
      dropped_total: numberOrNull(raw.console_sink.dropped_total),
    },
    transition_audit: {
      queue_depth: numberOrNull(raw.transition_audit.queue_depth),
    },
    fd: {
      open: numberOrNull(raw.fd.open),
      limit: numberOrNull(raw.fd.limit),
      active_operations: activeOperations,
      resource_errors: resourceErrors,
    },
    stores,
    event_bus: eventBus,
    pool: {
      idle: numberOrNull(raw.pool.idle),
      inflight: numberOrNull(raw.pool.inflight),
      reuse_total: numberOrNull(raw.pool.reuse_total),
      evict_total: numberOrNull(raw.pool.evict_total),
      evict_failure_total: numberOrNull(raw.pool.evict_failure_total),
      create_total: numberOrNull(raw.pool.create_total),
    },
  }
}

export function fetchRuntimeObservables(): Promise<RuntimeObservablesSnapshot> {
  return get<unknown>('/api/v1/dashboard/runtime-observables').then((raw) => {
    const decoded = decodeRuntimeObservables(raw)
    if (!decoded) throw new Error('유효하지 않은 runtime observables payload')
    return decoded
  })
}
