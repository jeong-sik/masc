import { get, post } from './core'
import { ensureDevToken } from './dev-token'

/** A declared service and what it currently offers one Keeper. `tools`
 *  absent means never attached; an empty array means attached and offering
 *  nothing, which is a different thing to tell an operator. */
export type AttachedProvider =
  | { provider: string; provider_label: string; attached: boolean; tools?: string[] }
  | { provider: string; problem: string }

export function isAttachable(
  provider: AttachedProvider,
): provider is {
  provider: string
  provider_label: string
  attached: boolean
  tools?: string[]
} {
  return !('problem' in provider)
}

interface AttachedProvidersResponse {
  providers: AttachedProvider[]
}

/** One fetch for both questions. A list of services and a list of
 *  attachments cannot disagree if they arrive together. */
export async function fetchAttachedProviders(
  keeperName: string,
  signal?: AbortSignal,
): Promise<AttachedProvider[]> {
  await ensureDevToken()
  const answer = await get<AttachedProvidersResponse>(
    `/api/v1/keepers/oauth/attached-tools?keeper=${encodeURIComponent(keeperName)}`,
    { signal },
  )
  return answer.providers ?? []
}

/** Ask an attached service again what tools it has. An operator action
 *  rather than a timer: a stale catalog is visible and fixable, while a
 *  timer is a network call nobody asked for. */
export async function refreshIdentityTools(
  keeperName: string,
  providerId: string,
): Promise<void> {
  await ensureDevToken()
  await post(
    `/api/v1/keepers/${encodeURIComponent(keeperName)}/identity-refresh`,
    { provider: providerId },
  )
}

export interface IdentityLoginStarted {
  keeper: string
  provider: string
  provider_label: string
  authorize_url: string
  state: string
  registered_now: boolean
  expires_at: number
}

/** Begin attaching one Keeper to one provider. Answers with the URL the
 *  operator has to open; nothing is written to the Keeper until the browser
 *  comes back to the server's callback. */
export async function startIdentityLogin(
  keeperName: string,
  providerId: string,
): Promise<IdentityLoginStarted> {
  await ensureDevToken()
  return post<IdentityLoginStarted>(
    `/api/v1/keepers/${encodeURIComponent(keeperName)}/oauth-login`,
    { provider: providerId },
  )
}

export interface OwnAppRecorded {
  provider: string
  provider_label: string
  client_id: string
  /** Whether a secret is on file. Never the secret itself: the answer to
   *  "did that save" is a yes, not a credential travelling back through
   *  every log and proxy on the way. */
  has_client_secret: boolean
}

/** Record an app the operator made themselves.
 *
 *  For a provider whose authorization server registers no client for a
 *  stranger -- Slack, GitHub and Figma all publish one app per operator --
 *  this is the only road in. One per provider for the whole install, not per
 *  Keeper, which is why the path carries no Keeper name. */
export async function setIdentityClient(
  providerId: string,
  clientId: string,
  clientSecret: string,
): Promise<OwnAppRecorded> {
  await ensureDevToken()
  return post<OwnAppRecorded>('/api/v1/keepers/oauth/client', {
    provider: providerId,
    client_id: clientId,
    // Sent as given. An empty string is the operator saying this app has no
    // secret, and the server reads it that way.
    client_secret: clientSecret,
  })
}
