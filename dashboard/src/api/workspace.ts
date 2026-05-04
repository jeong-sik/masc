import { get, type GetOptions } from './core'
import type { FileTreeNode } from '../components/ide/file-tree-store'

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

export interface WorkspaceFileResponse {
  readonly ok: boolean
  readonly content: string
  readonly language?: string
}

// --- API helpers ---

export interface WorkspaceApiOptions extends GetOptions {
  readonly keeper?: string
}

function keeperParam(keeper: string | undefined): string {
  return keeper ? `&keeper=${encodeURIComponent(keeper)}` : ''
}

export function fetchWorkspaceTree(
  depth: number,
  opts: WorkspaceApiOptions = {},
): Promise<ReadonlyArray<FileTreeNode>> {
  const keeper = keeperParam(opts.keeper)
  return get<ReadonlyArray<FileTreeNode>>(
    `/api/v1/workspace/tree?depth=${depth}${keeper}`,
    opts,
  )
}

export function fetchWorkspaceFile(
  path: string,
  opts: WorkspaceApiOptions = {},
): Promise<WorkspaceFileResponse | null> {
  const keeper = keeperParam(opts.keeper)
  return get<WorkspaceFileResponse | null>(
    `/api/v1/workspace/file?path=${encodeURIComponent(path)}${keeper}`,
    opts,
  )
}

export function fetchGitBlame(
  path: string,
  opts: WorkspaceApiOptions = {},
): Promise<ReadonlyArray<BlameBlock>> {
  const keeper = keeperParam(opts.keeper)
  return get<ReadonlyArray<BlameBlock>>(
    `/api/v1/git/blame?path=${encodeURIComponent(path)}${keeper}`,
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
  const keeper = keeperParam(opts.keeper)
  return get<GitDiffResponse>(
    `/api/v1/git/diff?path=${encodeURIComponent(path)}&base_ref=${encodeURIComponent(baseRef)}${keeper}`,
    opts,
  ).then(data => Array.isArray(data.unified) ? data.unified : [])
}
