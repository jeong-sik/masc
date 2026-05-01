// z-index-stack.ts — layer manager for nested overlays (dialog, tooltip, popover)
//
// Kimi design system sec01 1.4.1: pushLayer / popLayer ensure z-index ordering
// without hard-coding arbitrary values throughout components.
//
// A stack (array) of allocated z-indices is maintained so that popping a layer
// always restores the previous top value, even when there are gaps between
// semantic layer bases (e.g. modal=410, tooltip=600).

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

let _stack: number[] = []

/** Allocate a z-index for the given layer type. */
export function pushLayer(layer: LayerKey): number {
  const base = LAYERS[layer] ?? 0
  const top = _stack[_stack.length - 1] ?? 0
  const zIndex = Math.max(top + 1, base)
  _stack.push(zIndex)
  return zIndex
}

/** Release a previously allocated z-index, removing it from the stack. */
export function popLayer(zIndex: number) {
  const idx = _stack.lastIndexOf(zIndex)
  if (idx !== -1) {
    _stack.splice(idx, 1)
  }
}

/** Read the current maximum allocated z-index (for tests / introspection). */
export function currentZIndexMax(): number {
  return _stack[_stack.length - 1] ?? 0
}

/** Reset the stack to zero (for tests only). */
export function resetZIndexStack() {
  _stack = []
}
