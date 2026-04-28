/**
 * PortalManager — framework-agnostic stacking authority for portal layers.
 *
 * Binds the `layer` discriminator from RFC 0001 to the existing 7-slot
 * z-index raw tokens already defined in tokens/source.ts:264-268
 * (--z-base/sticky/dropdown/overlay/drawer/modal/toast). One source of
 * truth for stacking — primitives don't pick z-index numbers, they
 * declare *which kind of layer* they are and the manager resolves it.
 *
 * Caller may override the resolved z-index for edge cases (e.g. a
 * tooltip pinned above a toast); the override survives in `topmost()`
 * comparisons as the active value.
 *
 * No DOM access. The manager only tracks bookkeeping; the consumer
 * (Preact adapter, Bonsai adapter, etc.) is responsible for actually
 * mounting nodes and applying the z-index to its rendered surface.
 *
 * Tie-breaking: layers pushed at the same effective z-index are
 * topmost-ordered by *most recently pushed*, matching the OS-window
 * convention users expect.
 */

export type PortalLayerKind =
  | 'base'
  | 'sticky'
  | 'dropdown'
  | 'overlay'
  | 'drawer'
  | 'modal'
  | 'toast'

/**
 * Default z-index per layer kind. Mirrors the raw `--z-*` tokens. Kept
 * in sync with `dashboard/design-system/tokens/source.ts` raw tier.
 * If a token value changes there, update this map and re-run tests.
 */
export const PORTAL_Z_INDEX: Readonly<Record<PortalLayerKind, number>> = Object.freeze({
  base: 1,
  sticky: 20,
  dropdown: 30,
  overlay: 40,
  drawer: 60,
  modal: 80,
  toast: 100,
})

export interface PortalLayer {
  /** Stable id for this portal instance. Used by `pop()`. */
  readonly id: string
  readonly layer: PortalLayerKind
  /** Optional override of the layer's default z-index. */
  readonly zIndex?: number
}

/**
 * A pushed layer with its z-index resolved (override or default).
 * This is what `layers()` and `topmost()` return.
 */
export interface ActivePortalLayer {
  readonly id: string
  readonly layer: PortalLayerKind
  readonly zIndex: number
}

export interface PortalManager {
  /** Push a layer onto the stack. Returns the resolved active layer. */
  push(layer: PortalLayer): ActivePortalLayer
  /** Remove a layer by id. No-op if not present. */
  pop(id: string): void
  /**
   * Highest-z-index active layer; ties broken by most-recently-pushed.
   * Null when the stack is empty.
   */
  topmost(): ActivePortalLayer | null
  /** Immutable snapshot of all active layers in push order. */
  layers(): ReadonlyArray<ActivePortalLayer>
}

function resolveZIndex(layer: PortalLayer): number {
  return layer.zIndex ?? PORTAL_Z_INDEX[layer.layer]
}

export function createPortalManager(): PortalManager {
  const stack: ActivePortalLayer[] = []

  return {
    push(layer: PortalLayer): ActivePortalLayer {
      const active: ActivePortalLayer = Object.freeze({
        id: layer.id,
        layer: layer.layer,
        zIndex: resolveZIndex(layer),
      })
      stack.push(active)
      return active
    },
    pop(id: string): void {
      const idx = stack.findIndex((l) => l.id === id)
      if (idx >= 0) stack.splice(idx, 1)
    },
    topmost(): ActivePortalLayer | null {
      if (stack.length === 0) return null
      // Walk from latest → earliest; first one with the max zIndex wins.
      let best = stack[stack.length - 1]!
      for (let i = stack.length - 2; i >= 0; i -= 1) {
        const candidate = stack[i]!
        if (candidate.zIndex > best.zIndex) best = candidate
      }
      return best
    },
    layers(): ReadonlyArray<ActivePortalLayer> {
      return Object.freeze([...stack])
    },
  }
}
