import { signal } from '@preact/signals'

// Invalidates file read/write bases after an external write receipt or an
// unanswered write. A generation change alone does not prove a file commit.
export const runtimeTomlSourceGeneration = signal(0)

export function announceRuntimeTomlWritten(): void {
  runtimeTomlSourceGeneration.value += 1
}

export function announceRuntimeTomlWriteUncertain(): void {
  runtimeTomlSourceGeneration.value += 1
}
