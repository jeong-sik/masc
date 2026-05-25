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

function sameCursors(
  a: ReadonlyArray<AgentCursor>,
  b: ReadonlyArray<AgentCursor>,
): boolean {
  if (a.length !== b.length) return false
  return a.every((cursor, index) => {
    const next = b[index]
    if (next === undefined) return false
    if (cursor.agent.id !== next.agent.id) return false
    if (cursor.file !== next.file) return false
    if (cursor.position.line !== next.position.line) return false
    if (cursor.position.column !== next.position.column) return false
    const currentSelection = cursor.selection
    const nextSelection = next.selection
    if (currentSelection === undefined && nextSelection === undefined) return true
    if (currentSelection === undefined || nextSelection === undefined) return false
    return (
      currentSelection.line === nextSelection.line &&
      currentSelection.column === nextSelection.column &&
      currentSelection.end.line === nextSelection.end.line &&
      currentSelection.end.column === nextSelection.end.column
    )
  })
}

function sameConflicts(
  a: ReadonlyArray<FileConflict>,
  b: ReadonlyArray<FileConflict>,
): boolean {
  if (a.length !== b.length) return false
  return a.every((conflict, index) => {
    const next = b[index]
    if (next === undefined) return false
    if (conflict.file !== next.file) return false
    if (conflict.lineFrom !== next.lineFrom) return false
    if (conflict.lineTo !== next.lineTo) return false
    if (conflict.agents.length !== next.agents.length) return false
    const currentAgentIds = conflict.agents.map(agent => agent.id).sort()
    const nextAgentIds = next.agents.map(agent => agent.id).sort()
    return currentAgentIds.every((id, agentIndex) => id === nextAgentIds[agentIndex])
  })
}

export function useFileCursors(
  manager: CollaborationManager,
  file: string,
): ReadonlyArray<AgentCursor> {
  const [cursors, setCursors] = useState<ReadonlyArray<AgentCursor>>(() =>
    manager.activeAgentsInFile(file),
  )
  useEffect(() => {
    const updateCursors = (next: ReadonlyArray<AgentCursor>): void => {
      setCursors((prev) => sameCursors(prev, next) ? prev : next)
    }
    updateCursors(manager.activeAgentsInFile(file))
    const dispose = manager.subscribeFile(file, updateCursors)
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
    const updateConflicts = (next: ReadonlyArray<FileConflict>): void => {
      setConflicts((prev) => sameConflicts(prev, next) ? prev : next)
    }
    updateConflicts(manager.conflictsInFile(file))
    const dispose = manager.subscribeConflicts((all) => {
      updateConflicts(all.filter((c) => c.file === file))
    })
    return dispose
  }, [manager, file])
  return conflicts
}
