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
} from './schemas/gate-keepers'
export {
  decodeGateKeepers,
  GateKeepersSchemaDriftError,
} from './schemas/gate-keepers'

export type GateKeepersError =
  | DashboardTransportError
  | GateKeepersSchemaDriftError

const GATE_KEEPERS_PATH = '/api/v1/gate/keepers?limit=50&detailed=true'

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
