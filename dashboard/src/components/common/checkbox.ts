import { html } from 'htm/preact'

const CHECKBOX_BASE = 'w-4 h-4 rounded border border-[var(--card-border)] bg-[var(--white-4)] cursor-pointer transition-colors hover:bg-[var(--white-8)] hover:border-[var(--white-20)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[rgba(71,184,255,0.45)] focus-visible:ring-offset-2 focus-visible:ring-offset-[var(--bg-1)] accent-[var(--accent)]'

interface CheckboxProps {
  checked?: boolean
  disabled?: boolean
  class?: string
  onChange?: (checked: boolean) => void
}

export function Checkbox({ checked, disabled, class: cx, onChange }: CheckboxProps) {
  const handleChange = (e: Event) => { onChange?.((e.target as HTMLInputElement).checked) }
  return html`<input type="checkbox" class="${CHECKBOX_BASE} ${cx ?? ''}" checked=${checked} disabled=${disabled} onChange=${handleChange} />`
}
