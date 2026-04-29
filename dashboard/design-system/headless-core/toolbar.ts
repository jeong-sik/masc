/**
 * Toolbar — framework-agnostic action-group primitive (RFC 0016).
 *
 * Composes RovingTabindex (RFC 0003) for arrow / Home / End / typeahead
 * navigation. Layers on toolbar-specific kinds: toggle (aria-pressed),
 * radio (aria-checked with group exclusivity), separator (skipped by
 * rover), and group-start / group-end markers for ARIA radiogroup
 * containers. Optional overflow split sends trailing items into a Menu
 * (RFC 0005) when container width is constrained.
 *
 * MVP scope (RFC 0016 §3, §4, §5, §6):
 *   - Six item kinds: button, toggle, radio, separator, group-start,
 *     group-end. Only button / toggle / radio participate in the rover.
 *   - Activation by Enter / Space:
 *       button → onItemActivate(id) + item.action()
 *       toggle → flip pressed; onToggle(id, nextPressed)
 *       radio  → mutually exclusive within radioGroup; onRadioSelect
 *   - Overflow split via setContainerSize + setItemWidth, or manual
 *     overflowAt index. setContainerSize is throttled to ~60 fps so
 *     ResizeObserver storms don't recompute O(N) per frame.
 *   - aria-keyshortcuts surfaces item.shortcut directly.
 *
 * Out of scope (deferred per RFC 0016 §10):
 *   - Atomic group-spanning across overflow boundary (caller bears it)
 *   - Vertical-orientation overflow (height-based; same logic, future)
 *   - jest-axe fixtures (test target, separate harness)
 */

import {
  createRovingTabindex,
  type RovingTabindexController,
  type RovingKeyEvent,
} from './roving-tabindex'

export type ToolbarItemKind =
  | 'button'
  | 'toggle'
  | 'radio'
  | 'separator'
  | 'group-start'
  | 'group-end'

export interface ToolbarItem {
  readonly id: string
  readonly kind: ToolbarItemKind
  readonly label: string
  readonly disabled?: boolean
  readonly pressed?: boolean
  readonly radioGroup?: string
  readonly checked?: boolean
  readonly groupLabel?: string
  readonly shortcut?: string
  readonly action?: () => void
}

export type ToolbarOrientation = 'horizontal' | 'vertical'

export interface ToolbarOptions {
  items: ReadonlyArray<ToolbarItem>
  ariaLabel: string
  orientation?: ToolbarOrientation
  containerSize?: number
  overflowAt?: number
  /** Throttle window in ms for setContainerSize emit coalescing. Default 16. */
  resizeThrottleMs?: number
  onItemActivate?: (id: string) => void
  onToggle?: (id: string, nextPressed: boolean) => void
  onRadioSelect?: (groupId: string, selectedId: string) => void
}

export interface ToolbarKeyEvent {
  readonly key: string
  readonly metaKey?: boolean
  readonly ctrlKey?: boolean
  readonly shiftKey?: boolean
  readonly altKey?: boolean
  preventDefault(): void
}

export interface ToolbarRootProps {
  readonly role: 'toolbar'
  readonly 'aria-label': string
  readonly 'aria-orientation': ToolbarOrientation
  readonly tabIndex: -1
  readonly onKeyDown: (e: ToolbarKeyEvent) => void
}

export interface ToolbarItemProps {
  readonly id: string
  readonly type?: 'button'
  readonly role?: 'separator'
  readonly 'aria-pressed'?: boolean
  readonly 'aria-checked'?: boolean
  readonly 'aria-disabled'?: true
  readonly 'aria-keyshortcuts'?: string
  readonly tabIndex: 0 | -1
  readonly 'data-active': '' | undefined
  readonly 'data-pressed'?: ''
  readonly 'data-checked'?: ''
  readonly onClick?: () => void
}

export interface ToolbarOverflowTriggerProps {
  readonly type: 'button'
  readonly 'aria-label': 'More actions'
  readonly 'aria-haspopup': 'menu'
  readonly 'aria-expanded': boolean
  readonly tabIndex: 0
  readonly onClick: () => void
}

export interface ToolbarSnapshot {
  readonly visibleItems: ReadonlyArray<ToolbarItem>
  readonly overflowItems: ReadonlyArray<ToolbarItem>
  readonly activeId: string | null
  readonly overflowMenuOpen: boolean
}

export interface ToolbarController {
  readonly visibleItems: ReadonlyArray<ToolbarItem>
  readonly overflowItems: ReadonlyArray<ToolbarItem>
  readonly hasOverflow: boolean
  readonly activeId: string | null
  readonly overflowMenuOpen: boolean
  readonly items: ReadonlyArray<ToolbarItem>

  setItems(items: ReadonlyArray<ToolbarItem>): void
  setContainerSize(px: number): void
  setItemWidth(id: string, px: number): void
  toggle(id: string): void
  selectRadio(id: string): void
  activate(id: string): void
  openOverflowMenu(): void
  closeOverflowMenu(): void

  getRootProps(): ToolbarRootProps
  getItemProps(id: string): ToolbarItemProps
  getOverflowMenuTriggerProps(): ToolbarOverflowTriggerProps

  subscribe(listener: (snapshot: ToolbarSnapshot) => void): () => void
}

function isRoveable(kind: ToolbarItemKind): boolean {
  return kind === 'button' || kind === 'toggle' || kind === 'radio'
}

function freezeItem(item: ToolbarItem): ToolbarItem {
  return Object.freeze({ ...item })
}

export function createToolbar(opts: ToolbarOptions): ToolbarController {
  const orientation: ToolbarOrientation = opts.orientation ?? 'horizontal'
  const throttleMs = opts.resizeThrottleMs ?? 16

  let items: ReadonlyArray<ToolbarItem> = Object.freeze(opts.items.map(freezeItem))
  let containerSize: number | null = opts.containerSize ?? null
  const itemWidths = new Map<string, number>()
  let overflowMenuOpen = false

  // Coalesce rapid setContainerSize calls to avoid O(N) ARIA recompute / emit
  // per ResizeObserver frame.
  let pendingResize = false
  let resizeTimer: ReturnType<typeof setTimeout> | null = null

  const rover: RovingTabindexController = createRovingTabindex({
    orientation: orientation === 'horizontal' ? 'horizontal' : 'vertical',
    items: roveableSubset(items),
    activateOnFocus: false,
  })

  const listeners = new Set<(snapshot: ToolbarSnapshot) => void>()

  function roveableSubset(
    arr: ReadonlyArray<ToolbarItem>,
  ): ReadonlyArray<{ id: string; disabled?: boolean; text?: string }> {
    return arr
      .filter((it) => isRoveable(it.kind))
      .map((it) => ({ id: it.id, disabled: it.disabled, text: it.label }))
  }

  function computeSplit(): {
    visible: ReadonlyArray<ToolbarItem>
    overflow: ReadonlyArray<ToolbarItem>
  } {
    if (typeof opts.overflowAt === 'number' && opts.overflowAt >= 0) {
      const cut = Math.min(opts.overflowAt, items.length)
      return {
        visible: items.slice(0, cut),
        overflow: items.slice(cut),
      }
    }
    if (containerSize === null) {
      return { visible: items, overflow: [] }
    }
    let cumulative = 0
    let cut = items.length
    for (let i = 0; i < items.length; i += 1) {
      const item = items[i]!
      const w = itemWidths.get(item.id) ?? 0
      if (cumulative + w > containerSize) {
        cut = i
        break
      }
      cumulative += w
    }
    return {
      visible: items.slice(0, cut),
      overflow: items.slice(cut),
    }
  }

  function snapshot(): ToolbarSnapshot {
    const { visible, overflow } = computeSplit()
    return Object.freeze({
      visibleItems: visible,
      overflowItems: overflow,
      activeId: rover.activeId,
      overflowMenuOpen,
    })
  }

  function emit(): void {
    const snap = snapshot()
    for (const l of listeners) l(snap)
  }

  function scheduleResizeEmit(): void {
    if (pendingResize) return
    pendingResize = true
    if (resizeTimer !== null) clearTimeout(resizeTimer)
    resizeTimer = setTimeout(() => {
      pendingResize = false
      resizeTimer = null
      emit()
    }, throttleMs)
  }

  function findItem(id: string): ToolbarItem | undefined {
    return items.find((it) => it.id === id)
  }

  function replaceItem(id: string, patch: Partial<ToolbarItem>): void {
    const next = items.map((it) =>
      it.id === id ? freezeItem({ ...it, ...patch }) : it,
    )
    items = Object.freeze(next)
    rover.setItems(roveableSubset(items))
  }

  function activate(id: string): void {
    const item = findItem(id)
    if (item === undefined || item.disabled === true) return
    if (!isRoveable(item.kind)) return
    if (item.kind === 'button') {
      if (opts.onItemActivate !== undefined) opts.onItemActivate(id)
      if (item.action !== undefined) item.action()
      return
    }
    if (item.kind === 'toggle') {
      const nextPressed = item.pressed !== true
      replaceItem(id, { pressed: nextPressed })
      if (opts.onToggle !== undefined) opts.onToggle(id, nextPressed)
      if (opts.onItemActivate !== undefined) opts.onItemActivate(id)
      if (item.action !== undefined) item.action()
      emit()
      return
    }
    if (item.kind === 'radio') {
      selectRadio(id)
      if (opts.onItemActivate !== undefined) opts.onItemActivate(id)
      if (item.action !== undefined) item.action()
    }
  }

  function selectRadio(id: string): void {
    const target = findItem(id)
    if (target === undefined || target.kind !== 'radio') return
    if (target.disabled === true) return
    const groupId = target.radioGroup
    if (groupId === undefined) return
    const next = items.map((it) => {
      if (it.kind !== 'radio' || it.radioGroup !== groupId) return it
      const checked = it.id === id
      if (it.checked === checked) return it
      return freezeItem({ ...it, checked })
    })
    items = Object.freeze(next)
    rover.setItems(roveableSubset(items))
    if (opts.onRadioSelect !== undefined) opts.onRadioSelect(groupId, id)
    emit()
  }

  function toggle(id: string): void {
    const item = findItem(id)
    if (item === undefined || item.kind !== 'toggle') return
    if (item.disabled === true) return
    const nextPressed = item.pressed !== true
    replaceItem(id, { pressed: nextPressed })
    if (opts.onToggle !== undefined) opts.onToggle(id, nextPressed)
    emit()
  }

  function handleKeyDown(e: ToolbarKeyEvent): void {
    // Enter / Space activates focused (without modifiers) — toolbar
    // owns this so Roving's typeahead doesn't intercept Space.
    if (
      (e.key === 'Enter' || e.key === ' ') &&
      e.metaKey !== true &&
      e.ctrlKey !== true &&
      e.altKey !== true &&
      rover.activeId !== null
    ) {
      e.preventDefault()
      activate(rover.activeId)
      return
    }
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
    get visibleItems() {
      return computeSplit().visible
    },
    get overflowItems() {
      return computeSplit().overflow
    },
    get hasOverflow() {
      return computeSplit().overflow.length > 0
    },
    get activeId() {
      return rover.activeId
    },
    get overflowMenuOpen() {
      return overflowMenuOpen
    },
    get items() {
      return items
    },

    setItems(nextItems: ReadonlyArray<ToolbarItem>): void {
      items = Object.freeze(nextItems.map(freezeItem))
      rover.setItems(roveableSubset(items))
      // Drop widths for removed ids; keep for remaining.
      const live = new Set(items.map((it) => it.id))
      for (const id of Array.from(itemWidths.keys())) {
        if (!live.has(id)) itemWidths.delete(id)
      }
      emit()
    },

    setContainerSize(px: number): void {
      containerSize = px
      scheduleResizeEmit()
    },

    setItemWidth(id: string, px: number): void {
      itemWidths.set(id, px)
      scheduleResizeEmit()
    },

    toggle,
    selectRadio,
    activate,

    openOverflowMenu(): void {
      if (overflowMenuOpen) return
      overflowMenuOpen = true
      emit()
    },

    closeOverflowMenu(): void {
      if (!overflowMenuOpen) return
      overflowMenuOpen = false
      emit()
    },

    getRootProps(): ToolbarRootProps {
      return Object.freeze({
        role: 'toolbar' as const,
        'aria-label': opts.ariaLabel,
        'aria-orientation': orientation,
        tabIndex: -1 as const,
        onKeyDown: handleKeyDown,
      })
    },

    getItemProps(id: string): ToolbarItemProps {
      const item = findItem(id)
      if (item === undefined) {
        return Object.freeze({
          id,
          tabIndex: -1 as const,
          'data-active': undefined,
        })
      }
      const isActive = rover.activeId === id
      const isDis = item.disabled === true
      const isRover = isRoveable(item.kind)

      if (item.kind === 'separator') {
        return Object.freeze({
          id,
          role: 'separator' as const,
          tabIndex: -1 as const,
          'data-active': undefined,
        })
      }
      if (item.kind === 'group-start' || item.kind === 'group-end') {
        return Object.freeze({
          id,
          tabIndex: -1 as const,
          'data-active': undefined,
        })
      }

      const togglePressed = item.kind === 'toggle' && item.pressed === true
      const radioChecked = item.kind === 'radio' && item.checked === true
      const props: ToolbarItemProps = {
        id,
        type: 'button' as const,
        tabIndex: isRover && isActive ? 0 : -1,
        'data-active': isRover && isActive ? '' : undefined,
        onClick: isDis ? undefined : () => activate(id),
        ...(isDis ? { 'aria-disabled': true as const } : {}),
        ...(item.shortcut !== undefined
          ? { 'aria-keyshortcuts': item.shortcut }
          : {}),
        ...(item.kind === 'toggle'
          ? {
              'aria-pressed': togglePressed,
              ...(togglePressed ? { 'data-pressed': '' as const } : {}),
            }
          : {}),
        ...(item.kind === 'radio'
          ? {
              'aria-checked': radioChecked,
              ...(radioChecked ? { 'data-checked': '' as const } : {}),
            }
          : {}),
      }
      return Object.freeze(props)
    },

    getOverflowMenuTriggerProps(): ToolbarOverflowTriggerProps {
      const self = this
      return Object.freeze({
        type: 'button' as const,
        'aria-label': 'More actions' as const,
        'aria-haspopup': 'menu' as const,
        'aria-expanded': overflowMenuOpen,
        tabIndex: 0 as const,
        onClick: () => {
          if (overflowMenuOpen) self.closeOverflowMenu()
          else self.openOverflowMenu()
        },
      })
    },

    subscribe(listener: (snap: ToolbarSnapshot) => void): () => void {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },
  }
}
