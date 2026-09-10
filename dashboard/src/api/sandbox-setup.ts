import { get } from './core'
import { isRecord } from '../lib/type-guards'

export const sandboxNames = { docker: 'Docker', apple_container: 'Apple Container', nerdctl_kata: 'Kata (nerdctl)', microsandbox: 'microsandbox', remote_ssh: 'Remote SSH' }
export type SandboxBackend = keyof typeof sandboxNames
export type NetworkMode = 'inherit' | 'none' | 'policy'
type State = 'service_ready' | 'missing_prerequisite' | 'unsupported_host' | 'unsupported_capability' | 'probe_failed' | 'needs_configuration'
export interface SandboxCandidate {
  id: SandboxBackend; state: State; reason: string; configured: boolean; recommended: boolean; advanced: boolean
  networkModes: NetworkMode[]
}
export interface SandboxCatalog {
  candidates: SandboxCandidate[]
  configured: { backend: SandboxBackend; network: NetworkMode } | null
  configurationError: string | null
}
const backend = (value: unknown): value is SandboxBackend => typeof value === 'string' && Object.hasOwn(sandboxNames, value)
const network = (value: unknown): value is NetworkMode => value === 'inherit' || value === 'none' || value === 'policy'
const states: State[] = ['service_ready', 'missing_prerequisite', 'unsupported_host', 'unsupported_capability', 'probe_failed', 'needs_configuration']
export async function fetchSandboxCatalog(): Promise<SandboxCatalog> {
  const data = await get<unknown>('/api/v1/setup/sandbox')
  if (!isRecord(data) || data.schema !== 'masc.sandbox_readiness.v1' || !Array.isArray(data.candidates)) throw new Error('Invalid sandbox catalog')
  const seen = new Set<string>()
  const candidates = data.candidates.map((row): SandboxCandidate => {
    if (!isRecord(row) || !backend(row.id) || seen.has(row.id) || !states.includes(row.state as State)
      || typeof row.reason !== 'string' || row.guest_verification !== 'not_run'
      || typeof row.configured !== 'boolean' || typeof row.recommended !== 'boolean' || typeof row.advanced !== 'boolean'
      || !isRecord(row.capabilities) || !Array.isArray(row.capabilities.network_modes)
      || !row.capabilities.network_modes.every(network)) throw new Error('Invalid sandbox candidate')
    seen.add(row.id)
    return { id: row.id, state: row.state as State, reason: row.reason, configured: row.configured,
      recommended: row.recommended, advanced: row.advanced, networkModes: row.capabilities.network_modes }
  })
  const selected = data.configured_selection
  if (selected !== null && (!isRecord(selected) || !backend(selected.backend) || !network(selected.network_mode))) throw new Error('Invalid sandbox selection')
  if (data.configuration_error !== null && typeof data.configuration_error !== 'string') throw new Error('Invalid sandbox declaration')
  return { candidates, configured: selected === null ? null : { backend: selected.backend as SandboxBackend, network: selected.network_mode as NetworkMode }, configurationError: data.configuration_error }
}
