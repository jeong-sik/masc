import {
  defaultDashboardHttp,
  type DashboardHttpService,
  type DashboardTransportError,
} from './effect-http'
import {
  decodeGateKeepers,
  type GateKeepersData,
  type GateKeepersSchemaDriftError,
} from './schemas/gate-keepers'
import type { Result } from '../lib/result'

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

const GATE_KEEPERS_PATH = '/api/v1/gate/keepers?detailed=true'

export async function fetchGateKeepers(
  http: DashboardHttpService = defaultDashboardHttp,
  signal?: AbortSignal,
): Promise<Result<GateKeepersData, GateKeepersError>> {
  const raw = await http.getUnknown(GATE_KEEPERS_PATH, signal)
  if (!raw.ok) return raw
  return decodeGateKeepers(raw.value)
}
