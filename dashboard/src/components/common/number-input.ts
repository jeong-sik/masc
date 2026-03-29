import { html } from 'htm/preact'

const INPUT_BASE = 'w-full rounded-lg bg-[var(--white-4)] border border-[var(--card-border)] text-[var(--text-body)] placeholder:text-[var(--text-muted)] transition-colors focus-visible:outline-none focus-visible:border-[rgba(71,184,255,0.5)] focus-visible:ring-1 focus-visible:ring-[rgba(71,184,255,0.35)]'

interface NumberInputProps {
  value?: number | string
  placeholder?: string
  disabled?: boolean
  class?: string
  step?: number | 'any'
  min?: number
  max?: number
  onInput?: (value: number) => void
}

export function NumberInput({ value, placeholder, disabled, class: cx, step, min, max, onInput }: NumberInputProps) {
  const handleInput = (e: Event) => {
    const raw = (e.target as HTMLInputElement).value
    if (raw === '') { onInput?.(undefined as unknown as number); return }
    const num = Number(raw)
    if (!Number.isNaN(num)) onInput?.(num)
  }
  return html`
    <input type="number" class="${INPUT_BASE} px-3 py-2 text-[13px] ${cx ?? ''}" value=${value}
      placeholder=${placeholder} disabled=${disabled} step=${step} min=${min} max=${max} onInput=${handleInput} />
  `
}
