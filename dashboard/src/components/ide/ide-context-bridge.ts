import { signal } from '@preact/signals'
import type { AnchoredThread } from './anchored-thread-rail-store'

export interface IdeConversationThreadSnapshot {
  readonly filePath: string | null
  readonly threads: ReadonlyArray<AnchoredThread>
}

export const ideConversationThreadSnapshot = signal<IdeConversationThreadSnapshot>({
  filePath: null,
  threads: [],
})

export function publishIdeConversationThreads(
  filePath: string | null,
  threads: ReadonlyArray<AnchoredThread>,
): void {
  ideConversationThreadSnapshot.value = {
    filePath,
    threads: [...threads],
  }
}
