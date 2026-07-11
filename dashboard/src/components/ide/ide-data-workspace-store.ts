import { signal, effect, untracked } from '@preact/signals'
import {
  activeIdeFile,
  activeIdeFocus,
  activeIdeWorkspaceIdentity,
  clearIdeFileFocus,
  focusIdeFile,
  ideWorkspaceIdentityForSelection,
  sameIdeWorkspaceIdentity,
  synchronizeIdeWorkspaceIdentity,
} from './ide-state'
import { activeKeeperName } from '../../keeper-state'
import { route } from '../../router'
import { selectedTask } from '../goals/task-detail-selection'
import {
  discoverRepositories,
  fetchRepositoriesList,
  type Repository,
} from '../../api/repositories'
import { extractApiError } from '../../api/core'
import {
  fetchWorkspaceFile,
  fetchWorkspaceChildren,
  fetchGitBlame,
  fetchGitDiff,
  fetchWorkspaceTree,
  type UnifiedDiffRow,
  type WorkspaceSource,
} from '../../api/workspace'
import {
  createCodeDocumentStore,
  type CodeDocumentStore,
} from './code-document-store'
import { DEFAULT_LANGUAGE_ID } from './ide-language'
import {
  createKeeperLineOwnershipStore,
  type KeeperLineOwnershipStore,
} from './keeper-line-ownership-store'
import type { KeeperEditKind } from '../../../design-system/headless-core/keeper-line-ownership'
import {
  createFileTreeStore,
  type FileTreeStore,
} from './file-tree-store'
import {
  fetchIdeAnnotations,
  ideScopeFromKeeperLane,
  type IdeAnnotation,
} from '../../api/ide'
import { registerIdeWorkspaceRefresh } from '../../sse-store'
import { isAbortError } from '../../lib/async-state'
import { isDiffEditorView, viewFromRoute } from './ide-view-route'

export interface IdeDataWorkspaceStore {
  readonly documentStore: CodeDocumentStore
  readonly ownershipStore: KeeperLineOwnershipStore
  readonly fileTreeStore: FileTreeStore
  readonly workspaceIssues: () => ReadonlyArray<WorkspaceFetchIssue>
  readonly subscribeWorkspaceIssues: (listener: () => void) => () => void
  readonly diffRows: () => ReadonlyArray<UnifiedDiffRow>
  readonly subscribeDiffRows: (listener: () => void) => () => void
  readonly workspaceSource: () => WorkspaceSource
  readonly subscribeWorkspaceSource: (listener: () => void) => () => void
  readonly workspaceBasePath: () => string | null
  readonly subscribeWorkspaceBasePath: (listener: () => void) => () => void
  readonly repositories: () => ReadonlyArray<Repository>
  readonly activeRepositoryId: () => string | null
  readonly setActiveRepositoryId: (repoId: string | null) => void
  readonly subscribeActiveRepositoryId: (listener: () => void) => () => void
  readonly scanRepositories: () => Promise<ReadonlyArray<Repository>>
  readonly subscribeRepositories: (listener: () => void) => () => void
  readonly annotations: () => ReadonlyArray<IdeAnnotation>
  readonly subscribeAnnotations: (listener: () => void) => () => void
  /** Re-run the workspace fetches on demand — the annotation composer
   *  (#23471 FE-4) calls this after a successful create so the line
   *  chips / popover / Context Lens pick the new record up through the
   *  same read path keeper edits use. */
  readonly refresh: () => void
  readonly dispose: () => void
}

export interface WorkspaceTreeIdentity {
  readonly source: WorkspaceSource
  readonly basePath: string | null
}

export type WorkspaceFetchIssueKind =
  | 'repositories'
  | 'tree'
  | 'file'
  | 'regions'
  | 'blame'
  | 'diff'
  | 'annotations'

export interface WorkspaceFetchIssue {
  readonly kind: WorkspaceFetchIssueKind
  readonly message: string
  readonly file_path: string | null
  readonly keeper: string | null
  readonly repo_id: string | null
  readonly observed_at_ms: number
}

export interface WorkspaceFetchIssueContext {
  readonly filePath?: string | null
  readonly keeper?: string | null
  readonly repoId?: string | null
  readonly fallbackMessage?: string
  readonly nowMs?: number
}

type WorkspaceFetchIssueScope = Pick<WorkspaceFetchIssueContext, 'filePath' | 'keeper' | 'repoId'>

export function firstObservedChangedFilePath(
  nodes: ReadonlyArray<{
    readonly path: string
    readonly hasChildren: boolean
    readonly diff: string | null
  }>,
): string | null {
  return nodes.find(node =>
    !node.hasChildren
    && node.path.trim().length > 0
    && node.diff !== null
    && node.diff.trim().length > 0,
  )?.path ?? null
}

export function workspaceTreeHasFile(
  nodes: ReadonlyArray<{ readonly path: string; readonly hasChildren: boolean }>,
  filePath: string,
): boolean {
  return nodes.some(node => !node.hasChildren && node.path === filePath)
}

export function workspaceTreeIdentity(
  source: WorkspaceSource,
  basePath: string | null,
): WorkspaceTreeIdentity {
  return { source, basePath }
}

export function sameWorkspaceTreeIdentity(
  left: WorkspaceTreeIdentity | null,
  right: WorkspaceTreeIdentity,
): boolean {
  if (left === null) return false
  if (left.basePath !== right.basePath) return false
  const leftSource = left.source
  const rightSource = right.source
  if (leftSource.kind !== rightSource.kind) return false
  switch (leftSource.kind) {
    case 'project':
      return true
    case 'repository':
      return rightSource.kind === 'repository' && leftSource.repoId === rightSource.repoId
    case 'repository_missing':
      return rightSource.kind === 'repository_missing' && leftSource.repoId === rightSource.repoId
    case 'repository_unknown':
      return rightSource.kind === 'repository_unknown' && leftSource.repoId === rightSource.repoId
    case 'playground':
      return rightSource.kind === 'playground' && leftSource.keeper === rightSource.keeper
    case 'playground_missing':
      return rightSource.kind === 'playground_missing' && leftSource.keeper === rightSource.keeper
    case 'keeper_unknown':
      return rightSource.kind === 'keeper_unknown' && leftSource.keeper === rightSource.keeper
  }
}

export function workspaceFetchIssueFromError(
  kind: WorkspaceFetchIssueKind,
  error: unknown,
  context: WorkspaceFetchIssueContext = {},
): WorkspaceFetchIssue | null {
  if (isAbortError(error)) return null
  const summary = extractApiError(error, context.fallbackMessage ?? `${kind} fetch failed`)
  return {
    kind,
    message: summary.message,
    file_path: context.filePath ?? null,
    keeper: context.keeper ?? null,
    repo_id: context.repoId ?? null,
    observed_at_ms: context.nowMs ?? Date.now(),
  }
}

function sameWorkspaceIssueScope(
  left: WorkspaceFetchIssue,
  right: WorkspaceFetchIssue,
): boolean {
  return left.kind === right.kind
    && left.file_path === right.file_path
    && left.keeper === right.keeper
    && left.repo_id === right.repo_id
}

export function replaceWorkspaceFetchIssue(
  issues: ReadonlyArray<WorkspaceFetchIssue>,
  next: WorkspaceFetchIssue,
): ReadonlyArray<WorkspaceFetchIssue> {
  return [
    ...issues.filter(issue => !sameWorkspaceIssueScope(issue, next)),
    next,
  ]
}

export function clearWorkspaceFetchIssue(
  issues: ReadonlyArray<WorkspaceFetchIssue>,
  kind: WorkspaceFetchIssueKind,
  context: WorkspaceFetchIssueScope = {},
): ReadonlyArray<WorkspaceFetchIssue> {
  const issueToClear: WorkspaceFetchIssue = {
    kind,
    message: '',
    file_path: context.filePath ?? null,
    keeper: context.keeper ?? null,
    repo_id: context.repoId ?? null,
    observed_at_ms: 0,
  }
  return issues.filter(issue => !sameWorkspaceIssueScope(issue, issueToClear))
}

export function retainCurrentWorkspaceFetchIssues(
  issues: ReadonlyArray<WorkspaceFetchIssue>,
  context: WorkspaceFetchIssueContext,
): ReadonlyArray<WorkspaceFetchIssue> {
  const currentFilePath = context.filePath ?? null
  const currentKeeper = context.keeper ?? null
  const currentRepoId = context.repoId ?? null
  return issues.filter(issue => {
    if (issue.kind === 'repositories') return true
    if (issue.keeper !== currentKeeper || issue.repo_id !== currentRepoId) return false
    return issue.file_path === null || issue.file_path === currentFilePath
  })
}

function isManagedMirrorRepository(repository: Repository): boolean {
  const localPath = repository.local_path.replace(/\\/g, '/')
  return localPath === `.masc/repos/${repository.id}`
    || localPath.startsWith('.masc/repos/')
    || localPath.includes('/.masc/repos/')
}

// Reviewer #13232: detect Windows drive-letter absolute paths
// (e.g. "C:/Users/.../repo" or "D:\\projects\\repo") after
// backslash normalization so workspace repos on Windows are not
// classified as managed mirrors and dropped from IDE default
// selection.  Posix absolute paths still match via the
// leading-slash branch.
const WINDOWS_DRIVE_LETTER_PREFIX = /^[A-Za-z]:\//
function isWorkspaceRepository(repository: Repository): boolean {
  const localPath = repository.local_path.replace(/\\/g, '/')
  const isAbsolute =
    localPath.startsWith('/') ||
    WINDOWS_DRIVE_LETTER_PREFIX.test(localPath)
  return isAbsolute && !localPath.includes('/.masc/')
}

/** Repo is not reachable — server reported it as missing or unknown. */
const UNREACHABLE_WORKSPACE_SOURCES: ReadonlySet<string> = new Set([
  'repository_missing',
  'repository_unknown',
])

export function selectPreferredIdeRepositoryId(
  repositories: ReadonlyArray<Repository>,
  current: string | null,
  excludeIds?: ReadonlySet<string>,
): string | null {
  if (current && !excludeIds?.has(current) && repositories.some(repository => repository.id === current)) {
    return current
  }

  const candidates = excludeIds && excludeIds.size > 0
    ? repositories.filter(r => !excludeIds.has(r.id))
    : repositories

  return candidates.find(isWorkspaceRepository)?.id
    ?? candidates.find(repository => !isManagedMirrorRepository(repository))?.id
    ?? candidates[0]?.id
    ?? null
}

export function createIdeDataWorkspaceStore(): IdeDataWorkspaceStore {
  const documentStore = createCodeDocumentStore({
    file_path: activeIdeFile.value,
    language: DEFAULT_LANGUAGE_ID,
    content: '',
  })
  const ownershipStore = createKeeperLineOwnershipStore(activeIdeFile.value)

  const diffRowsSignal = signal<ReadonlyArray<UnifiedDiffRow>>([])
  const workspaceIssuesSignal = signal<ReadonlyArray<WorkspaceFetchIssue>>([])
  const workspaceSourceSignal = signal<WorkspaceSource>({ kind: 'project' })
  const workspaceBasePathSignal = signal<string | null>(null)
  const repositoriesSignal = signal<ReadonlyArray<Repository>>([])
  const activeRepositoryIdSignal = signal<string | null>(null)
  const annotationsSignal = signal<ReadonlyArray<IdeAnnotation>>([])
  const currentWorkspaceIssues = (): ReadonlyArray<WorkspaceFetchIssue> =>
    workspaceIssuesSignal.peek()
  const clearIssue = (
    kind: WorkspaceFetchIssueKind,
    context: WorkspaceFetchIssueScope = {},
  ): void => {
    workspaceIssuesSignal.value = clearWorkspaceFetchIssue(
      currentWorkspaceIssues(),
      kind,
      context,
    )
  }
  const recordIssue = (
    kind: WorkspaceFetchIssueKind,
    error: unknown,
    context: WorkspaceFetchIssueContext = {},
  ): void => {
    const issue = workspaceFetchIssueFromError(kind, error, context)
    if (issue) {
      workspaceIssuesSignal.value = replaceWorkspaceFetchIssue(currentWorkspaceIssues(), issue)
    }
  }

  // Lazy tree: expanding a directory fetches its immediate children on demand.
  // The loader reads the current keeper/repo at call time (not capture time),
  // so it stays correct across repo/keeper switches. Diff badges are omitted on
  // lazily-loaded nodes (server does not compute them per-subtree); they refresh
  // on the next full tree load.
  const fileTreeStore = createFileTreeStore({
    loadChildren: (path: string) =>
      fetchWorkspaceChildren(path, {
        keeper: activeKeeperName.value || undefined,
        repoId: activeRepositoryIdSignal.value,
      }),
  })

  /** Track repo IDs that returned unreachable workspace sources, to avoid re-selecting them. */
  const unreachableRepoIds = new Set<string>()

  let abortController = new AbortController()
  // Identity of the workspace source the file tree was last seeded for.
  // A matching identity means the next fetch is a live refresh of the same
  // workspace, so the tree is reconciled (expansion + lazily-loaded children
  // preserved) rather than re-seeded. Include the source payload and basePath
  // so keeper/repo/fallback switches cannot retain stale lazy children.
  let lastTreeIdentity: WorkspaceTreeIdentity | null = null

  const applyRepositories = (repositories: ReadonlyArray<Repository>): void => {
    const current = activeRepositoryIdSignal.value
    repositoriesSignal.value = repositories
    activeRepositoryIdSignal.value = selectPreferredIdeRepositoryId(repositories, current, unreachableRepoIds)
  }

  const refreshRepositories = async (): Promise<ReadonlyArray<Repository>> => {
    try {
      const repositories = await fetchRepositoriesList()
      clearIssue('repositories')
      applyRepositories(repositories)
      return repositories
    } catch (error) {
      recordIssue('repositories', error, {
        fallbackMessage: 'repository list fetch failed',
      })
      throw error
    }
  }

  const scanRepositories = async (): Promise<ReadonlyArray<Repository>> => {
    const registered = await discoverRepositories()
    await refreshRepositories()
    return registered
  }

  refreshRepositories()
    .catch(error => {
      recordIssue('repositories', error, {
        fallbackMessage: 'repository list fetch failed',
      })
      repositoriesSignal.value = []
    })

  // Fetch the workspace snapshot for the current file/keeper/repo/task.
  //
  // Called two ways: reactively via the effect() below (on navigation-signal
  // changes) and imperatively via the live SSE refresh (when a keeper edits
  // files — see registerIdeWorkspaceRefresh). Both share `abortController`, so
  // the latest call always wins and a live refresh cannot race a navigation
  // refresh to stale data. The fetches are idempotent (server is SSOT), so a
  // coalesced live+nav refresh is safe.
  const runWorkspaceFetches = (): void => {
    const focus = activeIdeFocus.value
    const keeper = activeKeeperName.value
    const repoId = activeRepositoryIdSignal.value
    const task = selectedTask.value
    const workspaceIdentity = ideWorkspaceIdentityForSelection(repoId, keeper)
    const workspaceIdentityChanged = !sameIdeWorkspaceIdentity(
      activeIdeWorkspaceIdentity.peek(),
      workspaceIdentity,
    )

    // Cancel every request owned by the previous focus/workspace before any
    // state transition can synchronously re-run this effect.
    abortController.abort()
    abortController = new AbortController()
    const { signal } = abortController

    const invalidateWorkspaceDocument = (): void => {
      documentStore.invalidate()
      ownershipStore.reset(null)
      diffRowsSignal.value = []
      annotationsSignal.value = []
    }

    const focusWorkspaceChanged = focus !== null
      && !sameIdeWorkspaceIdentity(focus.workspace_identity, workspaceIdentity)
    if (workspaceIdentityChanged || focusWorkspaceChanged) {
      invalidateWorkspaceDocument()
    }
    if (workspaceIdentityChanged) {
      fileTreeStore.seed([])
      synchronizeIdeWorkspaceIdentity(workspaceIdentity)
    }

    if (focusWorkspaceChanged) {
      if (focus.origin === 'observed_change') {
        clearIdeFileFocus()
      } else {
        focusIdeFile({
          path: focus.path,
          origin: focus.origin,
          workspace_identity: workspaceIdentity,
          availability: 'pending',
        })
      }
      return
    }

    const requestedFilePath = focus?.path ?? null
    const filePath = focus?.availability === 'available' ? focus.path : null
    const loadedFilePath = untracked(() => documentStore.document().file_path)
    if (loadedFilePath !== null && loadedFilePath !== filePath) {
      invalidateWorkspaceDocument()
    }

    ownershipStore.reset(filePath)

    const keeperParam = keeper || undefined
    const opts = { keeper: keeperParam, repoId, signal, includeDiff: true }
    // IDE observation routes require one explicit scope. Repository scope is
    // authoritative when configured; otherwise a selected keeper can read its
    // own orphan observation lane without fabricating a repository identity.
    const ideOpts = repoId
      ? { keeper: keeperParam, repoId, signal }
      : {
          keeper: keeperParam,
          repoId,
          scope: ideScopeFromKeeperLane(keeperParam),
          signal,
        }
    workspaceIssuesSignal.value = retainCurrentWorkspaceFetchIssues(currentWorkspaceIssues(), {
      filePath: requestedFilePath,
      keeper: keeperParam ?? null,
      repoId,
    })

    // Load the file tree independently of the active file. When no explicit
    // operator/route focus exists, the server-ordered changed-file observation
    // is the only automatic focus contract. Do not infer focus from dot-path
    // visibility, keeper ownership, or an arbitrary tree leaf.
    fetchWorkspaceTree(2, opts).then(({ nodes, source, basePath }) => {
      if (signal.aborted) return
      clearIssue('tree', { keeper: keeperParam ?? null, repoId })
      // Same source + base path ⇒ live refresh: keep the operator's expansion
      // and any lazily-loaded children. A change ⇒ workspace switch: reset.
      const treeIdentity = workspaceTreeIdentity(source, basePath)
      if (sameWorkspaceTreeIdentity(lastTreeIdentity, treeIdentity)) {
        fileTreeStore.reconcile(nodes)
      } else {
        fileTreeStore.seed(nodes)
      }
      lastTreeIdentity = treeIdentity
      workspaceSourceSignal.value = source
      workspaceBasePathSignal.value = basePath

      // Self-healing: if the selected repo is unreachable (missing .git,
      // path does not exist, etc.), exclude it and auto-switch to the next
      // preferred repo so the IDE does not land on a blank screen.
      if (repoId && UNREACHABLE_WORKSPACE_SOURCES.has(source.kind)) {
        unreachableRepoIds.add(repoId)
        const repos = repositoriesSignal.value
        const nextId = selectPreferredIdeRepositoryId(repos, null, unreachableRepoIds)
        if (nextId && nextId !== repoId) {
          activeRepositoryIdSignal.value = nextId
          return  // effect will re-fire with the new repoId
        }
      }

      const currentFocus = activeIdeFocus.peek()
      if (currentFocus?.availability === 'pending') {
        if (!sameIdeWorkspaceIdentity(currentFocus.workspace_identity, workspaceIdentity)) return
        if (workspaceTreeHasFile(nodes, currentFocus.path)) {
          focusIdeFile({
            ...currentFocus,
            availability: 'available',
          })
          return
        }
        const pendingFocus = currentFocus
        fetchWorkspaceFile(pendingFocus.path, opts).then(response => {
          if (signal.aborted || activeIdeFocus.peek() !== pendingFocus) return
          if (response?.ok === true && typeof response.content === 'string') {
            const loaded = documentStore.load({
              file_path: pendingFocus.path,
              language: response.language ?? DEFAULT_LANGUAGE_ID,
              content: response.content,
            })
            if (!loaded) {
              documentStore.invalidate()
              focusIdeFile({
                ...pendingFocus,
                availability: 'unavailable',
              })
              recordIssue('file', new Error('explicit IDE focus response was malformed'), {
                filePath: pendingFocus.path,
                keeper: keeperParam ?? null,
                repoId,
                fallbackMessage: 'explicit IDE focus validation failed',
              })
              return
            }
            clearIssue('file', {
              filePath: pendingFocus.path,
              keeper: keeperParam ?? null,
              repoId,
            })
            focusIdeFile({
              ...pendingFocus,
              availability: 'available',
            })
            return
          }
          documentStore.invalidate()
          if (response?.ok === false) {
            focusIdeFile({
              ...pendingFocus,
              availability: 'not_found',
            })
            recordIssue(
              'file',
              new Error(`explicit IDE focus not found in selected workspace: ${pendingFocus.path}`),
              {
                filePath: pendingFocus.path,
                keeper: keeperParam ?? null,
                repoId,
              },
            )
            return
          }
          focusIdeFile({
            ...pendingFocus,
            availability: 'unavailable',
          })
          recordIssue('file', new Error('explicit IDE focus response was unavailable'), {
            filePath: pendingFocus.path,
            keeper: keeperParam ?? null,
            repoId,
            fallbackMessage: 'explicit IDE focus validation failed',
          })
        }).catch(error => {
          if (signal.aborted || activeIdeFocus.peek() !== pendingFocus) return
          documentStore.invalidate()
          focusIdeFile({
            ...pendingFocus,
            availability: 'unavailable',
          })
          recordIssue('file', error, {
            filePath: pendingFocus.path,
            keeper: keeperParam ?? null,
            repoId,
            fallbackMessage: 'explicit IDE focus validation failed',
          })
        })
        return
      }

      if (currentFocus === null) {
        const nextFile = firstObservedChangedFilePath(nodes)
        if (nextFile) {
          focusIdeFile({
            path: nextFile,
            origin: 'observed_change',
            workspace_identity: workspaceIdentity,
            availability: 'available',
          })
        }
      }
    }).catch(error => {
      if (signal.aborted) return
      const pendingFocus = activeIdeFocus.peek()
      if (
        pendingFocus?.availability === 'pending'
        && sameIdeWorkspaceIdentity(pendingFocus.workspace_identity, workspaceIdentity)
      ) {
        documentStore.invalidate()
        focusIdeFile({
          ...pendingFocus,
          availability: 'unavailable',
        })
      }
      recordIssue('tree', error, {
        keeper: keeperParam ?? null,
        repoId,
        fallbackMessage: 'workspace tree fetch failed',
      })
    })

    // File-scoped fetches require an active file path; skip when none is selected.
    if (filePath === null) {
      diffRowsSignal.value = []
      annotationsSignal.value = []
      if (requestedFilePath === null) {
        workspaceIssuesSignal.value = currentWorkspaceIssues().filter(issue => issue.file_path === null)
      }
      return
    }

    // Load file content
    fetchWorkspaceFile(filePath, opts).then(response => {
      if (signal.aborted) return
      if (response?.ok === true && typeof response.content === 'string') {
        const loaded = documentStore.load({
          file_path: filePath,
          language: response.language ?? DEFAULT_LANGUAGE_ID,
          content: response.content,
        })
        if (!loaded) {
          documentStore.invalidate()
          const currentFocus = activeIdeFocus.peek()
          if (currentFocus?.path === filePath && currentFocus.availability === 'available') {
            focusIdeFile({
              ...currentFocus,
              availability: 'unavailable',
            })
          }
          recordIssue('file', new Error('workspace file response was malformed'), {
            filePath,
            keeper: keeperParam ?? null,
            repoId,
            fallbackMessage: 'workspace file fetch failed',
          })
          return
        }
        clearIssue('file', { filePath, keeper: keeperParam ?? null, repoId })

        // The document load invalidates metadata for a different file. Start
        // the region read only after that load has committed; doing both in
        // parallel let a slower file response mark a valid region response as
        // stale before it could populate the ownership projection.
        documentStore.loadRegions(filePath, ideOpts).then(() => {
          if (signal.aborted || documentStore.document().file_path !== filePath) return
          for (const region of documentStore.regions()) {
            ownershipStore.ingest({
              file_path: region.file_path,
              line_start: region.line_start,
              line_end: region.line_end,
              keeper_id: region.keeper_id,
              timestamp_ms: region.timestamp_ms,
              // Regions prove that a keeper operated on this code range, but the
              // wire contract deliberately does not infer a more specific edit
              // operation such as create/refactor/revert.
              kind: 'observed',
            })
          }
          clearIssue('regions', { filePath, keeper: keeperParam ?? null, repoId })
        }).catch(error => {
          if (signal.aborted) return
          recordIssue('regions', error, {
            filePath,
            keeper: keeperParam ?? null,
            repoId,
            fallbackMessage: 'IDE regions fetch failed',
          })
        })
      } else {
        documentStore.invalidate()
        const currentFocus = activeIdeFocus.peek()
        if (currentFocus?.path === filePath) {
          if (response?.ok === false && currentFocus.origin !== 'observed_change') {
            focusIdeFile({
              ...currentFocus,
              availability: 'not_found',
            })
          } else {
            focusIdeFile({
              ...currentFocus,
              availability: 'unavailable',
            })
          }
        }
        const responseError = response?.ok === false
          ? new Error('workspace file response reported that the file was not found')
          : new Error('workspace file response was unavailable or malformed')
        recordIssue('file', responseError, {
          filePath,
          keeper: keeperParam ?? null,
          repoId,
          fallbackMessage: 'workspace file fetch failed',
        })
      }
    }).catch(error => {
      if (signal.aborted) return
      documentStore.invalidate()
      const currentFocus = activeIdeFocus.peek()
      if (currentFocus?.path === filePath && currentFocus.availability === 'available') {
        focusIdeFile({
          ...currentFocus,
          availability: 'unavailable',
        })
      }
      recordIssue('file', error, {
        filePath,
        keeper: keeperParam ?? null,
        repoId,
        fallbackMessage: 'workspace file fetch failed',
      })
    })

    // Load blame & diff conditionally on view tab to prevent over-fetching.
    // Use the same route normalization as IdeShell so legacy aliases such as
    // "merge" do not silently suppress the diff fetch.
    const currentView = viewFromRoute(route.value.params.view)
    const isBlameView = currentView === 'blame'
    const isDiffView = isDiffEditorView(currentView)

    if (isBlameView) {
      fetchGitBlame(filePath, opts).then(blocks => {
        if (signal.aborted) return
        clearIssue('blame', { filePath, keeper: keeperParam ?? null, repoId })
        for (const block of blocks) {
          ownershipStore.ingest({
            file_path: block.file_path,
            line_start: block.line_start,
            line_end: block.line_end,
            keeper_id: block.keeper_id,
            timestamp_ms: block.timestamp_ms,
            kind: block.kind as KeeperEditKind,
          })
        }
      }).catch(error => {
        if (signal.aborted) return
        recordIssue('blame', error, {
          filePath,
          keeper: keeperParam ?? null,
          repoId,
          fallbackMessage: 'git blame fetch failed',
        })
      })
    }

    if (isDiffView) {
      fetchGitDiff(filePath, { ...opts, baseRef: 'HEAD' }).then(rows => {
        if (signal.aborted) return
        clearIssue('diff', { filePath, keeper: keeperParam ?? null, repoId })
        diffRowsSignal.value = rows
      }).catch(error => {
        if (signal.aborted) return
        recordIssue('diff', error, {
          filePath,
          keeper: keeperParam ?? null,
          repoId,
          fallbackMessage: 'git diff fetch failed',
        })
      })
    } else {
      diffRowsSignal.value = []
    }

    // Load annotations
    fetchIdeAnnotations({ file_path: filePath, goal_id: task?.goal_id ?? undefined, task_id: task?.id ?? undefined }, ideOpts).then(annotations => {
      if (signal.aborted) return
      clearIssue('annotations', { filePath, keeper: keeperParam ?? null, repoId })
      annotationsSignal.value = annotations
    }).catch(error => {
      if (signal.aborted) return
      recordIssue('annotations', error, {
        filePath,
        keeper: keeperParam ?? null,
        repoId,
        fallbackMessage: 'IDE annotations fetch failed',
      })
    })
  }

  // Re-run fetches on navigation-signal changes. Reading the signals
  // synchronously inside runWorkspaceFetches registers them as effect
  // dependencies (activeIdeFile, activeKeeperName, activeRepositoryId,
  // selectedTask), so the effect re-fires exactly when they change.
  const disposeEffect = effect(() => {
    runWorkspaceFetches()
  })

  // Live updates: refresh the workspace snapshot when a keeper edits files or
  // completes a turn. The sse-store dispatch is debounced and scoped to the
  // code surface, so this does not fetch while the user is on another tab.
  const unregisterLiveRefresh = registerIdeWorkspaceRefresh(runWorkspaceFetches)

  return {
    documentStore,
    ownershipStore,
    fileTreeStore,
    workspaceIssues: () => workspaceIssuesSignal.value,
    subscribeWorkspaceIssues: (listener: () => void) =>
      workspaceIssuesSignal.subscribe(listener),
    diffRows: () => diffRowsSignal.value,
    subscribeDiffRows: (listener: () => void) =>
      diffRowsSignal.subscribe(listener),
    workspaceSource: () => workspaceSourceSignal.value,
    // Wrap [Signal.subscribe] in an arrow so [this] stays bound when
    // the property is destructured by callers (the [as (listener: () =>
    // void) => () => void] cast on a method reference loses [this] and
    // crashes with "Cannot read properties of undefined" inside the
    // signal core's internal tracking).
    subscribeWorkspaceSource: (listener: () => void) =>
      workspaceSourceSignal.subscribe(listener),
    workspaceBasePath: () => workspaceBasePathSignal.value,
    subscribeWorkspaceBasePath: (listener: () => void) =>
      workspaceBasePathSignal.subscribe(listener),
    repositories: () => repositoriesSignal.value,
    activeRepositoryId: () => activeRepositoryIdSignal.value,
    setActiveRepositoryId: (repoId: string | null) => {
      activeRepositoryIdSignal.value = repoId
    },
    subscribeActiveRepositoryId: (listener: () => void) =>
      activeRepositoryIdSignal.subscribe(listener),
    scanRepositories,
    subscribeRepositories: (listener: () => void) =>
      repositoriesSignal.subscribe(listener),
    annotations: () => annotationsSignal.value,
    subscribeAnnotations: (listener: () => void) =>
      annotationsSignal.subscribe(listener),
    refresh: () => {
      runWorkspaceFetches()
    },
    dispose: () => {
      abortController.abort()
      unregisterLiveRefresh()
      disposeEffect()
      ownershipStore.dispose()
    },
  }
}
