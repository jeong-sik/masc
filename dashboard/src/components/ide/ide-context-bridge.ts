import { signal } from '@preact/signals'
import type { AnchoredThread } from './anchored-thread-rail-store'

export interface IdeConversationThreadSnapshot {
  readonly filePath: string
  readonly threads: ReadonlyArray<AnchoredThread>
}

export const ideConversationThreadSnapshot = signal<IdeConversationThreadSnapshot>({
  filePath: '',
  threads: [],
})

export function publishIdeConversationThreads(
  filePath: string,
  threads: ReadonlyArray<AnchoredThread>,
): void {
  ideConversationThreadSnapshot.value = {
    filePath,
    threads: [...threads],
  }
}
