import type { ArtifactDraftTarget } from '../api/artifact-drafts'
import type { ArtifactWorkspace } from '../api/published-artifacts'

export type ArtifactDraftRecovery = { id: string; workspace: ArtifactWorkspace; target: ArtifactDraftTarget; state: string; at: string; persisted: boolean }
const prefix = 'masc.artifact-draft-recovery.v1:'
const memory = new Map<string, ArtifactDraftRecovery>()
// Records are per editor, so one session never acknowledges another's pending
// work. They are recovery copies, never an authority or automatic write source.
export function retainArtifactDraft(id: string, workspace: ArtifactWorkspace, target: ArtifactDraftTarget, state: string): ArtifactDraftRecovery {
  const record = { id, workspace, target, state, at: new Date().toISOString(), persisted: false }
  try { localStorage.setItem(prefix + id, JSON.stringify(record)); record.persisted = true } catch { /* Keep the in-page recovery if browser storage is full. */ }
  memory.set(id, record)
  return record
}
export function discardArtifactDraftRecovery(id: string): void {
  memory.delete(id)
  try { localStorage.removeItem(prefix + id) } catch { /* A stale copy can safely be offered again, never auto-applied. */ }
}
export function artifactDraftRecoveries(workspace: ArtifactWorkspace, artifactId: string): ArtifactDraftRecovery[] {
  try {
    for (let index = 0; index < localStorage.length; index++) {
      const key = localStorage.key(index)
      if (!key?.startsWith(prefix)) continue
      let value: unknown
      try { value = JSON.parse(localStorage.getItem(key) ?? 'null') } catch { continue }
      if (typeof value !== 'object' || value === null) continue
      const record = value as Partial<ArtifactDraftRecovery>
      if (typeof record.id !== 'string' || key !== prefix + record.id || typeof record.at !== 'string'
        || typeof record.state !== 'string' || !record.workspace || !record.target
        || typeof record.target.artifact_id !== 'string' || typeof record.target.generation !== 'string'
        || typeof record.workspace.basePath !== 'string' || typeof record.workspace.mascRoot !== 'string') continue
      // Memory can contain a newer snapshot after a failed browser-storage write.
      if (!memory.has(record.id)) memory.set(record.id, { ...record, persisted: true } as ArtifactDraftRecovery)
    }
  } catch { /* In-page recovery remains usable when local storage is disabled. */ }
  return [...memory.values()].filter(record => record.workspace.basePath === workspace.basePath
    && record.workspace.mascRoot === workspace.mascRoot && record.target.artifact_id === artifactId)
}

if (typeof window !== 'undefined') window.addEventListener('beforeunload', event => {
  if ([...memory.values()].some(record => !record.persisted)) { event.preventDefault(); event.returnValue = '' }
})
