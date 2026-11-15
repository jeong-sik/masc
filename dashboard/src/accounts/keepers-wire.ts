// What the console sends about the Keepers of a signed-in person and how it
// reads the answers (lib/auth_preview_keeper.ml, `list`, `make` and
// `assign`). An answer that is not what the route promises is not read.

import { isRecord } from '../lib/type-guards'
import { bodyOf, csrfHeader, deliver, get, problemOf } from './wire'
import type { Answer, Send } from './wire'

export const keepersPath = '/api/v1/auth/keepers'
export const assignPath = `${keepersPath}/assign`

/** A Keeper of the person, and the id of the Runtime it runs on, or null before it is given one. */
export interface Keeper {
  readonly id: string
  readonly runtimeId: string | null
}

const text = (value: unknown): string | null => (typeof value === 'string' && value !== '' ? value : null)

function readKeeper(json: unknown): Keeper | null {
  if (!isRecord(json)) return null
  const id = text(json.keeper_id)
  if (id === null) return null
  if (json.runtime_id === null) return { id, runtimeId: null }
  const runtimeId = text(json.runtime_id)
  return runtimeId === null ? null : { id, runtimeId }
}

/** The Keepers of the person, or null when any is not what the route promises. */
export function readKeepers(json: unknown): readonly Keeper[] | null {
  if (!isRecord(json) || !Array.isArray(json.keepers)) return null
  const keepers = (json.keepers as readonly unknown[]).map(readKeeper)
  return keepers.every((one): one is Keeper => one !== null) ? keepers : null
}

/** What a make came to: `existing` when the person had made a Keeper of the name before. */
export interface Made { readonly id: string; readonly existing: boolean }

export function readMade(json: unknown): Made | null {
  if (!isRecord(json)) return null
  const id = text(json.keeper_id)
  if (id === null || (json.record !== 'made' && json.record !== 'existing')) return null
  return { id, existing: json.record === 'existing' }
}

/** What an assignment came to: `existing` when the Keeper already ran on that Runtime. */
export interface Assigned { readonly id: string; readonly runtimeId: string; readonly existing: boolean }

export function readAssigned(json: unknown): Assigned | null {
  if (!isRecord(json)) return null
  const id = text(json.keeper_id)
  const runtimeId = text(json.runtime_id)
  if (id === null || runtimeId === null || (json.record !== 'assigned' && json.record !== 'existing')) return null
  return { id, runtimeId, existing: json.record === 'existing' }
}

async function post<T>(to: Send, path: string, csrfToken: string, body: unknown, read: (json: unknown) => T | null): Promise<Answer<T>> {
  const response = await deliver(to, path, {
    method: 'POST',
    headers: { accept: 'application/json', 'content-type': 'application/json', [csrfHeader]: csrfToken },
    body: JSON.stringify(body),
  })
  if (response === null) return { ok: false, problem: { kind: 'unreachable' } }
  if (!response.ok) return { ok: false, problem: await problemOf(response) }
  const value = read(await bodyOf(response))
  return value === null ? { ok: false, problem: { kind: 'unreadable' } } : { ok: true, value }
}

export const readList = (to: Send): Promise<Answer<readonly Keeper[]>> => get(to, keepersPath, readKeepers)
export const make = (to: Send, csrfToken: string, name: string): Promise<Answer<Made>> =>
  post(to, keepersPath, csrfToken, { keeper_id: name }, readMade)
export const assign = (to: Send, csrfToken: string, name: string, runtimeId: string): Promise<Answer<Assigned>> =>
  post(to, assignPath, csrfToken, { keeper_id: name, runtime_id: runtimeId }, readAssigned)
