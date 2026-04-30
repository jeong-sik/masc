// z-index-stack.ts — layer manager for nested overlays (dialog, tooltip, popover)
//
// Kimi design system sec01 1.4.1: pushLayer / popLayer ensure z-index ordering
// without hard-coding arbitrary values throughout components.

const LAYERS: Record<string, number> = {
  base: 0,
  dropdown: 100,
  sticky: 200,
  fixed: 300,
  'modal-backdrop': 400,
  modal: 410,
  popover: 500,
  tooltip: 600,
}

export type LayerKey =
  | 'base'
  | 'dropdown'
  | 'sticky'
  | 'fixed'
  | 'modal-backdrop'
  | 'modal'
  | 'popover'
  | 'tooltip'

let _currentMax = 0

/** Allocate a z-index for the given layer type. */
export function pushLayer(layer: LayerKey): number {
  const base = LAYERS[layer]
  _currentMax = Math.max(_currentMax + 1, base)
  return _currentMax
}

/** Release a previously allocated z-index (only if it was the current max). */
export function popLayer(zIndex: number) {
  if (zIndex === _currentMax) _currentMax--
}

/** Read the current maximum allocated z-index (for tests / introspection). */
export function currentZIndexMax(): number {
  return _currentMax
}

/** Reset the stack to zero (for tests only). */
export function resetZIndexStack() {
  _currentMax = 0
}
