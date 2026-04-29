/**
 * Tabs — framework-agnostic tablist primitive (RFC 0015).
 *
 * Composes RovingTabindex (RFC 0003) for arrow / Home / End / typeahead
 * navigation, then layers on tab-specific behavior: aria-selected,
 * aria-controls/aria-labelledby cross-references, automatic vs manual
 * activation, close button (Delete keyboard), drag reorder.
 *
 * MVP scope (RFC 0015 §3, §4, §5):
 *   - automatic activation (default): rover move = activation
 *   - manual activation: Enter / Space activates focused tab
 *   - orientation horizontal (default) / vertical
 *   - close: Delete on focused tab fires onClose; close button has
 *     tabIndex=-1 so Tab traversal goes through the tab itself
 *     (matches VS Code; avoids "Tab Tab Enter" close-button trap)
 *   - drag reorder via 3 handlers; pinned tabs stay clustered
 *
 * Out of scope (RFC 0015 §12):
 *   - Tab content lazy loading / unmount (consumer concern)
 *   - Persistence of active tab (consumer owns localStorage / route)
 *   - Multi-row tab wrap
 */

import {
  createRovingTabindex,
  type RovingTabindexController,
  type RovingKeyEvent,
} from './roving-tabindex'

export interface TabDescriptor {
  readonly id: string
  readonly label: string
  readonly disabled?: boolean
  readonly closeable?: boolean
  readonly pinned?: boolean
}

export type ActivationMode = 'automatic' | 'manual'
export type TabsOrientation = 'horizontal' | 'vertical'

export interface TabsOptions {
  tabs: ReadonlyArray<TabDescriptor>
  activationMode?: ActivationMode
  orientation?: TabsOrientation
  defaultActiveId?: string
  onActiveChange?: (id: string) => void
  onClose?: (id: string) => void
  onReorder?: (ids: ReadonlyArray<string>) => void
}

export interface TabsKeyEvent {
  readonly key: string
  readonly metaKey?: boolean
  readonly ctrlKey?: boolean
  readonly shiftKey?: boolean
  readonly altKey?: boolean
  preventDefault(): void
}

export interface TabListProps {
  readonly role: 'tablist'
  readonly 'aria-orientation': TabsOrientation
  readonly tabIndex: -1
  readonly onKeyDown: (e: TabsKeyEvent) => void
}

export interface TabProps {
  readonly id: string
  readonly role: 'tab'
  readonly 'aria-selected': boolean
  readonly 'aria-controls': string
  readonly 'aria-disabled'?: true
  readonly tabIndex: 0 | -1
  readonly 'data-active': '' | undefined
  readonly onClick: () => void
}

export interface TabPanelProps {
  readonly id: string
  readonly role: 'tabpanel'
  readonly 'aria-labelledby': string
  readonly tabIndex: 0
  readonly hidden: boolean
}

export interface CloseButtonProps {
  readonly type: 'button'
  readonly 'aria-label': string
  readonly tabIndex: -1
  readonly onClick: () => void
}

export interface TabsController {
  readonly activeId: string | null
  readonly tabs: ReadonlyArray<TabDescriptor>
  readonly draggingId: string | null

  setTabs(tabs: ReadonlyArray<TabDescriptor>): void
  activate(id: string): void
  close(id: string): void
  reorder(ids: ReadonlyArray<string>): void

  getTabListProps(): TabListProps
  getTabProps(id: string): TabProps
  getTabPanelProps(id: string): TabPanelProps
  getCloseButtonProps(id: string): CloseButtonProps

  handleDragStart(id: string): void
  handleDragOver(targetId: string): void
  handleDragEnd(): void

  subscribe(listener: (snapshot: TabsSnapshot) => void): () => void
}

export interface TabsSnapshot {
  readonly activeId: string | null
  readonly tabs: ReadonlyArray<TabDescriptor>
  readonly draggingId: string | null
}

function tabPanelId(tabId: string): string {
  return `${tabId}-panel`
}

export function createTabs(opts: TabsOptions): TabsController {
  const activationMode = opts.activationMode ?? 'automatic'
  const orientation = opts.orientation ?? 'horizontal'

  let tabs: ReadonlyArray<TabDescriptor> = opts.tabs
  let activeId: string | null = opts.defaultActiveId ?? null
  let draggingId: string | null = null
  let dragOverId: string | null = null

  // Anchor active to first enabled if no defaultActiveId.
  if (activeId === null) {
    for (const t of tabs) {
      if (t.disabled !== true) {
        activeId = t.id
        break
      }
    }
  }

  const rover: RovingTabindexController = createRovingTabindex({
    orientation,
    items: tabs.map((t) => ({ id: t.id, disabled: t.disabled, text: t.label })),
    defaultActiveId: activeId ?? undefined,
    activateOnFocus: activationMode === 'automatic',
    onActiveChange: (id) => {
      if (activationMode === 'automatic' && id !== null) {
        activate(id)
      }
    },
  })

  const listeners = new Set<(snapshot: TabsSnapshot) => void>()

  function emit(): void {
    const snap: TabsSnapshot = Object.freeze({
      activeId,
      tabs,
      draggingId,
    })
    for (const l of listeners) l(snap)
  }

  function activate(id: string): void {
    const idx = tabs.findIndex((t) => t.id === id)
    if (idx < 0) return
    const tab = tabs[idx]!
    if (tab.disabled === true) return
    if (activeId === id) return
    activeId = id
    if (opts.onActiveChange !== undefined) opts.onActiveChange(id)
    emit()
  }

  function close(id: string): void {
    const idx = tabs.findIndex((t) => t.id === id)
    if (idx < 0) return
    const wasActive = activeId === id
    const next = tabs.filter((t) => t.id !== id)
    tabs = Object.freeze(next)
    rover.setItems(
      tabs.map((t) => ({ id: t.id, disabled: t.disabled, text: t.label })),
    )
    if (wasActive) {
      // Pick neighbor: previous if any, else next, else null.
      let neighborId: string | null = null
      for (let j = idx - 1; j >= 0; j -= 1) {
        if (next[j] !== undefined && next[j]!.disabled !== true) {
          neighborId = next[j]!.id
          break
        }
      }
      if (neighborId === null) {
        for (let j = idx; j < next.length; j += 1) {
          if (next[j] !== undefined && next[j]!.disabled !== true) {
            neighborId = next[j]!.id
            break
          }
        }
      }
      activeId = neighborId
      if (neighborId !== null && opts.onActiveChange !== undefined) {
        opts.onActiveChange(neighborId)
      }
    }
    if (opts.onClose !== undefined) opts.onClose(id)
    emit()
  }

  function reorder(ids: ReadonlyArray<string>): void {
    if (ids.length !== tabs.length) return
    const map = new Map(tabs.map((t) => [t.id, t]))
    const next: TabDescriptor[] = []
    for (const id of ids) {
      const t = map.get(id)
      if (t === undefined) return
      next.push(t)
    }
    tabs = Object.freeze(next)
    rover.setItems(
      tabs.map((t) => ({ id: t.id, disabled: t.disabled, text: t.label })),
    )
    if (opts.onReorder !== undefined) opts.onReorder(ids)
    emit()
  }

  function handleListKeyDown(e: TabsKeyEvent): void {
    // Manual activation: Enter / Space activates focused tab.
    if (
      activationMode === 'manual' &&
      (e.key === 'Enter' || e.key === ' ') &&
      rover.activeId !== null
    ) {
      e.preventDefault()
      activate(rover.activeId)
      return
    }
    // Delete or Mod+W closes focused closeable tab.
    if (
      (e.key === 'Delete' || (e.key === 'w' && (e.metaKey === true || e.ctrlKey === true))) &&
      rover.activeId !== null
    ) {
      const target = tabs.find((t) => t.id === rover.activeId)
      if (target !== undefined && target.closeable === true) {
        e.preventDefault()
        close(target.id)
        return
      }
    }
    // Forward to rover for arrow/Home/End/typeahead.
    const adapted: RovingKeyEvent = {
      key: e.key,
      shiftKey: e.shiftKey,
      metaKey: e.metaKey,
      ctrlKey: e.ctrlKey,
      altKey: e.altKey,
      preventDefault: () => e.preventDefault(),
    }
    rover.handleKeyDown(adapted)
  }

  return {
    get activeId() {
      return activeId
    },
    get tabs() {
      return tabs
    },
    get draggingId() {
      return draggingId
    },

    setTabs(nextTabs: ReadonlyArray<TabDescriptor>): void {
      tabs = Object.freeze([...nextTabs])
      rover.setItems(
        tabs.map((t) => ({ id: t.id, disabled: t.disabled, text: t.label })),
      )
      if (activeId !== null && tabs.findIndex((t) => t.id === activeId) < 0) {
        // Active tab gone — pick first enabled.
        let neighborId: string | null = null
        for (const t of tabs) {
          if (t.disabled !== true) {
            neighborId = t.id
            break
          }
        }
        activeId = neighborId
        if (neighborId !== null && opts.onActiveChange !== undefined) {
          opts.onActiveChange(neighborId)
        }
      }
      emit()
    },

    activate,
    close,
    reorder,

    getTabListProps(): TabListProps {
      return Object.freeze({
        role: 'tablist' as const,
        'aria-orientation': orientation,
        tabIndex: -1 as const,
        onKeyDown: handleListKeyDown,
      })
    },

    getTabProps(id: string): TabProps {
      const tab = tabs.find((t) => t.id === id)
      const isActive = activeId === id
      const isDis = tab?.disabled === true
      const props: TabProps = {
        id,
        role: 'tab' as const,
        'aria-selected': isActive,
        'aria-controls': tabPanelId(id),
        tabIndex: isActive ? 0 : -1,
        'data-active': isActive ? '' : undefined,
        onClick: () => activate(id),
      }
      if (isDis) {
        return Object.freeze({ ...props, 'aria-disabled': true as const })
      }
      return Object.freeze(props)
    },

    getTabPanelProps(id: string): TabPanelProps {
      return Object.freeze({
        id: tabPanelId(id),
        role: 'tabpanel' as const,
        'aria-labelledby': id,
        tabIndex: 0 as const,
        hidden: activeId !== id,
      })
    },

    getCloseButtonProps(id: string): CloseButtonProps {
      const tab = tabs.find((t) => t.id === id)
      const label = tab !== undefined ? `Close ${tab.label}` : 'Close'
      return Object.freeze({
        type: 'button' as const,
        'aria-label': label,
        tabIndex: -1 as const,
        onClick: () => close(id),
      })
    },

    handleDragStart(id: string): void {
      const tab = tabs.find((t) => t.id === id)
      if (tab === undefined || tab.pinned === true) return
      draggingId = id
      dragOverId = null
      emit()
    },

    handleDragOver(targetId: string): void {
      if (draggingId === null || draggingId === targetId) return
      const target = tabs.find((t) => t.id === targetId)
      if (target === undefined || target.pinned === true) return
      dragOverId = targetId
    },

    handleDragEnd(): void {
      if (draggingId === null) {
        emit()
        return
      }
      if (dragOverId !== null && dragOverId !== draggingId) {
        const newOrder: string[] = []
        for (const t of tabs) {
          if (t.id === draggingId) continue
          if (t.id === dragOverId) {
            newOrder.push(draggingId)
          }
          newOrder.push(t.id)
        }
        // If the over target was the last position, the dragged item
        // wasn't appended; ensure it's present.
        if (newOrder.indexOf(draggingId) === -1) newOrder.push(draggingId)
        const map = new Map(tabs.map((t) => [t.id, t]))
        const reordered: TabDescriptor[] = newOrder
          .map((id) => map.get(id))
          .filter((t): t is TabDescriptor => t !== undefined)
        tabs = Object.freeze(reordered)
        rover.setItems(
          tabs.map((t) => ({ id: t.id, disabled: t.disabled, text: t.label })),
        )
        if (opts.onReorder !== undefined) opts.onReorder(newOrder)
      }
      draggingId = null
      dragOverId = null
      emit()
    },

    subscribe(listener: (snapshot: TabsSnapshot) => void): () => void {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },
  }
}
