import { signal } from '@preact/signals'

export const ideReplayUntilMs = signal<number | null>(null)

export function setIdeReplayUntilMs(value: number | null): void {
  const next = value === null || !Number.isFinite(value) ? null : value
  if (ideReplayUntilMs.value === next) return
  ideReplayUntilMs.value = next
}
