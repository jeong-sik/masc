import { authHeaders, get } from './core'
import { ensureDevToken } from './dev-token'

export interface KeeperGithubAuthResult {
  authenticated: boolean
  login: string | null
  // The OAuth scopes GitHub listed for the token (X-OAuth-Scopes). null when
  // it listed none: a fine-grained PAT or an App token, or a failed probe.
  scopes: string[] | null
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

// The scopes a login may ask for beyond gh's minimum (repo, read:org, gist).
// The server's list is Keeper_github_identity.all_login_scopes; it refuses a
// name it does not offer with 400, so a scope missing here is only unoffered,
// and one added here that the server lacks fails loudly.
export type KeeperGithubLoginScope = 'workflow' | 'write:packages'

export const KEEPER_GITHUB_LOGIN_SCOPES: readonly {
  scope: KeeperGithubLoginScope
  note: string
}[] = [
  {
    scope: 'workflow',
    note: '.github/workflows 를 바꿀 수 있어요. workflow 는 저장소 secrets 로 돌아요.',
  },
  {
    scope: 'write:packages',
    note: 'GitHub Packages(ghcr.io 이미지 포함)에 올릴 수 있어요. read:packages 도 같이 받아요.',
  },
]

export function keeperGithubLoginPath(
  keeperName: string,
  hostname: string,
  scopes: readonly KeeperGithubLoginScope[],
): string {
  const params = new URLSearchParams({ hostname })
  if (scopes.length > 0) params.set('scopes', scopes.join(','))
  return `/api/v1/keepers/${encodeURIComponent(keeperName)}/github-login?${params.toString()}`
}

export async function streamKeeperGithubLogin(
  keeperName: string,
  hostname: string,
  scopes: readonly KeeperGithubLoginScope[],
  onEvent: (event: KeeperGithubLoginEvent) => void,
  signal: AbortSignal,
): Promise<void> {
  await ensureDevToken()
  const response = await fetch(keeperGithubLoginPath(keeperName, hostname, scopes), {
    method: 'POST',
    headers: authHeaders(),
    signal,
  })
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
