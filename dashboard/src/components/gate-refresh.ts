import { fetchDashboardGate } from '../api/dashboard-gate'
import { registerGateRefresh } from '../sse-store'
import {
  gateResource,
  gateError,
} from './gate-signals'

export async function refreshGate(opts?: { force?: boolean }) {
  gateError.value = ''
  await gateResource.load(signal => fetchDashboardGate({ force: opts?.force, signal }))
  const s = gateResource.state.value
  if (s.error) {
    gateError.value = s.error
  }
}

registerGateRefresh(refreshGate)
