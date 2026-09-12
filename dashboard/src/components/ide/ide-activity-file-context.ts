import type { RunActivityEvent } from './run-activity-store'
import { normalizeIdeContextFilePath, normalizeIdeContextLine } from './ide-state'

/** A relative file path is meaningful only inside its server-resolved codebase.
 * The workspace-wide activity API supplies no such per-event authority. */
export function activityFileContext(event: RunActivityEvent, codebase: string | null | undefined): {
  readonly filePath: string
  readonly line: number | undefined
} | null {
  const selectedCodebase = codebase?.trim()
  if (!selectedCodebase || event.codebase !== selectedCodebase) return null
  const rawFile = event.context?.file_path
  if (rawFile === undefined) return null
  const filePath = normalizeIdeContextFilePath(rawFile)
  if (filePath === null) return null
  return { filePath, line: normalizeIdeContextLine(event.context?.line) }
}
