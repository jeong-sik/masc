// Menubar — ARIA menubar primitive
// Kimi sec06 ARIA pattern: menubar. ArrowRight/Left cycles items;
// Enter/Space executes; Home/End jumps to first/last.

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { createContext } from 'preact'
import { useCallback, useContext, useEffect, useRef, useState } from 'preact/hooks'

interface MenubarCtx {
  focusedIndex: number
  setFocusedIndex: (i: number) => void
  register: () => number
  unregister: (i: number) => void
}

const Ctx = createContext<MenubarCtx | null>(null)

function useCtx() {
  const c = useContext(Ctx)
  if (!c) throw new Error('Menubar compound components must be inside <Menubar>')
  return c
}

let _id = 0

/* ─── Menubar root ─── */
interface MenubarProps {
  children: ComponentChildren
  class?: string
  'aria-label': string
}

export function Menubar({ children, class: cx, 'aria-label': ariaLabel }: MenubarProps) {
  const [focusedIndex, setFocusedIndex] = useState(() => _id)
  const [items, setItems] = useState<Set<number>>(new Set())

  const register = useCallback(() => {
    const id = _id++
    setItems((prev) => new Set(prev).add(id))
    return id
  }, [])

  const unregister = useCallback((id: number) => {
    setItems((prev) => {
      const next = new Set(prev)
      next.delete(id)
      return next
    })
  }, [])

  const sortedItems = Array.from(items).sort((a, b) => a - b)

  const handleKeyDown = (e: KeyboardEvent) => {
    if (sortedItems.length === 0) return
    const currentIdx = sortedItems.indexOf(focusedIndex)
    const idx = currentIdx === -1 ? 0 : currentIdx
    let nextIdx = -1

    if (e.key === 'ArrowRight') nextIdx = (idx + 1) % sortedItems.length
    else if (e.key === 'ArrowLeft')
      nextIdx = (idx - 1 + sortedItems.length) % sortedItems.length
    else if (e.key === 'Home') nextIdx = 0
    else if (e.key === 'End') nextIdx = sortedItems.length - 1

    if (nextIdx !== -1) {
      e.preventDefault()
      const next = sortedItems[nextIdx]
      if (next !== undefined) setFocusedIndex(next)
    }
  }

  const Provider = Ctx.Provider
  return html`
    <div role="menubar" aria-label=${ariaLabel} class=${cx ?? ''} onKeyDown=${handleKeyDown}>
      <${Provider} value=${{ focusedIndex, setFocusedIndex, register, unregister }}
        >${children}
      <//>
    </div>
  `
}

/* ─── MenubarItem ─── */
interface MenubarItemProps {
  children: ComponentChildren
  onClick?: (e: MouseEvent) => void
  disabled?: boolean
  class?: string
}

export function MenubarItem({
  children,
  onClick,
  disabled,
  class: cx,
}: MenubarItemProps) {
  const { focusedIndex, setFocusedIndex, register, unregister } = useCtx()
  const [id] = useState(() => register())
  const ref = useRef<HTMLButtonElement>(null)
  const active = focusedIndex === id

  useEffect(() => {
    if (active) ref.current?.focus()
  }, [active])

  useEffect(() => () => unregister(id), [id, unregister])

  return html`
    <button
      ref=${ref}
      type="button"
      role="menuitem"
      tabindex=${active ? 0 : -1}
      disabled=${disabled}
      class=${cx ?? ''}
      onClick=${(e: MouseEvent) => {
        onClick?.(e)
        setFocusedIndex(id)
      }}
      onFocus=${() => setFocusedIndex(id)}
    >
      ${children}
    </button>
  `
}
