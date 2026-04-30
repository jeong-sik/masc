// RadioGroup — radiogroup/radio primitive
// Kimi sec06 ARIA pattern: radiogroup. Arrow keys move focus/selection;
// Space selects focused item.

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { createContext } from 'preact'
import { useCallback, useContext, useRef, useState } from 'preact/hooks'

interface RadioCtx {
  name: string
  value: string
  onChange: (v: string) => void
}

const Ctx = createContext<RadioCtx | null>(null)

function useCtx() {
  const c = useContext(Ctx)
  if (!c) throw new Error('Radio compound components must be inside <RadioGroup>')
  return c
}

/* ─── RadioGroup root ─── */
interface RadioGroupProps {
  name: string
  value?: string
  defaultValue?: string
  onValueChange?: (value: string) => void
  children: ComponentChildren
  class?: string
}

export function RadioGroup({
  name,
  value: controlled,
  defaultValue,
  onValueChange,
  children,
  class: cx,
}: RadioGroupProps) {
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

  const Provider = Ctx.Provider
  return html`
    <div role="radiogroup" aria-label=${name} class=${cx ?? ''}>
      <${Provider} value=${{ name, value, onChange }}>${children}<//>
    </div>
  `
}

/* ─── Radio item ─── */
interface RadioProps {
  value: string
  children: ComponentChildren
  class?: string
}

export function Radio({ value, children, class: cx }: RadioProps) {
  const { value: selected, onChange } = useCtx()
  const checked = selected === value
  const ref = useRef<HTMLDivElement>(null)

  const onKeyDown = (e: KeyboardEvent) => {
    const group = ref.current?.closest('[role="radiogroup"]') as HTMLElement | null
    if (!group) return
    const radios = Array.from(group.querySelectorAll<HTMLElement>('[role="radio"]'))
    const idx = radios.findIndex((r) => r === ref.current)
    if (idx === -1) return

    let nextIdx = -1
    if (e.key === 'ArrowDown' || e.key === 'ArrowRight')
      nextIdx = (idx + 1) % radios.length
    else if (e.key === 'ArrowUp' || e.key === 'ArrowLeft')
      nextIdx = (idx - 1 + radios.length) % radios.length

    if (nextIdx !== -1) {
      e.preventDefault()
      const next = radios[nextIdx]
      next.focus()
      next.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    } else if (e.key === ' ' || e.key === 'Spacebar') {
      e.preventDefault()
      onChange(value)
    }
  }

  return html`
    <div
      ref=${ref}
      role="radio"
      aria-checked=${checked}
      tabindex=${checked ? 0 : -1}
      class=${cx ?? ''}
      onClick=${() => onChange(value)}
      onKeyDown=${onKeyDown}
    >
      ${children}
    </div>
  `
}
