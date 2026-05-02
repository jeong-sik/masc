/**
 * LayeredOverlay — framework-agnostic multi-select toggle controller
 * for the IDE editor LAYERS bar (RFC 0020).
 *
 * Each registered layer can be toggled independently. Layers may
 * declare `mutuallyExclusive: true`, in which case activating that
 * layer clears every other active layer, and activating any other
 * layer clears the exclusive one. EXPLODE in the IDE mockup is the
 * canonical exclusive layer.
 *
 * The controller does not render anything; consumers (the toolbar
 * component, an URL persistence layer) read the active set and emit
 * toggles. Subscribers receive the new active set per change so they
 * can update without reading state from the controller.
 *
 * Out of scope (RFC 0020 §2):
 *   - Per-overlay rendering. Each overlay's pixels are owned by its
 *     consumer (editor blame strip for `time`, gutter striper for
 *     `parallel`, etc.).
 *   - Layer ordering / z-index — registration order is the default;
 *     consumer can sort.
 *   - Persistence — URL serialization helpers live alongside but the
 *     controller itself is in-memory.
 */

export interface OverlayLayer {
  readonly kind: string
  readonly label: string
  readonly description: string
  readonly mutuallyExclusive?: boolean
}

export interface LayeredOverlayController {
  readonly layers: ReadonlyArray<OverlayLayer>
  readonly active: () => ReadonlySet<string>
  readonly toggle: (kind: string) => void
  readonly setActive: (active: ReadonlySet<string>) => void
  readonly clear: () => void
  readonly isActive: (kind: string) => boolean
  readonly subscribe: (listener: (active: ReadonlySet<string>) => void) => () => void
}

export function createLayeredOverlay(layers: ReadonlyArray<OverlayLayer>): LayeredOverlayController {
  const layerByKind = new Map<string, OverlayLayer>()
  for (const layer of layers) {
    if (layerByKind.has(layer.kind)) {
      throw new Error(`createLayeredOverlay: duplicate layer kind "${layer.kind}"`)
    }
    layerByKind.set(layer.kind, layer)
  }

  let activeSet: Set<string> = new Set()
  const listeners = new Set<(active: ReadonlySet<string>) => void>()

  const emit = (): void => {
    const snapshot: ReadonlySet<string> = new Set(activeSet)
    for (const listener of listeners) {
      listener(snapshot)
    }
  }

  const isExclusive = (kind: string): boolean => layerByKind.get(kind)?.mutuallyExclusive === true

  const sameActive = (left: ReadonlySet<string>, right: ReadonlySet<string>): boolean => {
    if (left.size !== right.size) return false
    for (const kind of left) {
      if (!right.has(kind)) return false
    }
    return true
  }

  const normalizeActive = (active: ReadonlySet<string>): Set<string> => {
    const requested = new Set([...active].filter(kind => layerByKind.has(kind)))
    const exclusive = layers.find(layer => layer.mutuallyExclusive === true && requested.has(layer.kind))
    if (exclusive) return new Set([exclusive.kind])
    const next = new Set<string>()
    for (const layer of layers) {
      if (requested.has(layer.kind)) next.add(layer.kind)
    }
    return next
  }

  const hasExclusiveActive = (): string | null => {
    for (const kind of activeSet) {
      if (isExclusive(kind)) return kind
    }
    return null
  }

  const toggle = (kind: string): void => {
    if (!layerByKind.has(kind)) return
    const next = new Set(activeSet)

    if (next.has(kind)) {
      next.delete(kind)
    } else if (isExclusive(kind)) {
      // Activating an exclusive layer clears everything else.
      next.clear()
      next.add(kind)
    } else {
      // Activating any non-exclusive layer drops any active exclusive
      // layer first, then adds the new layer.
      const exclusive = hasExclusiveActive()
      if (exclusive !== null) next.delete(exclusive)
      next.add(kind)
    }

    activeSet = next
    emit()
  }

  const setActive = (active: ReadonlySet<string>): void => {
    const next = normalizeActive(active)
    if (sameActive(activeSet, next)) return
    activeSet = next
    emit()
  }

  const clear = (): void => {
    if (activeSet.size === 0) return
    activeSet = new Set()
    emit()
  }

  const isActive = (kind: string): boolean => activeSet.has(kind)
  const active = (): ReadonlySet<string> => new Set(activeSet)

  const subscribe = (listener: (active: ReadonlySet<string>) => void): (() => void) => {
    listeners.add(listener)
    return () => {
      listeners.delete(listener)
    }
  }

  return { layers, active, toggle, setActive, clear, isActive, subscribe }
}

/**
 * Serialize an active set to a canonical query-string-safe form.
 * Order is alphabetical so deep links don't churn between renders.
 */
export function serializeActive(active: ReadonlySet<string>): string {
  return [...active].sort().join(',')
}

/**
 * Parse a comma-separated active list, dropping unknown layer kinds.
 * Empty or whitespace-only input returns an empty set.
 */
export function parseActive(
  input: string,
  knownKinds: ReadonlySet<string>,
): ReadonlySet<string> {
  const trimmed = input.trim()
  if (trimmed === '') return new Set()
  const parts = trimmed.split(',').map(p => p.trim()).filter(p => p !== '')
  const filtered: Set<string> = new Set()
  for (const kind of parts) {
    if (knownKinds.has(kind)) filtered.add(kind)
  }
  return filtered
}
