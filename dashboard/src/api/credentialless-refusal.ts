import { isRecord } from '../lib/type-guards'

/* A request that carries no credential and is answered 401 `missing_token`
   names a route that needs a credential. The same request without one gets
   the same answer until a credential is stored, so a page that keeps polling
   without one (a remote tab after its token was cleared) only resends a
   refusal. The answer is kept per route and per stored-token revision, and a
   request with no credential to that route is answered from it. Storing or
   clearing a token moves the revision, and a reload empties the table, so
   either one sends again. A route the server opens to callers without a
   credential is never refused, so it is never answered from here.

   The key leaves out the X-MASC-Agent name: with no bearer the server finds
   no credential whatever name is sent, so the answer does not change with
   it. A replayed refusal starts no recovery, the same as the one the server
   sent: the rejected-credential listener only hears 401s that carried a
   token. */

/** One request sent without a credential, as the table keys it. */
export interface CredentiallessRequest {
  route: string
  tokenRevision: number
}

interface StoredRefusal {
  tokenRevision: number
  status: number
  statusText: string
  headers: [string, string][]
  body: string
}

const refusals = new Map<string, StoredRefusal>()

export function credentiallessRequest(
  method: string | undefined,
  path: string,
  tokenRevision: number,
): CredentiallessRequest {
  const { pathname } = new URL(path, window.location.href)
  return { route: `${(method ?? 'GET').toUpperCase()} ${pathname}`, tokenRevision }
}

/** The server's refusal of this route while no credential has been stored since. */
export function replayedRefusal(request: CredentiallessRequest): Response | null {
  const stored = refusals.get(request.route)
  if (stored === undefined) return null
  if (stored.tokenRevision !== request.tokenRevision) {
    refusals.delete(request.route)
    return null
  }
  return new Response(stored.body, {
    status: stored.status,
    statusText: stored.statusText,
    headers: stored.headers,
  })
}

function isMissingTokenBody(body: string): boolean {
  try {
    const parsed: unknown = JSON.parse(body)
    return isRecord(parsed) && parsed.auth_error_code === 'missing_token'
  } catch {
    return false
  }
}

/** Keep a 401 answered to [request] when its typed code says no credential was sent. */
export async function noteRefusal(request: CredentiallessRequest, response: Response, signal?: AbortSignal): Promise<void> {
  if (signal?.aborted || response.status !== 401) return
  const body = await response.text()
  if (signal?.aborted || !isMissingTokenBody(body)) return
  refusals.set(request.route, {
    tokenRevision: request.tokenRevision,
    status: response.status,
    statusText: response.statusText,
    headers: [...response.headers.entries()],
    body,
  })
}
