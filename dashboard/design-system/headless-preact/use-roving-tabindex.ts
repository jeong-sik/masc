/**
 * useRovingTabindex — Preact adapter over headless-core/RovingTabindex.
 *
 * Per RFC 0003 §3.2. Replaces the inline `keydown + index tracking +
 * tabindex shuffling` patterns currently scattered across mode-tabs,
 * keeper-inspector tabs, and the cockpit Toolbar prototype. Consumer
 * supplies the item list and binds the returned prop bundles onto
 * its container + item elements.
 *
 * The adapter:
 *   - Lazily creates the RovingTabindex controller on first render
 *     (cached via useRef so re-renders don't reinstantiate state)
 *   - Synchronizes the controller with the latest items array each
 *     render via setItems()
 *   - Subscribes to activeId changes and triggers a re-render via a
 *     useState bump
 *   - Cleans up the subscription on unmount (no leaked listeners)
 *
 * Returns prop getters (not pre-baked attribute objects) so the
 * consumer can spread them onto multiple elements per item without
 * forcing the adapter to memoize per-item objects.
 */

import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import {
  createRovingTabindex,
  type Orientation,
  type RovingItemDescriptor,
  type RovingTabindexController,
  type RovingContainerProps,
  type RovingItemProps,
  type RovingKeyEvent,
} from '../headless-core/roving-tabindex'

export interface UseRovingTabindexArgs<T extends RovingItemDescriptor> {
  items: ReadonlyArray<T>
  orientation: Orientation
  loop?: boolean
  activateOnFocus?: boolean
  defaultActiveId?: string
  typeaheadResetMs?: number
  /** Fires whenever the rover lands on a new id (or null when the
   *  list empties). */
  onActiveChange?: (id: string | null) => void
}

export interface UseRovingTabindexResult<T extends RovingItemDescriptor> {
  readonly activeId: string | null
  readonly items: ReadonlyArray<T>
  /** Spread onto the role=tablist / toolbar / tree container element. */
  getContainerProps(): RovingContainerProps
  /** Spread onto each role=tab / button / treeitem element. */
  getItemProps(id: string): RovingItemProps
  /** Imperatively focus a specific item. */
  setActive(id: string): void
  next(): void
  prev(): void
  first(): void
  last(): void
}

export function useRovingTabindex<T extends RovingItemDescriptor>(
  args: UseRovingTabindexArgs<T>,
): UseRovingTabindexResult<T> {
  const controllerRef = useRef<RovingTabindexController | null>(null)
  // Bump-state forces re-render on activeId change; the actual id is
  // read off the controller (single source of truth). Keeps re-render
  // semantics aligned with subscription-based mutation.
  const [, bumpState] = useState(0)

  if (controllerRef.current === null) {
    controllerRef.current = createRovingTabindex({
      orientation: args.orientation,
      loop: args.loop,
      activateOnFocus: args.activateOnFocus,
      defaultActiveId: args.defaultActiveId,
      typeaheadResetMs: args.typeaheadResetMs,
      items: args.items,
      onActiveChange: args.onActiveChange,
    })
  }

  // Sync items every render. Cheap when reference-stable; controller
  // skips emit when nothing changed.
  useEffect(() => {
    controllerRef.current?.setItems(args.items)
  }, [args.items])

  // Wire subscription once.
  useEffect(() => {
    const controller = controllerRef.current
    if (controller === null) return undefined
    const dispose = controller.subscribe(() => {
      bumpState((n) => n + 1)
    })
    return dispose
  }, [])

  const result = useMemo<UseRovingTabindexResult<T>>(() => {
    const controller = controllerRef.current!
    return {
      get activeId() {
        return controller.activeId
      },
      get items() {
        return args.items
      },
      getContainerProps() {
        return {
          ...controller.getContainerProps(),
          // Bind via closure so we always dispatch through the live
          // controller even if a stale prop bundle gets cached.
          onKeyDown: (e: RovingKeyEvent) => controller.handleKeyDown(e),
        }
      },
      getItemProps(id: string) {
        return controller.getItemProps(id)
      },
      setActive(id: string) {
        controller.setActive(id)
      },
      next() {
        controller.next()
      },
      prev() {
        controller.prev()
      },
      first() {
        controller.first()
      },
      last() {
        controller.last()
      },
    }
  }, [args.items])

  return result
}
