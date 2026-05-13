// Tabs — tablist/tab/tabpanel primitive
// Kimi sec06 ARIA pattern: tablist. Keyboard arrows cycle tabs;
// Home/End jump to first/last.

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { createContext } from 'preact'
import { useCallback, useContext, useId, useRef, useState } from 'preact/hooks'
import { ringFocusClasses } from './ring'

interface TabsCtx {
  value: string
  onChange: (v: string) => void
  baseId: string
}

const Ctx = createContext<TabsCtx | null>(null)

const TABLIST_DEFAULT_CLASS =
  'inline-flex items-center gap-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] p-0.5'

const TAB_DEFAULT_CLASS = [
  'relative inline-flex items-center justify-center rounded-[var(--r-0)] border border-transparent px-2.5 py-1',
  'text-2xs font-semibold uppercase tracking-wider text-[var(--color-fg-muted)]',
  'transition-colors duration-[var(--t-fast)]',
  'hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-primary)]',
  'aria-selected:bg-[var(--color-state-active-bg)]',
  'aria-selected:border-[var(--color-state-active-border)]',
  'aria-selected:text-[var(--color-state-active-fg)]',
  'aria-selected:shadow-[inset_0_-1px_0_var(--color-tab-indicator)]',
  ringFocusClasses({ tone: 'accent-medium', width: 2 }),
].join(' ')

function useCtx() {
  const c = useContext(Ctx)
  if (!c) throw new Error('Tabs compound components must be inside <Tabs>')
  return c
}

/* ─── Tabs root ─── */
interface TabsProps {
  defaultValue?: string
  value?: string
  onValueChange?: (value: string) => void
  children: ComponentChildren
  class?: string
}

export function Tabs({
  defaultValue,
  value: controlled,
  onValueChange,
  children,
  class: cx,
}: TabsProps) {
  const [uncontrolled, setUncontrolled] = useState(defaultValue ?? '')
  const isControlled = controlled !== undefined
  const value = isControlled ? controlled! : uncontrolled
  const onChange = useCallback(
    (v: string) => {
      if (!isControlled) setUncontrolled(v)
      onValueChange?.(v)
    },
    [isControlled, onValueChange],
  )
  const baseId = useId()

  const Provider = Ctx.Provider
  return html`
    <div class=${cx ?? ''}><${Provider} value=${{ value, onChange, baseId }}>${children}<//></div>
  `
}

/* ─── TabList ─── */
interface TabListProps {
  children: ComponentChildren
  class?: string
}

export function TabList({ children, class: cx }: TabListProps) {
  return html`<div role="tablist" class=${cx ?? TABLIST_DEFAULT_CLASS}>${children}</div>`
}

/* ─── Tab ─── */
interface TabProps {
  value: string
  children: ComponentChildren
  class?: string
}

export function Tab({ value, children, class: cx }: TabProps) {
  const { value: selected, onChange, baseId } = useCtx()
  const active = selected === value
  const tabId = `${baseId}-tab-${value}`
  const panelId = `${baseId}-panel-${value}`
  const ref = useRef<HTMLButtonElement>(null)

  const onKeyDown = (e: KeyboardEvent) => {
    const list = ref.current?.closest('[role="tablist"]') as HTMLElement | null
    if (!list) return
    const tabs = Array.from(list.querySelectorAll<HTMLElement>('[role="tab"]'))
    const idx = tabs.findIndex((t) => t === ref.current)
    if (idx === -1) return

    let nextIdx = -1
    if (e.key === 'ArrowRight') nextIdx = (idx + 1) % tabs.length
    else if (e.key === 'ArrowLeft') nextIdx = (idx - 1 + tabs.length) % tabs.length
    else if (e.key === 'Home') nextIdx = 0
    else if (e.key === 'End') nextIdx = tabs.length - 1

    if (nextIdx !== -1) {
      e.preventDefault()
      const next = tabs[nextIdx] as HTMLButtonElement | undefined
      if (!next) return
      next.focus()
      next.click()
    }
  }

  return html`
    <button
      ref=${ref}
      role="tab"
      id=${tabId}
      aria-selected=${active}
      aria-controls=${panelId}
      tabindex=${active ? 0 : -1}
      class=${cx ?? TAB_DEFAULT_CLASS}
      onClick=${() => onChange(value)}
      onKeyDown=${onKeyDown}
    >
      ${children}
    </button>
  `
}

/* ─── TabPanel ─── */
interface TabPanelProps {
  value: string
  children: ComponentChildren
  class?: string
}

export function TabPanel({ value, children, class: cx }: TabPanelProps) {
  const { value: selected, baseId } = useCtx()
  const active = selected === value
  const tabId = `${baseId}-tab-${value}`
  const panelId = `${baseId}-panel-${value}`

  return html`
    <div
      role="tabpanel"
      id=${panelId}
      aria-labelledby=${tabId}
      hidden=${!active}
      class=${cx ?? ''}
    >
      ${active ? children : null}
    </div>
  `
}
