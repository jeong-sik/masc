// Builds the `surface_context` payload an IDE interject attaches to a keeper
// chat message, so the keeper knows what the operator was looking at.
//
// Wire shape mirrors the board producer
// (server_routes_http_routes_activity.ml, board_context_inference_surface_context):
// `{label, route, scene, fields}` where `fields` is a `[{k, v}, ...]` list the
// keeper prompt renders as `- k: v` lines
// (keeper_turn.ml, surface_context_fields).
import type { KeeperStreamSurfaceContext } from '../../api/keeper'
import type { IdeFileFocus } from './ide-state'
import type { IdeEditorSelection } from './ide-editor-selection'

export interface IdeInterjectContextInputs {
  readonly focus: IdeFileFocus | null
  readonly selection: IdeEditorSelection | null
}

interface SurfaceContextField {
  readonly k: string
  readonly v: string
}

function selectionLinesLabel(selection: IdeEditorSelection): string {
  return selection.lineStart === selection.lineEnd
    ? `L${selection.lineStart}`
    : `L${selection.lineStart}-L${selection.lineEnd}`
}

/** Returns `undefined` when the IDE holds no context worth sending — a bare
 *  `surface: ide` marker alone would add prompt noise without an anchor. */
export function buildIdeInterjectSurfaceContext(
  inputs: IdeInterjectContextInputs,
): KeeperStreamSurfaceContext | undefined {
  const fields: SurfaceContextField[] = [{ k: 'surface', v: 'ide' }]
  const focusPath = inputs.focus?.path.trim() || null
  const selection = inputs.selection
  const selectionPath = selection?.filePath.trim() || null
  // The selection carries its own filePath; prefer it over the focused tab so
  // lines always refer to the file they were selected in.
  const file = selectionPath ?? focusPath
  if (file) {
    fields.push({ k: 'file', v: file })
  }
  if (selection && selectionPath) {
    fields.push({ k: 'lines', v: selectionLinesLabel(selection) })
  }
  const identity = inputs.focus?.workspace_identity
  if (identity?.kind === 'repository') {
    fields.push({ k: 'repo', v: identity.repoId })
    // RFC-0378 §5.3: the codebase slug is the anchor vocabulary the keeper
    // hands back to keeper_ide_annotate verbatim.
    if (identity.codebase) fields.push({ k: 'codebase', v: identity.codebase })
  } else if (identity?.kind === 'keeper') {
    fields.push({ k: 'workspace_keeper', v: identity.keeper })
  }
  if (fields.length === 1) return undefined
  const routeParams = new URLSearchParams({ section: 'ide-shell' })
  if (file) routeParams.set('file', file)
  if (selection && selectionPath) routeParams.set('line', String(selection.lineStart))
  return {
    label: 'IDE interject context',
    route: `#code?${routeParams.toString()}`,
    scene: 'ide_interject',
    fields,
  }
}
