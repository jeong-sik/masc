// What the console reads about the people of the account server
// (lib/auth/login_member_routes.mli, `list`). Only the session of an Admin is
// answered. An answer that is not what the route promises is not read.

import { isRecord } from '../lib/type-guards'
import { get } from './wire'
import type { Answer, Send } from './wire'

export const membersPath = '/api/v1/auth/members'

/** The account a person signs in with (lib/auth/authz_external_identity.ml).
    `unrecognised` is a way of signing in this console does not know. */
export type Identity =
  | { readonly provider: 'github'; readonly userId: number }
  | { readonly provider: 'google'; readonly sub: string }
  | { readonly provider: 'unrecognised' }

export type MemberRole = 'admin' | 'member'

const roles: readonly MemberRole[] = ['admin', 'member']

/** Whether the person can sign in and act. `unrecognised` is a word this console does not know. */
export type MemberStatus = 'active' | 'disabled' | 'unrecognised'

const statuses = ['active', 'disabled'] as const

/** A change to a person the log did not record, which the server holds: the
    end of an Admin assignment, a disable, or a delete
    (lib/auth/authz_external_store.mli, `authz_event_label`). */
export type HeldChange = 'revoke' | 'disable' | 'delete' | 'unrecognised'

const heldChanges = ['revoke', 'disable', 'delete'] as const

export interface Member {
  readonly userId: string
  readonly identity: Identity
  readonly role: MemberRole
  readonly status: MemberStatus
  /** Each kind once, in the order of the server; empty when nothing is held. */
  readonly held: readonly HeldChange[]
}

const text = (value: unknown): string | null => (typeof value === 'string' && value !== '' ? value : null)

/** An identity as the server writes it: its members in this order, a GitHub
    user id a positive number, a Google sub a string. */
export function readIdentity(json: unknown): Identity | null {
  if (!isRecord(json) || typeof json.provider !== 'string') return null
  const members = Object.keys(json).join(',')
  switch (json.provider) {
    case 'github': {
      const userId = json.user_id
      return members === 'provider,user_id' && typeof userId === 'number' && Number.isSafeInteger(userId) && userId > 0
        ? { provider: 'github', userId }
        : null
    }
    case 'google': {
      const sub = text(json.sub)
      return members === 'provider,sub' && sub !== null ? { provider: 'google', sub } : null
    }
    default:
      return { provider: 'unrecognised' }
  }
}

/** The changes held, which the server writes once each in ascending order. */
function readHeld(json: unknown): readonly HeldChange[] | null {
  if (!Array.isArray(json)) return null
  const labels: string[] = []
  for (const one of json as readonly unknown[]) {
    const label = text(one)
    const last = labels.at(-1)
    if (label === null || (last !== undefined && !(last < label))) return null
    labels.push(label)
  }
  const held = labels.map((label) => heldChanges.find((known) => known === label) ?? 'unrecognised')
  return [...new Set(held)]
}

function readMember(json: unknown): Member | null {
  if (!isRecord(json)) return null
  const userId = text(json.user_id)
  const identity = readIdentity(json.identity)
  const role = roles.find((known) => known === json.role) ?? null
  const held = readHeld(json.held)
  if (userId === null || identity === null || role === null || held === null || typeof json.status !== 'string') return null
  const status = statuses.find((known) => known === json.status) ?? 'unrecognised'
  return { userId, identity, role, status, held }
}

/** Every person, or null when any is not what the route promises. */
export function readMembers(json: unknown): readonly Member[] | null {
  if (!isRecord(json) || !Array.isArray(json.members)) return null
  const members = (json.members as readonly unknown[]).map(readMember)
  if (!members.every((one): one is Member => one !== null)) return null
  return new Set(members.map((one) => one.userId)).size === members.length ? members : null
}

export const list = (to: Send): Promise<Answer<readonly Member[]>> => get(to, membersPath, readMembers)
