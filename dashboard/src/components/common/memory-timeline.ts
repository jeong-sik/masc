// MemoryTimeline — AX molecule that visualizes memory access patterns
// as an hourly heatmap bar chart.
//
// Kimi design system sec03 reference: 3.1.3 access heatmap for agent
// working-memory recall patterns.

import { html } from 'htm/preact'
import { useMemo } from 'preact/hooks'

export type MemoryAccessType = 'read' | 'write' | 'search'

export interface TimelineEntry {
  timestamp: number
  memoryId: string
  accessType: MemoryAccessType
}

export interface HourlyMemoryAccess {
  readonly hour: number
  readonly count: number
  readonly intensity: number
  readonly dominantType: MemoryAccessType | null
  readonly uniqueMemoryCount: number
  readonly typeCounts: Record<MemoryAccessType, number>
}

export interface MemoryTimelineSummary {
  readonly totalAccesses: number
  readonly uniqueMemoryCount: number
  readonly peakHour: number | null
  readonly peakCount: number
  readonly typeCounts: Record<MemoryAccessType, number>
}

interface MemoryTimelineProps {
  entries: TimelineEntry[]
  testId?: string
}

const ACCESS_TYPES: readonly MemoryAccessType[] = ['read', 'write', 'search']
const ACCESS_TYPE_LABEL: Record<MemoryAccessType, string> = {
  read: '읽기',
  write: '쓰기',
  search: '검색',
}

const ACCESS_TYPE_PRIORITY: Record<MemoryAccessType, number> = {
  read: 1,
  search: 2,
  write: 3,
}

function emptyTypeCounts(): Record<MemoryAccessType, number> {
  return { read: 0, write: 0, search: 0 }
}

function dominantAccessType(typeCounts: Record<MemoryAccessType, number>): MemoryAccessType {
  return ACCESS_TYPES.reduce<MemoryAccessType>((best, accessType) => {
    const bestCount = typeCounts[best]
    const nextCount = typeCounts[accessType]
    if (nextCount > bestCount) return accessType
    if (nextCount === bestCount && ACCESS_TYPE_PRIORITY[accessType] > ACCESS_TYPE_PRIORITY[best]) {
      return accessType
    }
    return best
  }, 'read')
}

export function summarizeMemoryTimeline(entries: TimelineEntry[]): MemoryTimelineSummary {
  const typeCounts = emptyTypeCounts()
  const memoryIds = new Set<string>()
  const hourCounts: Record<number, number> = {}

  entries.forEach((entry) => {
    typeCounts[entry.accessType] += 1
    memoryIds.add(entry.memoryId)
    const hour = new Date(entry.timestamp).getHours()
    hourCounts[hour] = (hourCounts[hour] ?? 0) + 1
  })

  const peak = Object.entries(hourCounts).reduce<{ hour: number | null; count: number }>(
    (best, [hour, count]) => {
      const hourNumber = Number(hour)
      if (count > best.count) return { hour: hourNumber, count }
      if (count === best.count && best.hour !== null && hourNumber < best.hour) {
        return { hour: hourNumber, count }
      }
      return best
    },
    { hour: null, count: 0 },
  )

  return {
    totalAccesses: entries.length,
    uniqueMemoryCount: memoryIds.size,
    peakHour: peak.hour,
    peakCount: peak.count,
    typeCounts,
  }
}

export function buildMemoryTimelineHeatmap(entries: TimelineEntry[]): HourlyMemoryAccess[] {
  const hours = Array.from({ length: 24 }, (_, i) => i)
  const map: Record<number, { count: number; typeCounts: Record<MemoryAccessType, number>; memoryIds: Set<string> }> = {}

  entries.forEach((entry) => {
    const hour = new Date(entry.timestamp).getHours()
    if (!map[hour]) {
      map[hour] = { count: 0, typeCounts: emptyTypeCounts(), memoryIds: new Set() }
    }
    map[hour].count += 1
    map[hour].typeCounts[entry.accessType] += 1
    map[hour].memoryIds.add(entry.memoryId)
  })

  const max = Math.max(...Object.values(map).map((v) => v.count), 1)
  return hours.map((hour) => {
    const bucket = map[hour]
    const typeCounts = bucket?.typeCounts ?? emptyTypeCounts()
    const count = bucket?.count ?? 0
    return {
      hour,
      count,
      intensity: count / max,
      dominantType: count > 0 ? dominantAccessType(typeCounts) : null,
      uniqueMemoryCount: bucket?.memoryIds.size ?? 0,
      typeCounts,
    }
  })
}

function accessTypeColor(accessType: MemoryAccessType): string {
  return accessType === 'write'
    ? 'var(--warn-10)'
    : accessType === 'search'
      ? 'var(--color-accent)'
      : 'var(--ok-10)'
}

function formatPeakHour(summary: MemoryTimelineSummary): string {
  return summary.peakHour === null ? '없음' : `${summary.peakHour}시`
}

function formatHourTitle(hour: HourlyMemoryAccess): string {
  if (hour.count === 0 || !hour.dominantType) return `${hour.hour}시 — 접근 없음`
  return `${hour.hour}시 — ${hour.count}회 접근 · ${ACCESS_TYPE_LABEL[hour.dominantType]} 우세 · ${hour.uniqueMemoryCount}개 메모리`
}

function formatHourAriaLabel(hour: HourlyMemoryAccess): string {
  if (hour.count === 0 || !hour.dominantType) return `${hour.hour}시: 접근 없음`
  return `${hour.hour}시: ${hour.count}회, ${ACCESS_TYPE_LABEL[hour.dominantType]} 우세, 고유 메모리 ${hour.uniqueMemoryCount}개`
}

export function MemoryTimeline({ entries, testId }: MemoryTimelineProps) {
  const heatmap = useMemo(() => buildMemoryTimelineHeatmap(entries), [entries])
  const summary = useMemo(() => summarizeMemoryTimeline(entries), [entries])
  const chartLabel = summary.totalAccesses === 0
    ? '시간대별 메모리 접근 패턴, 접근 없음'
    : `시간대별 메모리 접근 패턴, 총 ${summary.totalAccesses}회, 고유 메모리 ${summary.uniqueMemoryCount}개, 최대 ${formatPeakHour(summary)} ${summary.peakCount}회`

  return html`
    <div class="w-full" data-memory-timeline data-testid=${testId}>
      <div
        class="mb-2 grid grid-cols-3 gap-2 text-3xs text-[var(--color-fg-secondary)]"
        data-memory-timeline-summary
        data-memory-timeline-total=${summary.totalAccesses}
        data-memory-timeline-unique=${summary.uniqueMemoryCount}
        data-memory-timeline-peak-hour=${summary.peakHour ?? ''}
        data-memory-timeline-peak-count=${summary.peakCount}
      >
        <span>총 ${summary.totalAccesses}회</span>
        <span>고유 ${summary.uniqueMemoryCount}개</span>
        <span>피크 ${formatPeakHour(summary)} · ${summary.peakCount}회</span>
      </div>
      <div class="flex h-16 items-end gap-1" role="img" aria-label=${chartLabel}>
        ${heatmap.map(
          h => html`
            <div
              key=${h.hour}
              class="flex-1 rounded-t transition-[background-color,opacity]"
              style=${{
                opacity: 0.1 + h.intensity * 0.9,
                height: `${20 + h.intensity * 80}%`,
                background: accessTypeColor(h.dominantType ?? 'read'),
              }}
              title=${formatHourTitle(h)}
              role="graphics-symbol"
              aria-label=${formatHourAriaLabel(h)}
              data-memory-timeline-hour=${h.hour}
              data-memory-timeline-count=${h.count}
              data-memory-timeline-dominant-type=${h.dominantType ?? ''}
              data-memory-timeline-unique=${h.uniqueMemoryCount}
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
          읽기 ${summary.typeCounts.read}
        </span>
        <span class="inline-flex items-center gap-1">
          <span class="inline-block h-2 w-2 rounded-[var(--r-0)]" style=${{ background: 'var(--warn-10)' }}></span>
          쓰기 ${summary.typeCounts.write}
        </span>
        <span class="inline-flex items-center gap-1">
          <span class="inline-block h-2 w-2 rounded-[var(--r-0)]" style=${{ background: 'var(--color-accent)' }}></span>
          검색 ${summary.typeCounts.search}
        </span>
        <span class="ml-auto">최대 ${summary.peakCount}회</span>
      </div>
    </div>
  `
}
