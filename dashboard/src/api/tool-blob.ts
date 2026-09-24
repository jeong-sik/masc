/**
 * Client for the `/api/v1/artifacts/<sha256>` endpoint exposed by
 * `lib/server/server_routes_http_routes_artifacts.ml`.
 *
 * Used by tool-result-display when the operator clicks "Show full output"
 * on a blob marker payload. The endpoint returns the full bytes
 * inline — no streaming. Suitable for tool outputs up to a few MB.
 */

import { ApiRequestError, authHeaders, fetchWithTimeout, get } from './core'
import { DEFAULT_GET_TIMEOUT_MS } from '../config/constants'

interface ToolBlobResponse {
  sha256: string
  bytes: number
  mime: string
  content: string
}

/**
 * Fetch the full bytes for a stored tool output.
 *
 * Throws `ApiRequestError` from `./core` on non-2xx responses (404 when
 * the sha256 isn't in the store, 503 when the stored artifact cannot be
 * read). Callers should catch and render the error inline.
 */
export async function fetchToolBlob(
  sha256: string,
  opts: { signal?: AbortSignal; timeoutMs?: number } = {},
): Promise<ToolBlobResponse> {
  return get<ToolBlobResponse>(`/api/v1/artifacts/${encodeURIComponent(sha256)}`, opts)
}

/** Retrieve exact bytes with an operator token. A plain link cannot carry
 * the Dashboard's Authorization header, and the JSON endpoint cannot safely
 * carry arbitrary binary media. */
export async function fetchToolBlobBytes(
  sha256: string,
  opts: { signal?: AbortSignal } = {},
): Promise<ArrayBuffer> {
  const path = `/api/v1/artifact-bytes/${encodeURIComponent(sha256)}`
  const response = await fetchWithTimeout(
    path,
    { headers: authHeaders(), signal: opts.signal },
    DEFAULT_GET_TIMEOUT_MS,
  )
  if (!response.ok) {
    throw new ApiRequestError({
      method: 'GET', path, status: response.status, statusText: response.statusText,
    })
  }
  return response.arrayBuffer()
}
