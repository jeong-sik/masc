/**
 * Menu — framework-agnostic menu / context-menu / submenu primitive
 * (RFC 0005). Composes RovingTabindex (RFC 0003) for menuitem
 * keyboard navigation, IdGenerator (RFC 0001) for aria-controls
 * linkage, and is designed to mount inside PortalManager 'dropdown'
 * layer (RFC 0001) — the manager itself is consumer-side concern.
 *
 * MVP scope (RFC 0005 §3, §4, §5, §7):
 *   - Action menu, submenu, context menu (createContextMenu wrapper)
 *   - Trigger: aria-haspopup=menu + aria-expanded + aria-controls,
 *     keyboard open via Enter/Space/ArrowDown (focus first item) and
 *     ArrowUp (focus last item)
 *   - Menu items: role=menuitem, aria-disabled, aria-keyshortcuts,
 *     data-active rover hook
 *   - Separator items: role=separator with no rover stop
 *   - Submenu open/close delays (default 200/300 ms)
 *   - Submenus = separate createMenu instances chained via openPath
 *     snapshot; ArrowRight/ArrowLeft navigate the chain
 *   - Esc closes current level (deepest first); propagates up
 *
 * Out of scope (RFC 0005 §11, §6):
 *   - Menu chrome tokens (Stage 1.4 follow-up — already merged via
 *     #11965)
 *   - Hover-tunnel mouse path (Amazon mega-menu pattern); 200/300 ms
 *     delays approximate the effect
 *   - Global keyboard shortcut REGISTRATION — manager exposes
 *     aria-keyshortcuts but does not bind global keys
 */

import {
  createRovingTabindex,
  type RovingTabindexController,
  type RovingKeyEvent,
} from './roving-tabindex'

export type MenuPlacement =
  | 'bottom-start'
  | 'bottom-end'
  | 'top-start'
  | 'top-end'
  | 'right-start'
  | 'right-end'
  | 'left-start'
  | 'left-end'

export interface MenuItemDescriptor {
  readonly id: string
  readonly label: string
  readonly disabled?: boolean
  readonly shortcut?: string
  readonly items?: ReadonlyArray<MenuItemDescriptor>
  readonly type?: 'item' | 'separator'
}

export interface MenuOptions {
  items: ReadonlyArray<MenuItemDescriptor>
  placement?: MenuPlacement
  orientation?: 'vertical' | 'horizontal'
  loop?: boolean
  submenuOpenDelay?: number
  submenuCloseDelay?: number
  /** Stable id seed; consumer typically passes useId() result. */
  id: string
  onSelect?: (itemId: string, path: ReadonlyArray<string>) => void
  onOpenChange?: (open: boolean) => void
}

export interface MenuKeyEvent {
  readonly key: string
  readonly metaKey?: boolean
  readonly ctrlKey?: boolean
  readonly shiftKey?: boolean
  readonly altKey?: boolean
  preventDefault(): void
}

export interface MenuTriggerProps {
  readonly 'aria-haspopup': 'menu'
  readonly 'aria-expanded': boolean
  readonly 'aria-controls': string
  readonly onClick: () => void
  readonly onKeyDown: (e: MenuKeyEvent) => void
}

export interface MenuProps {
  readonly id: string
  readonly role: 'menu'
  readonly 'aria-orientation': 'vertical' | 'horizontal'
  readonly tabIndex: -1
  readonly onKeyDown: (e: MenuKeyEvent) => void
}

export interface MenuItemProps {
  readonly id: string
  readonly role: 'menuitem' | 'separator'
  readonly tabIndex: 0 | -1
  readonly 'aria-disabled'?: true
  readonly 'aria-haspopup'?: 'menu'
  readonly 'aria-expanded'?: boolean
  readonly 'aria-keyshortcuts'?: string
  readonly 'data-active': '' | undefined
  readonly onClick: () => void
  readonly onMouseEnter: () => void
  readonly onMouseLeave: () => void
}

export interface MenuSnapshot {
  readonly isOpen: boolean
  readonly activeId: string | null
  readonly openPath: ReadonlyArray<string>
}

export interface MenuController {
  readonly isOpen: boolean
  readonly activeId: string | null

  open(): void
  close(): void
  toggle(): void

  focus(itemId: string): void
  select(itemId: string): void

  getTriggerProps(): MenuTriggerProps
  getMenuProps(): MenuProps
  getItemProps(itemId: string): MenuItemProps

  subscribe(listener: (snapshot: MenuSnapshot) => void): () => void

  /** Internal: parent invokes this when its trigger initiates a chain
   *  open — so child can open without redundant trigger click. */
  _openImmediate(): void
  /** Internal: id of the parent item this menu is attached to (for
   *  submenus). null for root menus. */
  readonly _parentItemId: string | null
}

const DEFAULT_OPEN_DELAY = 200
const DEFAULT_CLOSE_DELAY = 300

interface InternalMenuOptions extends MenuOptions {
  parentItemId?: string | null
  onChainSelect?: (path: ReadonlyArray<string>) => void
}

function createMenuInternal(opts: InternalMenuOptions): MenuController {
  const orientation = opts.orientation ?? 'vertical'
  const loop = opts.loop ?? true
  const openDelay = opts.submenuOpenDelay ?? DEFAULT_OPEN_DELAY
  const closeDelay = opts.submenuCloseDelay ?? DEFAULT_CLOSE_DELAY

  let isOpen = false
  let openSubmenuId: string | null = null
  let openTimer: ReturnType<typeof setTimeout> | null = null
  let closeTimer: ReturnType<typeof setTimeout> | null = null

  const submenus = new Map<string, MenuController>()
  // Lazily build child menus for items that have nested items.
  for (const item of opts.items) {
    if (item.items !== undefined && item.items.length > 0) {
      const childId = `${opts.id}-sub-${item.id}`
      const child: MenuController = createMenuInternal({
        id: childId,
        items: item.items,
        placement: 'right-start',
        orientation: 'vertical',
        loop,
        submenuOpenDelay: openDelay,
        submenuCloseDelay: closeDelay,
        onSelect: opts.onSelect,
        parentItemId: item.id,
        onChainSelect: opts.onChainSelect,
      })
      submenus.set(item.id, child)
    }
  }

  const rover: RovingTabindexController = createRovingTabindex({
    orientation,
    loop,
    items: opts.items
      .filter((i) => i.type !== 'separator')
      .map((i) => ({ id: i.id, disabled: i.disabled, text: i.label })),
  })

  const listeners = new Set<(s: MenuSnapshot) => void>()

  function snapshot(): MenuSnapshot {
    const path: string[] = []
    if (openSubmenuId !== null) path.push(openSubmenuId)
    return Object.freeze({
      isOpen,
      activeId: rover.activeId,
      openPath: Object.freeze(path),
    })
  }

  function emit(): void {
    const snap = snapshot()
    for (const l of listeners) l(snap)
  }

  function clearOpenTimer(): void {
    if (openTimer !== null) {
      clearTimeout(openTimer)
      openTimer = null
    }
  }
  function clearCloseTimer(): void {
    if (closeTimer !== null) {
      clearTimeout(closeTimer)
      closeTimer = null
    }
  }

  function openSubmenu(itemId: string): void {
    if (openSubmenuId === itemId) return
    if (openSubmenuId !== null) {
      submenus.get(openSubmenuId)?.close()
    }
    const child = submenus.get(itemId)
    if (child === undefined) return
    child._openImmediate()
    openSubmenuId = itemId
    emit()
  }

  function closeSubmenu(): void {
    if (openSubmenuId === null) return
    submenus.get(openSubmenuId)?.close()
    openSubmenuId = null
    emit()
  }

  function setOpen(next: boolean): void {
    if (isOpen === next) return
    isOpen = next
    if (!next) {
      // Cascade: close any open child.
      closeSubmenu()
      clearOpenTimer()
      clearCloseTimer()
    }
    if (opts.onOpenChange !== undefined) opts.onOpenChange(next)
    emit()
  }

  function selectImpl(itemId: string): void {
    const item = opts.items.find((i) => i.id === itemId)
    if (item === undefined || item.disabled === true || item.type === 'separator')
      return
    if (item.items !== undefined && item.items.length > 0) {
      openSubmenu(itemId)
      return
    }
    const path = [...(opts.parentItemId !== null && opts.parentItemId !== undefined
      ? [opts.parentItemId]
      : []), itemId]
    if (opts.onSelect !== undefined) opts.onSelect(itemId, path)
    if (opts.onChainSelect !== undefined) opts.onChainSelect(path)
    setOpen(false)
  }

  function handleTriggerKeyDown(e: MenuKeyEvent): void {
    if (e.key === 'Enter' || e.key === ' ' || e.key === 'ArrowDown') {
      e.preventDefault()
      setOpen(true)
      rover.first()
      return
    }
    if (e.key === 'ArrowUp') {
      e.preventDefault()
      setOpen(true)
      rover.last()
      return
    }
  }

  function handleMenuKeyDown(e: MenuKeyEvent): void {
    if (!isOpen) return
    if (e.key === 'Escape') {
      e.preventDefault()
      if (openSubmenuId !== null) {
        closeSubmenu()
        return
      }
      setOpen(false)
      return
    }
    if (e.key === 'ArrowRight') {
      // Open submenu if the focused item has children.
      const focusedId = rover.activeId
      if (focusedId !== null) {
        const child = submenus.get(focusedId)
        if (child !== undefined) {
          e.preventDefault()
          openSubmenu(focusedId)
          return
        }
      }
      // Otherwise no-op for vertical menu.
      return
    }
    if (e.key === 'ArrowLeft') {
      // Close submenu OR (if root) close menu.
      if (openSubmenuId !== null) {
        e.preventDefault()
        closeSubmenu()
        return
      }
      if (opts.parentItemId !== null && opts.parentItemId !== undefined) {
        e.preventDefault()
        setOpen(false)
        return
      }
      return
    }
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault()
      if (rover.activeId !== null) selectImpl(rover.activeId)
      return
    }
    // Forward to rover.
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
    get isOpen() {
      return isOpen
    },
    get activeId() {
      return rover.activeId
    },
    get _parentItemId() {
      return opts.parentItemId ?? null
    },

    open(): void {
      setOpen(true)
      rover.first()
    },

    close(): void {
      setOpen(false)
    },

    toggle(): void {
      if (isOpen) setOpen(false)
      else this.open()
    },

    _openImmediate(): void {
      setOpen(true)
      rover.first()
    },

    focus(itemId: string): void {
      rover.setActive(itemId)
    },

    select(itemId: string): void {
      selectImpl(itemId)
    },

    getTriggerProps(): MenuTriggerProps {
      return Object.freeze({
        'aria-haspopup': 'menu' as const,
        'aria-expanded': isOpen,
        'aria-controls': opts.id,
        onClick: () => this.toggle(),
        onKeyDown: handleTriggerKeyDown,
      })
    },

    getMenuProps(): MenuProps {
      return Object.freeze({
        id: opts.id,
        role: 'menu' as const,
        'aria-orientation': orientation,
        tabIndex: -1 as const,
        onKeyDown: handleMenuKeyDown,
      })
    },

    getItemProps(itemId: string): MenuItemProps {
      const item = opts.items.find((i) => i.id === itemId)
      if (item === undefined) {
        return Object.freeze({
          id: itemId,
          role: 'menuitem' as const,
          tabIndex: -1 as const,
          'data-active': undefined,
          onClick: () => {},
          onMouseEnter: () => {},
          onMouseLeave: () => {},
        })
      }
      if (item.type === 'separator') {
        return Object.freeze({
          id: itemId,
          role: 'separator' as const,
          tabIndex: -1 as const,
          'data-active': undefined,
          onClick: () => {},
          onMouseEnter: () => {},
          onMouseLeave: () => {},
        })
      }
      const isActive = rover.activeId === itemId
      const isDis = item.disabled === true
      const hasSub = item.items !== undefined && item.items.length > 0
      const props: MenuItemProps = {
        id: itemId,
        role: 'menuitem' as const,
        tabIndex: isActive ? 0 : -1,
        'aria-disabled': isDis ? (true as const) : undefined,
        'aria-haspopup': hasSub ? ('menu' as const) : undefined,
        'aria-expanded': hasSub ? openSubmenuId === itemId : undefined,
        'aria-keyshortcuts': item.shortcut,
        'data-active': isActive ? '' : undefined,
        onClick: () => {
          if (isDis) return
          selectImpl(itemId)
        },
        onMouseEnter: () => {
          if (isDis) return
          rover.setActive(itemId)
          if (hasSub) {
            clearCloseTimer()
            clearOpenTimer()
            openTimer = setTimeout(() => {
              openTimer = null
              openSubmenu(itemId)
            }, openDelay)
          } else if (openSubmenuId !== null) {
            // Hovering a sibling without children — start close timer.
            clearCloseTimer()
            closeTimer = setTimeout(() => {
              closeTimer = null
              closeSubmenu()
            }, closeDelay)
          }
        },
        onMouseLeave: () => {
          if (openTimer !== null) clearOpenTimer()
        },
      }
      return Object.freeze(props)
    },

    subscribe(listener: (s: MenuSnapshot) => void): () => void {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },
  }
}

export function createMenu(opts: MenuOptions): MenuController {
  return createMenuInternal({ ...opts, parentItemId: null })
}

// Context menu wrapper — adds openAt(coords) + viewport flip awareness.

export interface ContextMenuOptions extends MenuOptions {
  viewport?: { readonly width: number; readonly height: number }
}

export interface ContextMenuController extends MenuController {
  openAt(coords: { x: number; y: number }): void
  /** Last-set position; null when never opened or after close. */
  readonly position: { readonly x: number; readonly y: number } | null
  /** Resolved placement after viewport flip. */
  readonly resolvedPlacement: MenuPlacement
}

export function createContextMenu(opts: ContextMenuOptions): ContextMenuController {
  const inner = createMenu(opts)
  let position: { x: number; y: number } | null = null
  let resolvedPlacement: MenuPlacement = opts.placement ?? 'bottom-start'

  function getViewport(): { width: number; height: number } {
    if (opts.viewport !== undefined) return opts.viewport
    if (typeof globalThis.window !== 'undefined') {
      return {
        width: globalThis.window.innerWidth,
        height: globalThis.window.innerHeight,
      }
    }
    return { width: 1024, height: 768 }
  }

  // Cannot spread `inner` because getters would be evaluated to static
  // values at spread time, freezing isOpen / activeId. Forward each
  // member explicitly so the getters stay live against `inner`'s state.
  const cm: ContextMenuController = {
    get isOpen() {
      return inner.isOpen
    },
    get activeId() {
      return inner.activeId
    },
    get _parentItemId() {
      return inner._parentItemId
    },
    get position() {
      return position
    },
    get resolvedPlacement() {
      return resolvedPlacement
    },
    open: () => inner.open(),
    close: () => inner.close(),
    toggle: () => inner.toggle(),
    _openImmediate: () => inner._openImmediate(),
    focus: (id: string) => inner.focus(id),
    select: (id: string) => inner.select(id),
    getTriggerProps: () => inner.getTriggerProps(),
    getMenuProps: () => inner.getMenuProps(),
    getItemProps: (id: string) => inner.getItemProps(id),
    subscribe: (listener) => inner.subscribe(listener),
    openAt(coords: { x: number; y: number }): void {
      const vp = getViewport()
      position = { ...coords }
      const rightHalf = coords.x > vp.width / 2
      const bottomHalf = coords.y > vp.height / 2
      if (rightHalf && bottomHalf) resolvedPlacement = 'top-end'
      else if (rightHalf) resolvedPlacement = 'bottom-end'
      else if (bottomHalf) resolvedPlacement = 'top-start'
      else resolvedPlacement = 'bottom-start'
      inner.open()
    },
  }
  return cm
}
