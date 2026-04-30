/**
 * useTabs — Preact adapter over headless-core/Tabs (RFC 0015 §3.2).
 *
 * Mirrors the use-roving-tabindex shape: cached controller via useRef,
 * subscribe → bumpState for re-render, useMemo prop getters.
 */

import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
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
  readonly activeId: string | null
  readonly tabs: ReadonlyArray<TabDescriptor>
  readonly draggingId: string | null
  getTabListProps(): TabListProps
  getTabProps(id: string): TabProps
  getTabPanelProps(id: string): TabPanelProps
  getCloseButtonProps(id: string): CloseButtonProps
  activate(id: string): void
  close(id: string): void
  reorder(ids: ReadonlyArray<string>): void
}

export function useTabs(opts: TabsOptions): UseTabsResult {
  const controllerRef = useRef<TabsController | null>(null)
  const [, bump] = useState(0)

  if (controllerRef.current === null) {
    controllerRef.current = createTabs(opts)
  }

  useEffect(() => {
    controllerRef.current?.setTabs(opts.tabs)
  }, [opts.tabs])

  useEffect(() => {
    const c = controllerRef.current
    if (c === null) return undefined
    return c.subscribe(() => bump((n) => n + 1))
  }, [])

  return useMemo<UseTabsResult>(() => {
    const c = controllerRef.current!
    return {
      get activeId() {
        return c.activeId
      },
      get tabs() {
        return c.tabs
      },
      get draggingId() {
        return c.draggingId
      },
      getTabListProps: () => c.getTabListProps(),
      getTabProps: (id) => c.getTabProps(id),
      getTabPanelProps: (id) => c.getTabPanelProps(id),
      getCloseButtonProps: (id) => c.getCloseButtonProps(id),
      activate: (id) => c.activate(id),
      close: (id) => c.close(id),
      reorder: (ids) => c.reorder(ids),
    }
  }, [])
}
