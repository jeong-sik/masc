import { Either, Schema } from 'effect'

const text = Schema.NonEmptyString.pipe(Schema.filter(value => value.trim().length > 0))
const id = Schema.Number.pipe(Schema.filter(value => Number.isSafeInteger(value) && value >= 0))
const spaceObservation = Schema.Struct({
  spaceId: id, spaceName: text, ownership: text,
  observedAt: Schema.Number.pipe(Schema.filter(Number.isFinite)),
})
const presenceCommon = { spaceId: id, observedAt: Schema.Number.pipe(Schema.filter(Number.isFinite)) }
const spacePresence = Schema.Union(
  Schema.Struct({ ...presenceCommon, state: Schema.Literal('present', 'missing') }),
  Schema.Struct({ ...presenceCommon, state: Schema.Literal('unknown'), reason: Schema.Union(
    Schema.Struct({ kind: Schema.Literal('transport_unavailable', 'invalid_inventory'), detail: Schema.String }),
    Schema.Struct({ kind: Schema.Literal('ambiguous_inventory') }),
  ) }),
)
const work = Schema.Struct({
  requestId: text, actor: Schema.NullOr(text), action: text, tabId: Schema.NullOr(id),
  phase: Schema.Literal('queued', 'running'),
})
const common = {
  clientId: text, browser: Schema.Literal('firefox', 'zen', 'ego_lite'),
  version: text, engineVersion: text,
  interactions: Schema.Array(work),
  lastActivities: Schema.Array(Schema.Struct({
    work, outcome: Schema.Literal('returned', 'refused', 'partial', 'unknown'),
  })),
}
const client = Schema.Union(
  Schema.Struct({ ...common, transport: Schema.Literal('ego_task_space'), space: Schema.Struct({ id, name: text }),
    spaceObservation: Schema.NullOr(spaceObservation),
    spacePresence: Schema.NullOr(spacePresence),
  }).pipe(Schema.filter(client => (client.spaceObservation === null || client.spaceObservation.spaceId === client.space.id)
    && (client.spacePresence === null || client.spacePresence.spaceId === client.space.id))),
  Schema.Struct({ ...common, transport: Schema.Literal('web_extension', 'webdriver_bidi'), space: Schema.Null,
    spaceObservation: Schema.Null, spacePresence: Schema.Null }),
)
const unavailable = Schema.Struct({
  backend: Schema.Literal('ego'), reason: Schema.Literal('user_owned_name'),
  space: Schema.NonEmptyString,
  ids: Schema.Array(Schema.Number.pipe(Schema.filter(value => Number.isInteger(value) && value > 0)))
    .pipe(Schema.filter(ids => new Set(ids).size === ids.length)),
  observedAt: Schema.Number.pipe(Schema.filter(value => Number.isFinite(value) && value >= 0)),
  recheck: Schema.Literal('take_over'),
})
const ownedBrowser = Schema.Struct({
  activity: Schema.Literal('enabled', 'disabled', 'unobserved'),
  registered: Schema.Boolean,
  session: Schema.Literal('closed', 'open', 'changing', 'unknown'),
  locate: Schema.Boolean,
})
const connections = Schema.Struct({
  state: Schema.Literal('serving', 'retired'),
  clients: Schema.Array(client).pipe(Schema.filter(clients => new Set(clients.map(item => item.clientId)).size === clients.length)),
  // Server-owned sessions are distinct from connected personal browsers.
  owned_backends: Schema.Struct({ automation: ownedBrowser }),
  unavailable: Schema.optional(Schema.Array(unavailable)),
})
export type BrowserConnection = Schema.Schema.Type<typeof client>
export type BrowserInteraction = Schema.Schema.Type<typeof work>
export type BrowserConnections =
  | { readonly kind: 'observed'; readonly value: Schema.Schema.Type<typeof connections> }
  | { readonly kind: 'unreadable' }

/** Mirrors Browser_lane.client_json / Browser_addon_owner.snapshot. Decode at
 * this display boundary without dropping the generic row or its raw evidence. */
export function parseBrowserConnections(value: unknown): BrowserConnections {
  const decoded = Schema.decodeUnknownEither(connections, { onExcessProperty: 'error' })(value)
  return Either.isRight(decoded) ? { kind: 'observed', value: decoded.right } : { kind: 'unreadable' }
}
