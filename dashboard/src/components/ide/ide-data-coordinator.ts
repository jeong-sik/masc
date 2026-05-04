import { signal, effect } from '@preact/signals'
import { activeIdeFile } from './ide-shell'
import { activeKeeperName } from '../../keeper-state'
import {
  fetchWorkspaceFile,
  fetchGitBlame,
  fetchGitDiff,
  fetchWorkspaceTree,
  type UnifiedDiffRow,
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

export interface IdeDataCoordinator {
  readonly documentStore: CodeDocumentStore
  readonly ownershipStore: KeeperLineOwnershipStore
  readonly fileTreeStore: FileTreeStore
  readonly diffRows: () => ReadonlyArray<UnifiedDiffRow>
  readonly subscribeDiffRows: (listener: () => void) => () => void
  readonly dispose: () => void
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

  let abortController = new AbortController()

  // React to file / keeper changes
  const disposeEffect = effect(() => {
    const filePath = activeIdeFile.value
    const keeper = activeKeeperName.value

    // Cancel in-flight requests for previous file
    abortController.abort()
    abortController = new AbortController()
    const { signal } = abortController

    ownershipStore.reset(filePath)

    const keeperParam = keeper || undefined
    const opts = { keeper: keeperParam, signal }

    // Load file tree
    fetchWorkspaceTree(2, opts).then(nodes => {
      if (signal.aborted) return
      fileTreeStore.seed(nodes)
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
  })

  return {
    documentStore,
    ownershipStore,
    fileTreeStore,
    diffRows: () => diffRowsSignal.value,
    subscribeDiffRows: diffRowsSignal.subscribe as (listener: () => void) => () => void,
    dispose: () => {
      abortController.abort()
      disposeEffect()
      ownershipStore.dispose()
    },
  }
}
