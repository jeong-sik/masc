// Toolbar — toolbar primitive with roving tabindex
// Kimi sec06 ARIA pattern: toolbar. Arrow keys move focus between items;
// Home/End jump to first/last. Only one item is tab-accessible at a time.

import { html } from 'htm/preact'
import type { ComponentChildren, FunctionComponent } from 'preact'
import { createContext } from 'preact'
import { useCallback, useContext, useEffect, useRef, useState } from 'preact/hooks'

interface ToolbarCtx {
  focusedIndex: number
  setFocusedIndex: (i: number) => void
  register: () => number
  unregister: (i: number) => void
}

const Ctx = createContext<ToolbarCtx | null>(null)

function useCtx() {
  const c = useContext(Ctx)
  if (!c) throw new Error('Toolbar compound components must be inside <Toolbar>')
  return c
}

let _id = 0

/* ─── Toolbar root ─── */
interface ToolbarProps {
  'aria-label': string
  orientation?: 'horizontal' | 'vertical'
  children: ComponentChildren
  class?: string
}

export function Toolbar({
  'aria-label': ariaLabel,
  orientation = 'horizontal',
  children,
  class: cx,
}: ToolbarProps) {
  const ref = useRef<HTMLDivElement>(null)
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

    if (orientation === 'horizontal') {
      if (e.key === 'ArrowRight') nextIdx = (idx + 1) % sortedItems.length
      else if (e.key === 'ArrowLeft') nextIdx = (idx - 1 + sortedItems.length) % sortedItems.length
    } else {
      if (e.key === 'ArrowDown') nextIdx = (idx + 1) % sortedItems.length
      else if (e.key === 'ArrowUp') nextIdx = (idx - 1 + sortedItems.length) % sortedItems.length
    }
    if (e.key === 'Home') nextIdx = 0
    else if (e.key === 'End') nextIdx = sortedItems.length - 1

    if (nextIdx !== -1) {
      e.preventDefault()
      const nextId = sortedItems[nextIdx]
      if (nextId === undefined) return
      setFocusedIndex(nextId)
    }
  }

  const Provider = Ctx.Provider
  return html`
    <div
      ref=${ref}
      role="toolbar"
      aria-label=${ariaLabel}
      aria-orientation=${orientation}
      class=${cx ?? ''}
      onKeyDown=${handleKeyDown}
    >
      <${Provider} value=${{ focusedIndex, setFocusedIndex, register, unregister }}
        >${children}
      <//>
    </div>
  `
}

/* ─── ToolbarButton ─── */
interface ToolbarButtonProps {
  children: ComponentChildren
  onClick?: (e: MouseEvent) => void
  disabled?: boolean
  class?: string
  'aria-pressed'?: boolean
  title?: string
}

export function ToolbarButton({
  children,
  onClick,
  disabled,
  class: cx,
  'aria-pressed': ariaPressed,
  title,
}: ToolbarButtonProps) {
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
      tabindex=${active ? 0 : -1}
      disabled=${disabled}
      aria-pressed=${ariaPressed}
      title=${title}
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

/* ─── ToolbarSeparator ─── */
interface ToolbarSeparatorProps {
  orientation?: 'horizontal' | 'vertical'
  class?: string
}

export const ToolbarSeparator: FunctionComponent<ToolbarSeparatorProps> = ({
  orientation = 'vertical',
  class: cx,
}) => {
  return html`
    <div
      role="separator"
      aria-orientation=${orientation}
      class=${
        'shrink-0 bg-[var(--color-border-default)] ' +
        (orientation === 'vertical' ? 'w-px h-4 mx-1' : 'h-px w-full my-1') +
        (cx ? ` ${cx}` : '')
      }
    />
  `
}
