import { signal, effect } from '@preact/signals'
import { activeIdeFile } from './ide-state'
import { activeKeeperName } from '../../keeper-state'
import { selectedTask } from '../goals/task-detail-selection'
import {
  discoverRepositories,
  fetchRepositoriesList,
  type Repository,
} from '../../api/repositories'
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
  type IdeAnnotation,
} from '../../api/ide'
import { registerIdeWorkspaceRefresh } from '../../sse-store'

export interface IdeDataWorkspaceStore {
  readonly documentStore: CodeDocumentStore
  readonly ownershipStore: KeeperLineOwnershipStore
  readonly fileTreeStore: FileTreeStore
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
  readonly dispose: () => void
}

function firstFilePath(nodes: ReadonlyArray<{ readonly path: string; readonly hasChildren: boolean }>): string | null {
  const firstFile = nodes.find(node => !node.hasChildren)
  return firstFile?.path ?? null
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
  const workspaceSourceSignal = signal<WorkspaceSource>({ kind: 'project' })
  const workspaceBasePathSignal = signal<string | null>(null)
  const repositoriesSignal = signal<ReadonlyArray<Repository>>([])
  const activeRepositoryIdSignal = signal<string | null>(null)
  const annotationsSignal = signal<ReadonlyArray<IdeAnnotation>>([])

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
  // Identity (repo + workspace source kind) the file tree was last seeded for.
  // A matching identity means the next fetch is a live refresh of the same
  // workspace, so the tree is reconciled (expansion + lazily-loaded children
  // preserved) rather than re-seeded (which would collapse it on every keeper
  // edit). `undefined` until the first successful fetch forces an initial seed.
  let lastTreeIdentity: string | undefined = undefined

  const applyRepositories = (repositories: ReadonlyArray<Repository>): void => {
    const current = activeRepositoryIdSignal.value
    activeRepositoryIdSignal.value = selectPreferredIdeRepositoryId(repositories, current, unreachableRepoIds)
    repositoriesSignal.value = repositories
  }

  const refreshRepositories = async (): Promise<ReadonlyArray<Repository>> => {
    const repositories = await fetchRepositoriesList()
    applyRepositories(repositories)
    return repositories
  }

  const scanRepositories = async (): Promise<ReadonlyArray<Repository>> => {
    const registered = await discoverRepositories()
    await refreshRepositories()
    return registered
  }

  refreshRepositories()
    .catch(() => {
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
    const filePath = activeIdeFile.value
    const keeper = activeKeeperName.value
    const repoId = activeRepositoryIdSignal.value
    const task = selectedTask.value

    // Cancel in-flight requests for previous file
    abortController.abort()
    abortController = new AbortController()
    const { signal } = abortController

    ownershipStore.reset(filePath)

    const keeperParam = keeper || undefined
    const opts = { keeper: keeperParam, repoId, signal, includeDiff: true }

    // Load file tree (independent of active file — needed to suggest first file)
    fetchWorkspaceTree(2, opts).then(({ nodes, source, basePath }) => {
      if (signal.aborted) return
      // Same repo + source ⇒ live refresh: keep the operator's expansion and
      // any lazily-loaded children. A change ⇒ workspace switch: reset.
      const treeIdentity = `${repoId ?? ''}::${source.kind}`
      if (treeIdentity === lastTreeIdentity) {
        fileTreeStore.reconcile(nodes)
      } else {
        fileTreeStore.seed(nodes)
        lastTreeIdentity = treeIdentity
      }
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

      const hasCurrentFile =
        filePath !== null && nodes.some(node => node.path === filePath && !node.hasChildren)
      const nextFile = hasCurrentFile ? null : firstFilePath(nodes)
      if (nextFile && nextFile !== activeIdeFile.value) {
        activeIdeFile.value = nextFile
      }
    }).catch(() => {})

    // File-scoped fetches require an active file path; skip when none is selected.
    if (filePath === null) {
      diffRowsSignal.value = []
      annotationsSignal.value = []
      return
    }

    // Load file content
    fetchWorkspaceFile(filePath, opts).then(response => {
      if (signal.aborted) return
      if (response?.ok && response.content) {
        documentStore.load({
          file_path: filePath,
          language: response.language ?? DEFAULT_LANGUAGE_ID,
          content: response.content,
        })
      }
    }).catch(() => {})

    // Load regions
    documentStore.loadRegions(filePath, opts).catch(() => {})

    // Load blame → ownership
    fetchGitBlame(filePath, opts).then(blocks => {
      if (signal.aborted) return
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
    }).catch(() => {})

    // Load diff
    fetchGitDiff(filePath, { ...opts, baseRef: 'HEAD' }).then(rows => {
      if (signal.aborted) return
      diffRowsSignal.value = rows
    }).catch(() => {})

    // Load annotations
    fetchIdeAnnotations({ file_path: filePath, goal_id: task?.goal_id ?? undefined, task_id: task?.id ?? undefined }, opts).then(annotations => {
      if (signal.aborted) return
      annotationsSignal.value = annotations
    }).catch(() => {})
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
    dispose: () => {
      abortController.abort()
      unregisterLiveRefresh()
      disposeEffect()
      ownershipStore.dispose()
    },
  }
}
