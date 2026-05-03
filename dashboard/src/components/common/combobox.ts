// Combobox — ARIA 1.3 editable combobox with filtering
//
// Keyboard: ArrowDown/Up navigates options, Enter selects, Escape closes.
// Typeahead is implicit via the input field: typing filters the list.

import { html } from 'htm/preact'
import { useEffect, useId, useRef, useState } from 'preact/hooks'

export interface ComboboxOption {
  value: string
  label: string
}

interface ComboboxProps {
  options: ComboboxOption[]
  value?: string
  onChange?: (value: string) => void
  placeholder?: string
  testId?: string
  /** Accessible name for the combobox input. */
  'aria-label'?: string
}

const INPUT_CLS =
  'w-full rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] border border-[var(--color-border-default)] ' +
  'text-[var(--color-fg-primary)] px-3 py-2 text-sm transition-colors ' +
  'hover:bg-[var(--color-bg-hover)] focus-visible:bg-[var(--color-bg-page)] ' +
  'focus-visible:border-[var(--info-border)] outline-none'

const LISTBOX_CLS =
  'absolute z-50 top-full mt-1 left-0 w-full max-h-60 overflow-auto ' +
  'bg-[var(--dialog-panel-bg)] rounded-[var(--r-1)] border border-[var(--dialog-panel-border)] ' +
  'shadow-[var(--shadow-panel)] py-1'

const OPTION_BASE = 'px-3 py-2 text-sm cursor-pointer '

function optionCls(active: boolean): string {
  return active
    ? OPTION_BASE + 'bg-[var(--color-accent-fg)] text-[var(--color-bg-page)]'
    : OPTION_BASE + 'text-[var(--color-fg-primary)] hover:bg-[var(--color-bg-hover)]'
}

export function Combobox({
  options,
  value,
  onChange,
  placeholder,
  testId,
  'aria-label': ariaLabel,
}: ComboboxProps) {
  const id = useId()
  const listboxId = `${id}-listbox`
  const inputRef = useRef<HTMLInputElement>(null)
  const listboxRef = useRef<HTMLDivElement>(null)

  const [open, setOpen] = useState(false)
  const [inputValue, setInputValue] = useState(value ?? '')
  const [activeIndex, setActiveIndex] = useState(0)

  const filtered = options.filter((opt) =>
    opt.label.toLowerCase().includes(inputValue.toLowerCase()),
  )

  useEffect(() => {
    setActiveIndex(0)
  }, [inputValue])

  useEffect(() => {
    if (!open) return
    const onDocClick = (e: MouseEvent) => {
      const target = e.target as Node
      if (
        inputRef.current?.contains(target) ||
        listboxRef.current?.contains(target)
      ) {
        return
      }
      setOpen(false)
    }
    document.addEventListener('click', onDocClick, true)
    return () => document.removeEventListener('click', onDocClick, true)
  }, [open])

  const selectOption = (opt: ComboboxOption) => {
    setInputValue(opt.label)
    setOpen(false)
    onChange?.(opt.value)
  }

  const handleKeyDown = (e: KeyboardEvent) => {
    if (e.key === 'ArrowDown') {
      e.preventDefault()
      if (!open) {
        setOpen(true)
        setActiveIndex(0)
      } else {
        setActiveIndex((i) => Math.min(filtered.length - 1, i + 1))
      }
    } else if (e.key === 'ArrowUp') {
      e.preventDefault()
      if (open) {
        setActiveIndex((i) => Math.max(0, i - 1))
      }
    } else if (e.key === 'Enter') {
      e.preventDefault()
      if (open && filtered[activeIndex]) {
        selectOption(filtered[activeIndex])
      }
    } else if (e.key === 'Escape') {
      e.preventDefault()
      setOpen(false)
    } else if (e.key === 'Home' && open) {
      e.preventDefault()
      setActiveIndex(0)
    } else if (e.key === 'End' && open) {
      e.preventDefault()
      setActiveIndex(filtered.length - 1)
    }
  }

  const activeDescendant =
    open && filtered[activeIndex]
      ? `${id}-option-${activeIndex}`
      : undefined

  const listboxLabel = ariaLabel ? `${ariaLabel} options` : 'Options'

  return html`
    <div class="relative inline-block w-full">
      <input
        ref=${inputRef}
        type="text"
        role="combobox"
        aria-expanded=${open}
        aria-controls=${listboxId}
        aria-activedescendant=${activeDescendant}
        aria-label=${ariaLabel}
        data-testid=${testId}
        value=${inputValue}
        placeholder=${placeholder}
        class=${INPUT_CLS}
        onInput=${(e: Event) => {
          const val = (e.target as HTMLInputElement).value
          setInputValue(val)
          setOpen(true)
          onChange?.(val)
        }}
        onKeyDown=${handleKeyDown}
      />
      ${open && filtered.length > 0
        ? html`<div
            ref=${listboxRef}
            id=${listboxId}
            role="listbox"
            aria-label=${listboxLabel}
            class=${LISTBOX_CLS}
          >
            ${filtered.map(
              (opt, idx) => html`
                <div
                  id=${`${id}-option-${idx}`}
                  role="option"
                  aria-selected=${idx === activeIndex}
                  class=${optionCls(idx === activeIndex)}
                  onClick=${() => selectOption(opt)}
                >
                  ${opt.label}
                </div>
              `,
            )}
          </div>`
        : null}
    </div>
  `
}
