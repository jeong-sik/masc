/**
 * useRovingTabindex — SolidJS adapter over headless-core/RovingTabindex
 * (RFC 0003 §3.2, RFC 0017 PR #2.7).
 *
 * Replaces ad-hoc keydown + tabindex shuffling. Consumer supplies the
 * item list (as an Accessor for reactive updates) and binds the
 * returned prop bundles onto container + item elements.
 *
 * - Controller created in the hook body (inside createRoot scope).
 * - createEffect syncs items() to controller.setItems() on each change.
 * - subscribe → setSignal on activeId change for reactive reads.
 * - onCleanup releases the subscription.
 */

import { createEffect, createSignal, onCleanup, type Accessor } from 'solid-js'
import {
  createRovingTabindex,
  type Orientation,
  type RovingContainerProps,
  type RovingItemDescriptor,
  type RovingItemProps,
  type RovingKeyEvent,
  type RovingTabindexController,
} from '../headless-core/roving-tabindex'

export interface UseRovingTabindexArgs<T extends RovingItemDescriptor> {
  /** Items getter — pass an Accessor for reactive updates. */
  items: Accessor<ReadonlyArray<T>> | ReadonlyArray<T>
  orientation: Orientation
  loop?: boolean
  activateOnFocus?: boolean
  defaultActiveId?: string
  typeaheadResetMs?: number
  onActiveChange?: (id: string | null) => void
}

export interface UseRovingTabindexResult<T extends RovingItemDescriptor> {
  readonly activeId: Accessor<string | null>
  readonly items: Accessor<ReadonlyArray<T>>
  getContainerProps(): RovingContainerProps
  getItemProps(id: string): RovingItemProps
  setActive(id: string): void
  next(): void
  prev(): void
  first(): void
  last(): void
}

export function useRovingTabindex<T extends RovingItemDescriptor>(
  args: UseRovingTabindexArgs<T>,
): UseRovingTabindexResult<T> {
  const itemsAccessor: Accessor<ReadonlyArray<T>> =
    typeof args.items === 'function'
      ? (args.items as Accessor<ReadonlyArray<T>>)
      : () => args.items as ReadonlyArray<T>

  const controller: RovingTabindexController = createRovingTabindex({
    orientation: args.orientation,
    loop: args.loop,
    activateOnFocus: args.activateOnFocus,
    defaultActiveId: args.defaultActiveId,
    typeaheadResetMs: args.typeaheadResetMs,
    items: itemsAccessor(),
    onActiveChange: args.onActiveChange,
  })

  const [activeId, setActiveId] = createSignal<string | null>(controller.activeId)

  createEffect(() => {
    controller.setItems(itemsAccessor())
  })

  const dispose = controller.subscribe(() => setActiveId(controller.activeId))
  onCleanup(dispose)

  return {
    activeId,
    items: itemsAccessor,
    getContainerProps: () => ({
      ...controller.getContainerProps(),
      onKeyDown: (e: RovingKeyEvent) => controller.handleKeyDown(e),
    }),
    getItemProps: (id: string) => controller.getItemProps(id),
    setActive: (id) => controller.setActive(id),
    next: () => controller.next(),
    prev: () => controller.prev(),
    first: () => controller.first(),
    last: () => controller.last(),
  }
}
