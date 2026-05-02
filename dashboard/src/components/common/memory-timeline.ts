// MemoryTimeline — AX molecule that visualizes memory access patterns
// as an hourly heatmap bar chart.
//
// Kimi design system sec03 reference: 3.1.3 access heatmap for agent
// working-memory recall patterns.

import { html } from 'htm/preact'
import { useMemo } from 'preact/hooks'

export interface TimelineEntry {
  timestamp: number
  memoryId: string
  accessType: 'read' | 'write' | 'search'
}

interface MemoryTimelineProps {
  entries: TimelineEntry[]
  testId?: string
}

function accessTypeColor(accessType: string): string {
  return accessType === 'write'
    ? 'var(--warn-10)'
    : accessType === 'search'
      ? 'var(--color-accent)'
      : 'var(--ok-10)'
}

export function MemoryTimeline({ entries, testId }: MemoryTimelineProps) {
  const hours = useMemo(() => Array.from({ length: 24 }, (_, i) => i), [])

  const heatmap = useMemo(() => {
    const map: Record<number, { count: number; type: string }> = {}
    entries.forEach(e => {
      const hour = new Date(e.timestamp).getHours()
      if (!map[hour]) {
        map[hour] = { count: 0, type: e.accessType }
      }
      map[hour].count += 1
    })
    const max = Math.max(...Object.values(map).map(v => v.count), 1)
    return hours.map(h => ({
      hour: h,
      count: map[h]?.count || 0,
      intensity: (map[h]?.count || 0) / max,
      type: map[h]?.type || 'read',
    }))
  }, [entries])

  const maxCount = Math.max(...heatmap.map(h => h.count), 1)

  return html`
    <div class="w-full" data-memory-timeline data-testid=${testId}>
      <div class="flex items-end gap-1 h-16" role="img" aria-label="시간대별 메모리 접근 패턴">
        ${heatmap.map(
          h => html`
            <div
              key=${h.hour}
              class="flex-1 rounded-t transition-[background-color,opacity]"
              style=${{
                opacity: 0.1 + h.intensity * 0.9,
                height: `${20 + h.intensity * 80}%`,
                background: accessTypeColor(h.type),
              }}
              title="${h.hour}시 — ${h.count}회 접근"
              role="graphics-symbol"
              aria-label="${h.hour}시: ${h.count}회"
            ></div>
          `,
        )}
      </div>
      <div class="mt-1 flex justify-between text-3xs text-[var(--color-fg-secondary)]">
        <span>00:00</span>
        <span>06:00</span>
        <span>12:00</span>
        <span>18:00</span>
        <span>23:00</span>
      </div>
      <div class="mt-1.5 flex items-center gap-3 text-3xs text-[var(--color-fg-muted)]">
        <span class="inline-flex items-center gap-1">
          <span class="inline-block h-2 w-2 rounded-[var(--r-0)]" style=${{ background: 'var(--ok-10)' }}></span>
          읽기
        </span>
        <span class="inline-flex items-center gap-1">
          <span class="inline-block h-2 w-2 rounded-[var(--r-0)]" style=${{ background: 'var(--warn-10)' }}></span>
          쓰기
        </span>
        <span class="inline-flex items-center gap-1">
          <span class="inline-block h-2 w-2 rounded-[var(--r-0)]" style=${{ background: 'var(--color-accent)' }}></span>
          검색
        </span>
        <span class="ml-auto">최대 ${maxCount}회</span>
      </div>
    </div>
  `
}
