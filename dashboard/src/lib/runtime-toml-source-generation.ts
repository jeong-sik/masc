import { signal } from '@preact/signals'

// Invalidates file read/write bases after an external write receipt or an
// unanswered write. A generation change alone does not prove a file commit.
// The request that receives a write receipt announces it (see
// receiveRuntimeTomlCommit), so a screen that stopped waiting cannot drop it;
// the screen that sent a write announces only its unanswered doubt.
export const runtimeTomlSourceGeneration = signal(0)

export function announceRuntimeTomlWritten(): void {
  runtimeTomlSourceGeneration.value += 1
}

export function announceRuntimeTomlWriteUncertain(): void {
  runtimeTomlSourceGeneration.value += 1
}
