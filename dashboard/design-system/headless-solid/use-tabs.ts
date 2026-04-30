/**
 * useTabs — SolidJS adapter over headless-core/Tabs
 * (RFC 0015 §3.2, RFC 0017 PR #2.3).
 *
 * Mirrors headless-preact/use-tabs.ts. Cached controller via createRoot
 * lifetime, subscribe → setSignal direct path, accessors expose live
 * controller state.
 */

import { createSignal, onCleanup, type Accessor } from 'solid-js'
import {
  createTabs,
  type CloseButtonProps,
  type TabDescriptor,
  type TabListProps,
  type TabPanelProps,
  type TabProps,
  type TabsController,
  type TabsOptions,
} from '../headless-core/tabs'

export interface UseTabsResult {
  readonly activeId: Accessor<string | null>
  readonly tabs: Accessor<ReadonlyArray<TabDescriptor>>
  readonly draggingId: Accessor<string | null>
  readonly controller: TabsController
  getTabListProps(): TabListProps
  getTabProps(id: string): TabProps
  getTabPanelProps(id: string): TabPanelProps
  getCloseButtonProps(id: string): CloseButtonProps
  activate(id: string): void
  close(id: string): void
  reorder(ids: ReadonlyArray<string>): void
}

export function useTabs(opts: TabsOptions): UseTabsResult {
  const controller = createTabs(opts)

  const [activeId, setActiveId] = createSignal<string | null>(controller.activeId)
  const [tabs, setTabs] = createSignal<ReadonlyArray<TabDescriptor>>(controller.tabs)
  const [draggingId, setDraggingId] = createSignal<string | null>(controller.draggingId)

  const dispose = controller.subscribe((snap) => {
    setActiveId(snap.activeId)
    setTabs(snap.tabs)
    setDraggingId(snap.draggingId)
  })
  onCleanup(dispose)

  return {
    activeId,
    tabs,
    draggingId,
    controller,
    getTabListProps: () => controller.getTabListProps(),
    getTabProps: (id) => controller.getTabProps(id),
    getTabPanelProps: (id) => controller.getTabPanelProps(id),
    getCloseButtonProps: (id) => controller.getCloseButtonProps(id),
    activate: (id) => controller.activate(id),
    close: (id) => controller.close(id),
    reorder: (ids) => controller.reorder(ids),
  }
}
