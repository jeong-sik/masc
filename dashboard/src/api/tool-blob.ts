/**
 * Client for the `/api/v1/artifacts/<sha256>` endpoint exposed by
 * `lib/server/server_routes_http_routes_artifacts.ml`.
 *
 * Used by tool-result-display when the operator clicks "Show full output"
 * on a sentinel marker payload. The endpoint returns the full bytes
 * inline — no streaming. Suitable for tool outputs up to a few MB.
 */

import { get } from './core'

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
 * the sha256 isn't in the store, 503 when the server's MASC_BASE_PATH
 * is unset). Callers should catch and render the error inline.
 */
export async function fetchToolBlob(
  sha256: string,
  opts: { signal?: AbortSignal; timeoutMs?: number } = {},
): Promise<ToolBlobResponse> {
  return get<ToolBlobResponse>(`/api/v1/artifacts/${encodeURIComponent(sha256)}`, opts)
}
