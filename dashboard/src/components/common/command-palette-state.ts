import { signal } from '@preact/signals'

export const commandPaletteRequested = signal(false)

export function requestCommandPaletteOpen(): void {
  commandPaletteRequested.value = true
}
