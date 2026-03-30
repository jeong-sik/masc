import { html } from 'htm/preact'

const SELECT_BASE = 'w-full rounded-lg bg-[var(--white-4)] border border-[var(--card-border)] text-[var(--text-body)] transition-colors focus-visible:outline-none focus-visible:border-[rgba(71,184,255,0.5)] focus-visible:ring-1 focus-visible:ring-[rgba(71,184,255,0.35)] appearance-none cursor-pointer'

interface SelectOption { value: string; label: string }

interface SelectProps {
  value?: string
  options: Array<string | SelectOption>
  placeholder?: string
  disabled?: boolean
  class?: string
  onInput?: (value: string) => void
}

export function Select({ value, options, placeholder, disabled, class: cx, onInput }: SelectProps) {
  const handleChange = (e: Event) => { onInput?.((e.target as HTMLSelectElement).value) }
  const currentValue = value ?? ''
  return html`
    <select class="${SELECT_BASE} px-3 py-2 text-[13px] ${cx ?? ''}" value=${currentValue} disabled=${disabled} onChange=${handleChange}>
      ${placeholder ? html`<option value="" disabled hidden>${placeholder}</option>` : null}
      ${options.map(opt => {
        const v = typeof opt === 'string' ? opt : opt.value
        const label = typeof opt === 'string' ? opt : opt.label
        return html`<option value=${v}>${label}</option>`
      })}
    </select>
  `
}
