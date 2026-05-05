import { relativeTime as relativeTimeBase, formatDuration } from '../lib/format-time'
import { trimText } from '../lib/truncate'
import { toneClass } from '../lib/tone'
import { statusLabel } from '../lib/status-label'

export { formatDuration, trimText, toneClass, statusLabel }

export function relativeTime(iso?: string | null): string {
  return relativeTimeBase(iso, '방금')
}
