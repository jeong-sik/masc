import { get, post } from './core'
import { ensureDevToken } from './dev-token'

/** A provider declared under `config/identity/`. A declaration the server
 *  could not read arrives as its own shape rather than being dropped: an
 *  operator looking for a provider has to see why it is not on offer. */
export type IdentityProvider =
  | { id: string; label: string }
  | { id: string; problem: string }

export function isConnectable(
  provider: IdentityProvider,
): provider is { id: string; label: string } {
  return 'label' in provider
}

interface IdentityProvidersResponse {
  providers: IdentityProvider[]
}

export async function fetchIdentityProviders(
  signal?: AbortSignal,
): Promise<IdentityProvider[]> {
  await ensureDevToken()
  const answer = await get<IdentityProvidersResponse>(
    '/api/v1/keepers/oauth/providers',
    { signal },
  )
  return answer.providers ?? []
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
