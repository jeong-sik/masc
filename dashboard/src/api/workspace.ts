import { get, getWithResponse, type GetOptions } from './core'
import type { FileTreeNode } from '../components/ide/file-tree-store'
import { parseWorkspaceSource, type WorkspaceSource } from './workspace-source'

export type { WorkspaceSource } from './workspace-source'

export interface WorkspaceTreeResult {
  readonly nodes: ReadonlyArray<FileTreeNode>
  readonly source: WorkspaceSource
  readonly basePath: string | null
}

// --- Blame ---

export interface BlameBlock {
  readonly file_path: string
  readonly line_start: number
  readonly line_end: number
  readonly keeper_id: string
  readonly timestamp_ms: number
  readonly kind: string
}

// --- Diff ---

export type DiffTone = 'context' | 'add' | 'delete'

export interface UnifiedDiffRow {
  readonly kind: DiffTone
  readonly oldLine: number | null
  readonly newLine: number | null
  readonly text: string
}

// --- Workspace File ---

export type WorkspaceFileResponse =
  | {
      readonly ok: true
      readonly content: string
      readonly language?: string
    }
  | {
      readonly ok: false
    }

// --- API helpers ---

export interface WorkspaceApiOptions extends GetOptions {
  readonly keeper?: string
  readonly repoId?: string | null
  readonly includeDiff?: boolean
}

function appendWorkspaceParams(params: URLSearchParams, opts: WorkspaceApiOptions): void {
  if (opts.repoId) params.set('repo_id', opts.repoId)
  if (opts.keeper) params.set('keeper', opts.keeper)
}

export async function fetchWorkspaceTree(
  depth: number,
  opts: WorkspaceApiOptions = {},
): Promise<WorkspaceTreeResult> {
  const params = new URLSearchParams()
  params.set('depth', String(depth))
  if (opts.includeDiff) params.set('diff', 'true')
  appendWorkspaceParams(params, opts)
  const { data, headers } = await getWithResponse<ReadonlyArray<FileTreeNode>>(
    `/api/v1/workspace/tree?${params.toString()}`,
    opts,
  )
  return {
    nodes: data,
    source: parseWorkspaceSource(headers.get('X-Workspace-Source')),
    basePath: headers.get('X-Workspace-Base-Path'),
  }
}

/**
 * Fetch the immediate children (one level) of a workspace directory for
 * lazy on-expand tree loading. Mirrors fetchWorkspaceTree's node shape but
 * returns only the given directory's direct entries; the server anchors each
 * node's path/parent/depth to the whole workspace tree so the client can merge
 * them into the existing flat node array. Path is validated server-side with
 * the same traversal/confidential/symlink guards as fetchWorkspaceFile.
 */
export function fetchWorkspaceChildren(
  path: string,
  opts: WorkspaceApiOptions = {},
): Promise<ReadonlyArray<FileTreeNode>> {
  const params = new URLSearchParams()
  params.set('path', path)
  appendWorkspaceParams(params, opts)
  return get<ReadonlyArray<FileTreeNode>>(
    `/api/v1/workspace/children?${params.toString()}`,
    opts,
  )
}

export function fetchWorkspaceFile(
  path: string,
  opts: WorkspaceApiOptions = {},
): Promise<WorkspaceFileResponse | null> {
  const params = new URLSearchParams()
  params.set('path', path)
  appendWorkspaceParams(params, opts)
  return get<WorkspaceFileResponse | null>(
    `/api/v1/workspace/file?${params.toString()}`,
    opts,
  )
}

export function fetchGitBlame(
  path: string,
  opts: WorkspaceApiOptions = {},
): Promise<ReadonlyArray<BlameBlock>> {
  const params = new URLSearchParams()
  params.set('path', path)
  appendWorkspaceParams(params, opts)
  return get<ReadonlyArray<BlameBlock>>(
    `/api/v1/git/blame?${params.toString()}`,
    opts,
  )
}

interface GitDiffResponse {
  readonly unified: ReadonlyArray<UnifiedDiffRow>
}

export function fetchGitDiff(
  path: string,
  opts: WorkspaceApiOptions & { baseRef?: string } = {},
): Promise<ReadonlyArray<UnifiedDiffRow>> {
  const baseRef = opts.baseRef ?? 'HEAD'
  const params = new URLSearchParams()
  params.set('path', path)
  params.set('base_ref', baseRef)
  appendWorkspaceParams(params, opts)
  return get<GitDiffResponse>(
    `/api/v1/git/diff?${params.toString()}`,
    opts,
  ).then(data => Array.isArray(data.unified) ? data.unified : [])
}
