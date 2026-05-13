import { signal, effect } from '@preact/signals'
import { activeIdeFile } from './ide-shell'
import { activeKeeperName } from '../../keeper-state'
import { selectedTask } from '../goals/task-detail-selection'
import {
  discoverRepositories,
  fetchRepositoriesList,
  type Repository,
} from '../../api/repositories'
import {
  fetchWorkspaceFile,
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

export interface IdeDataCoordinator {
  readonly documentStore: CodeDocumentStore
  readonly ownershipStore: KeeperLineOwnershipStore
  readonly fileTreeStore: FileTreeStore
  readonly diffRows: () => ReadonlyArray<UnifiedDiffRow>
  readonly subscribeDiffRows: (listener: () => void) => () => void
  readonly workspaceSource: () => WorkspaceSource
  readonly subscribeWorkspaceSource: (listener: () => void) => () => void
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

function isMascMcpRepository(repository: Repository): boolean {
  return repository.id === 'masc-mcp' || repository.name === 'masc-mcp'
}

export function selectPreferredIdeRepositoryId(
  repositories: ReadonlyArray<Repository>,
  current: string | null,
): string | null {
  if (current && repositories.some(repository => repository.id === current)) {
    return current
  }

  return repositories.find(repository => isMascMcpRepository(repository) && isWorkspaceRepository(repository))?.id
    ?? repositories.find(isWorkspaceRepository)?.id
    ?? repositories.find(isMascMcpRepository)?.id
    ?? repositories.find(repository => !isManagedMirrorRepository(repository))?.id
    ?? repositories[0]?.id
    ?? null
}

export function createIdeDataCoordinator(): IdeDataCoordinator {
  const documentStore = createCodeDocumentStore({
    file_path: activeIdeFile.value,
    language: 'text',
    content: '',
  })
  const ownershipStore = createKeeperLineOwnershipStore(activeIdeFile.value)
  const fileTreeStore = createFileTreeStore()

  const diffRowsSignal = signal<ReadonlyArray<UnifiedDiffRow>>([])
  const workspaceSourceSignal = signal<WorkspaceSource>({ kind: 'project' })
  const repositoriesSignal = signal<ReadonlyArray<Repository>>([])
  const activeRepositoryIdSignal = signal<string | null>(null)
  const annotationsSignal = signal<ReadonlyArray<IdeAnnotation>>([])

  let abortController = new AbortController()

  const applyRepositories = (repositories: ReadonlyArray<Repository>): void => {
    const current = activeRepositoryIdSignal.value
    activeRepositoryIdSignal.value = selectPreferredIdeRepositoryId(repositories, current)
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

  // React to file / keeper changes
  const disposeEffect = effect(() => {
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
    const opts = { keeper: keeperParam, repoId, signal }

    // Load file tree
    fetchWorkspaceTree(2, opts).then(({ nodes, source }) => {
      if (signal.aborted) return
      fileTreeStore.seed(nodes)
      workspaceSourceSignal.value = source
      const hasCurrentFile = nodes.some(node => node.path === filePath && !node.hasChildren)
      const nextFile = hasCurrentFile ? null : firstFilePath(nodes)
      if (nextFile && nextFile !== activeIdeFile.value) {
        activeIdeFile.value = nextFile
      }
    }).catch(() => {})

    // Load file content
    fetchWorkspaceFile(filePath, opts).then(response => {
      if (signal.aborted) return
      if (response?.ok && response.content) {
        documentStore.load({
          file_path: filePath,
          language: response.language ?? 'text',
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
  })

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
      disposeEffect()
      ownershipStore.dispose()
    },
  }
}
