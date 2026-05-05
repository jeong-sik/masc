// Decoded form of the [X-Workspace-Source] response header used by
// the keeper-aware workspace routes. The encoding is mirrored in
// [Server_routes_http_routes_workspace.source_header] and lets
// the dashboard render a fallback notice when the requested keeper
// resolved to project root (missing playground dir or unknown
// keeper meta).
export type WorkspaceSource =
  | { kind: 'project' }
  | { kind: 'playground'; keeper: string }
  | { kind: 'playground_missing'; keeper: string }
  | { kind: 'keeper_unknown'; keeper: string }

// Decode the [X-Workspace-Source] header value. Unknown / null /
// empty / malformed inputs collapse to [{ kind: 'project' }] so
// callers never need to handle a "header missing" branch.
export function parseWorkspaceSource(header: string | null): WorkspaceSource {
  if (!header) return { kind: 'project' }
  if (header === 'project') return { kind: 'project' }
  const colon = header.indexOf(':')
  if (colon === -1) return { kind: 'project' }
  const tag = header.slice(0, colon)
  const keeper = header.slice(colon + 1)
  if (tag === 'playground') return { kind: 'playground', keeper }
  if (tag === 'playground_missing') return { kind: 'playground_missing', keeper }
  if (tag === 'keeper_unknown') return { kind: 'keeper_unknown', keeper }
  return { kind: 'project' }
}
