import { signal } from '@preact/signals'

// Bumped after a runtime.toml write made outside RuntimeTomlEditor (the
// Settings routing and lane writers). A mounted editor re-reads the file so
// its structured projection (lane names, assignments) and the source_revision
// its assignment writes send are not left at the text it loaded first.
export const runtimeTomlSourceGeneration = signal(0)

export function announceRuntimeTomlWritten(): void {
  runtimeTomlSourceGeneration.value += 1
}
