/**
 * useCollaboration — Preact adapter over headless-core/CollaborationManager
 * (RFC 0010 §3.3).
 *
 * Hooks for file-scoped cursor and conflict subscriptions. The
 * manager is provided externally so multiple editor surfaces share
 * the same conflict state.
 */

import { useEffect, useState } from 'preact/hooks'
import type {
  AgentCursor,
  CollaborationManager,
  FileConflict,
} from '../headless-core/collaboration'

export function useFileCursors(
  manager: CollaborationManager,
  file: string,
): ReadonlyArray<AgentCursor> {
  const [cursors, setCursors] = useState<ReadonlyArray<AgentCursor>>(() =>
    manager.activeAgentsInFile(file),
  )
  useEffect(() => {
    setCursors(manager.activeAgentsInFile(file))
    const dispose = manager.subscribeFile(file, (cs) => setCursors(cs))
    return dispose
  }, [manager, file])
  return cursors
}

export function useFileConflicts(
  manager: CollaborationManager,
  file: string,
): ReadonlyArray<FileConflict> {
  const [conflicts, setConflicts] = useState<ReadonlyArray<FileConflict>>(() =>
    manager.conflictsInFile(file),
  )
  useEffect(() => {
    setConflicts(manager.conflictsInFile(file))
    const dispose = manager.subscribeConflicts((all) => {
      setConflicts(all.filter((c) => c.file === file))
    })
    return dispose
  }, [manager, file])
  return conflicts
}
