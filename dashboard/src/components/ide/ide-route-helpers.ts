import { parsePositiveLineString } from '../common/normalize'
import {
  parseActive,
  serializeActive,
} from '../../../design-system/headless-core/layered-overlay'
import { navigate, route } from '../../router'
import { activeKeeperName } from '../../keeper-state'
import { keepers } from '../../store'
import type { IdeEditorView } from './ide-editor'
import { IDE_LAYERS, REVIEW_FOCUS_LAYERS } from './ide-toolbar'

export type ViewTab = IdeEditorView
export type IdeFocus = 'review'

export const EMPTY_LAYER_PARAM = 'none'
const IDE_LAYER_KINDS = new Set(IDE_LAYERS.map(layer => layer.kind))
const REVIEW_FOCUS_LAYER_PARAM = REVIEW_FOCUS_LAYERS.join(',')

export function viewFromRoute(raw: string | null | undefined): ViewTab {
  const normalized = raw
    ?.trim()
    .toLowerCase()
    .replace(/[_\s]+/g, '-')
  if (normalized === 'split' || normalized === 'split-diff' || normalized === 'merge') return 'split-diff'
  if (normalized === 'unified') return 'unified'
  if (normalized === 'blame') return 'blame'
  return 'source'
}

export function focusFromRoute(raw: string | null | undefined): IdeFocus | null {
  return raw?.trim().toLowerCase() === 'review' ? 'review' : null
}

export function layersFromRoute(
  raw: string | null | undefined,
  focus: IdeFocus | null,
): ReadonlySet<string> {
  if (raw?.trim().toLowerCase() === EMPTY_LAYER_PARAM) return new Set()
  if (focus === 'review' && !raw?.trim()) {
    return parseActive(REVIEW_FOCUS_LAYER_PARAM, IDE_LAYER_KINDS)
  }
  return parseActive(raw ?? '', IDE_LAYER_KINDS)
}

export function keeperFromRoute(): string {
  const routeKeeper = route.value.params.keeper?.trim()
  if (routeKeeper) return routeKeeper
  const active = activeKeeperName.value.trim()
  if (active) return active
  return keepers.value[0]?.name?.trim() ?? ''
}

export function routeFocusFile(params: Record<string, string>): string | undefined {
  return params.file?.trim() || params.file_path?.trim() || params.path?.trim() || undefined
}

export function routeFocusLine(params: Record<string, string>): number | undefined {
  const raw = params.line?.trim() || params.lineno?.trim()
  if (!raw) return undefined
  return parsePositiveLineString(raw)
}

export function routeFocusLabel(params: Record<string, string>, filePath: string): string {
  const label = params.label?.trim()
  if (label) return label
  return filePath.split('/').pop() || filePath
}

export function routeFocusSourceId(
  params: Record<string, string>,
  filePath: string,
  line?: number,
): string {
  const sourceId = params.source_id?.trim() || params.source?.trim()
  if (sourceId) return sourceId
  return line !== undefined ? `route:${filePath}:${line}` : `route:${filePath}`
}

export function routeParam(
  params: Record<string, string>,
  ...keys: ReadonlyArray<string>
): string | undefined {
  for (const key of keys) {
    const value = params[key]?.trim()
    if (value) return value
  }
  return undefined
}

export function paramsWithLayers(
  params: Record<string, string>,
  view: ViewTab,
  activeLayers: ReadonlySet<string>,
): Record<string, string> {
  const next: Record<string, string> = { ...params, section: 'ide-shell', view }
  const serialized = serializeActive(activeLayers)
  if (serialized) {
    next.layers = serialized
  } else if (focusFromRoute(params.focus) === 'review' && view === 'unified') {
    next.layers = EMPTY_LAYER_PARAM
  } else {
    delete next.layers
  }
  return next
}

export function paramsWithRails(
  params: Record<string, string>,
  view: ViewTab,
  collapsed: boolean,
): Record<string, string> {
  const next: Record<string, string> = { ...params, section: 'ide-shell', view }
  if (collapsed) {
    next.rails = 'hidden'
  } else {
    delete next.rails
  }
  return next
}
