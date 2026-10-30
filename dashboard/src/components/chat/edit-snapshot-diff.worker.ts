import { computeEditSnapshotDiff } from './edit-snapshot-diff-engine'

self.onmessage = (event: MessageEvent<{ before: string; after: string }>) => {
  self.postMessage(computeEditSnapshotDiff(event.data.before, event.data.after))
}
