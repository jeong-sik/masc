import { isRecord } from './type-guards'

export interface KeeperRunTarget {
  readonly kind: 'keeper'
  readonly name: string
}

export interface KeeperRunRef {
  readonly runId: string
  readonly target: KeeperRunTarget
  readonly capability: 'invoke_turn'
}

export interface KeeperRunRefWire {
  readonly run_id: string
  readonly target: {
    readonly kind: 'keeper'
    readonly name: string
  }
  readonly capability: 'invoke_turn'
}

export interface KeeperRunTracking {
  readonly runRef: KeeperRunRef
  readonly resultContract: KeeperRunResultContract
}

export type KeeperRunResultContract =
  | 'awaiting_execution'
  | 'publication_uncertain'
  | 'running'
  | 'yielded'
  | 'cancellation_requested'
  | 'cancelled'
  | 'completed'
  | 'failed'

function exactFields(
  record: Readonly<Record<string, unknown>>,
  expected: readonly string[],
  field: string,
): void {
  const actual = Object.keys(record)
  if (
    actual.length !== expected.length
    || expected.some(name => !Object.hasOwn(record, name))
  ) {
    throw new Error(`${field} must contain exactly ${expected.join(', ')}`)
  }
}

function requiredString(value: unknown, field: string): string {
  if (typeof value !== 'string' || value.length === 0) {
    throw new Error(`${field} must be a non-empty string`)
  }
  return value
}

export function parseKeeperRunRef(value: unknown): KeeperRunRef {
  if (!isRecord(value)) throw new Error('run_ref must be an object')
  exactFields(value, ['run_id', 'target', 'capability'], 'run_ref')

  if (!isRecord(value.target)) throw new Error('run_ref.target must be an object')
  exactFields(value.target, ['kind', 'name'], 'run_ref.target')
  if (value.target.kind !== 'keeper') {
    throw new Error('run_ref.target.kind must be keeper')
  }
  if (value.capability !== 'invoke_turn') {
    throw new Error('run_ref.capability must be invoke_turn')
  }

  const target = Object.freeze<KeeperRunTarget>({
    kind: 'keeper',
    name: requiredString(value.target.name, 'run_ref.target.name'),
  })
  return Object.freeze<KeeperRunRef>({
    runId: requiredString(value.run_id, 'run_ref.run_id'),
    target,
    capability: 'invoke_turn',
  })
}

export function keeperRunRefToWire(reference: KeeperRunRef): KeeperRunRefWire {
  return {
    run_id: reference.runId,
    target: {
      kind: reference.target.kind,
      name: reference.target.name,
    },
    capability: reference.capability,
  }
}

export function keeperRunRefKey(reference: KeeperRunRef): string {
  return JSON.stringify(keeperRunRefToWire(reference))
}

export function sameKeeperRunRef(left: KeeperRunRef, right: KeeperRunRef): boolean {
  return left.runId === right.runId
    && left.target.kind === right.target.kind
    && left.target.name === right.target.name
    && left.capability === right.capability
}

export function parseKeeperRunResultContract(value: unknown): KeeperRunResultContract {
  switch (value) {
    case 'awaiting_execution':
    case 'publication_uncertain':
    case 'running':
    case 'yielded':
    case 'cancellation_requested':
    case 'cancelled':
    case 'completed':
    case 'failed':
      return value
    default:
      throw new Error(`unsupported Keeper run result contract: ${JSON.stringify(value)}`)
  }
}

export function parseKeeperRunTracking(value: unknown): KeeperRunTracking {
  if (!isRecord(value)) throw new Error('Keeper run tracking envelope must be an object')
  if (!isRecord(value.tracking)) throw new Error('Keeper run tracking must be an object')
  exactFields(value.tracking, ['kind', 'run_ref', 'result_contract'], 'tracking')
  if (value.tracking.kind !== 'keeper_run') {
    throw new Error('tracking.kind must be keeper_run')
  }
  const runRef = parseKeeperRunRef(value.tracking.run_ref)
  if (value.destination_type !== 'keeper' || value.destination_id !== runRef.target.name) {
    throw new Error('Keeper run tracking destination must match run_ref.target')
  }
  return Object.freeze({
    runRef,
    resultContract: parseKeeperRunResultContract(value.tracking.result_contract),
  })
}

export function parseKeeperRunTerminal(value: unknown): KeeperRunTracking {
  if (!isRecord(value)) throw new Error('Keeper run terminal must be an object')
  const fields = Object.keys(value)
  if (
    !Object.hasOwn(value, 'run_ref')
    || !Object.hasOwn(value, 'result_contract')
    || fields.some(field => field !== 'run_ref' && field !== 'result_contract' && field !== 'message')
  ) {
    throw new Error('Keeper run terminal must contain run_ref, result_contract, and optional message')
  }
  if (Object.hasOwn(value, 'message') && typeof value.message !== 'string') {
    throw new Error('Keeper run terminal message must be a string')
  }
  return Object.freeze({
    runRef: parseKeeperRunRef(value.run_ref),
    resultContract: parseKeeperRunResultContract(value.result_contract),
  })
}

export function isTerminalKeeperRunResult(contract: KeeperRunResultContract): boolean {
  return contract === 'yielded'
    || contract === 'cancelled'
    || contract === 'completed'
    || contract === 'failed'
}
