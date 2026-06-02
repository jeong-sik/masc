// Decoded form of the [X-Workspace-Source] response header used by
// the repository / keeper-aware workspace routes. The encoding is mirrored in
// [Server_routes_http_routes_workspace.source_header] and lets
// the dashboard render a fallback notice when the requested repository
// or keeper resolved to project root.
export type WorkspaceSource =
  | { kind: 'project' }
  | { kind: 'repository'; repoId: string }
  | { kind: 'repository_missing'; repoId: string }
  | { kind: 'repository_unknown'; repoId: string }
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
  const value = header.slice(colon + 1)
  if (tag === 'repository') return { kind: 'repository', repoId: value }
  if (tag === 'repository_missing') return { kind: 'repository_missing', repoId: value }
  if (tag === 'repository_unknown') return { kind: 'repository_unknown', repoId: value }
  if (tag === 'playground') return { kind: 'playground', keeper: value }
  if (tag === 'playground_missing') return { kind: 'playground_missing', keeper: value }
  if (tag === 'keeper_unknown') return { kind: 'keeper_unknown', keeper: value }
  return { kind: 'project' }
}
