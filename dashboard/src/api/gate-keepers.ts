import { Effect } from 'effect'

import {
  DashboardHttp,
  type DashboardTransportError,
} from './effect-http'
import {
  decodeGateKeepers,
  type GateKeepersData,
  type GateKeepersSchemaDriftError,
} from './schemas/gate-keepers'

export type {
  GateKeeper,
  GateKeeperDirectoryIssue,
  GateKeepersData,
  KeeperListing,
} from './schemas/gate-keepers'
export {
  decodeGateKeepers,
  GateKeepersSchemaDriftError,
} from './schemas/gate-keepers'

export type GateKeepersError =
  | DashboardTransportError
  | GateKeepersSchemaDriftError

// No limit parameter: the route clamps to its own bound and reports `total` /
// `truncated`, so asking for a number here only re-introduces a second cap the
// UI would have to keep in sync. masc#29077 — the hardcoded 50 hid 79 of 129
// keepers, including every keeper that had a live channel binding.
const GATE_KEEPERS_PATH = '/api/v1/gate/keepers?detailed=true'

export function fetchGateKeepers(): Effect.Effect<
  GateKeepersData,
  GateKeepersError,
  DashboardHttp
> {
  return Effect.gen(function*() {
    const http = yield* DashboardHttp
    const raw = yield* http.getUnknown(GATE_KEEPERS_PATH)
    return yield* decodeGateKeepers(raw)
  })
}
