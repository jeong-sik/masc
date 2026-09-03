import { authHeaders, get } from './core'
import { ensureDevToken } from './dev-token'

export interface KeeperGithubAuthResult {
  authenticated: boolean
  login: string | null
  error: string | null
}

export interface KeeperGithubIdentityObservation {
  ok: true
  keeper: string
  hostname: string
  config_dir: string
  projected_token_env_names: string[]
  stored: KeeperGithubAuthResult
  effective: KeeperGithubAuthResult
  effective_probe_scope: 'host_process_credential_only' | 'endpoint_process_only'
  checked_at_unix: number
}

export type KeeperGithubLoginEvent =
  | { event: 'output'; stream: 'stdout' | 'stderr'; text: string }
  | { event: 'complete'; observation: KeeperGithubIdentityObservation }
  | { event: 'error'; message: string }

function identityPath(keeperName: string, hostname: string): string {
  return `/api/v1/keepers/${encodeURIComponent(keeperName)}/github-identity?hostname=${encodeURIComponent(hostname)}`
}

export async function fetchKeeperGithubIdentity(
  keeperName: string,
  hostname = 'github.com',
  signal?: AbortSignal,
): Promise<KeeperGithubIdentityObservation> {
  await ensureDevToken()
  return get<KeeperGithubIdentityObservation>(identityPath(keeperName, hostname), { signal })
}

function decodeSseFrame(rawFrame: string): { event: string; data: string } | null {
  let event = 'message'
  const data: string[] = []
  for (const line of rawFrame.split('\n')) {
    if (line.startsWith('event:')) event = line.slice('event:'.length).trim()
    if (line.startsWith('data:')) data.push(line.slice('data:'.length).trimStart())
  }
  return data.length === 0 ? null : { event, data: data.join('\n') }
}

export async function streamKeeperGithubLogin(
  keeperName: string,
  hostname: string,
  onEvent: (event: KeeperGithubLoginEvent) => void,
  signal: AbortSignal,
): Promise<void> {
  await ensureDevToken()
  const response = await fetch(
    `/api/v1/keepers/${encodeURIComponent(keeperName)}/github-login?hostname=${encodeURIComponent(hostname)}`,
    { method: 'POST', headers: authHeaders(), signal },
  )
  if (!response.ok) {
    throw new Error((await response.text()) || `GitHub login failed (${response.status})`)
  }
  if (!response.body) throw new Error('GitHub login stream is unavailable')

  const reader = response.body.getReader()
  const decoder = new TextDecoder()
  let buffer = ''
  while (true) {
    const { done, value } = await reader.read()
    buffer += decoder.decode(value, { stream: !done }).replace(/\r\n/g, '\n')
    let boundary = buffer.indexOf('\n\n')
    while (boundary >= 0) {
      const frame = decodeSseFrame(buffer.slice(0, boundary))
      buffer = buffer.slice(boundary + 2)
      if (frame) {
        const payload = JSON.parse(frame.data) as Record<string, unknown>
        if (frame.event === 'output') {
          onEvent({
            event: 'output',
            stream: payload.stream === 'stderr' ? 'stderr' : 'stdout',
            text: typeof payload.text === 'string' ? payload.text : '',
          })
        } else if (frame.event === 'complete') {
          onEvent({
            event: 'complete',
            observation: payload.observation as KeeperGithubIdentityObservation,
          })
        } else if (frame.event === 'error') {
          onEvent({
            event: 'error',
            message: typeof payload.message === 'string'
              ? payload.message
              : 'GitHub login failed',
          })
        }
      }
      boundary = buffer.indexOf('\n\n')
    }
    if (done) break
  }
}
