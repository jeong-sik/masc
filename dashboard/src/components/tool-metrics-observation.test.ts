import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, describe, expect, it } from 'vitest'
import type { ToolMetricsResponse } from '../api'
import { ToolMetrics } from './tool-metrics'
import fixture from './tools/fixtures/tool-usage-53203.json'

const container = document.createElement('div')
afterEach(() => render(null, container))

describe('actual Tools observation denominators', () => {
  it('shows retained visible usage separately from hidden calls and log health', () => {
    // The allowlisted source snapshot is untouched. These two new fields are
    // the proposed API projection, not a claim that 53203 already emitted it.
    const data: ToolMetricsResponse = {
      ...fixture.original_metrics,
      metrics_source: { kind: 'tool_metrics', scope: 'retained_snapshot_and_current_process', persistence: 'sqlite' },
      catalog_usage: fixture.expected_catalog_usage,
      non_public_call_log: fixture.original_non_public_call_log,
    }
    expect(fixture.original_inventory_count).toBe(171)
    expect(data.registered_count).toBe(21)
    expect(data.total_calls).toBe(fixture.original_metrics.by_tool.reduce((n, row) => n + row.call_count, 0))
    const visibleNames = new Set(fixture.inventory.filter(row => row.visibility === 'default').map(row => row.name))
    expect(fixture.original_metrics.by_tool.filter(row => visibleNames.has(row.name))).toHaveLength(26)
    expect(fixture.original_metrics.never_called.every(name => visibleNames.has(name))).toBe(true)
    expect(fixture.expected_catalog_usage.visible_called + fixture.original_metrics.never_called_count).toBe(103)

    render(html`<${ToolMetrics} data=${data} />`, container)
    const text = container.textContent ?? ''
    expect(text).toContain('총 호출 수775')
    expect(text).toContain('사용이 관측된 전체 도구50')
    expect(text).toContain('현재 비숨김 도구 103개: 사용 관측 26개 · 현재 집계에 호출 없음 77개')
    expect(text).toContain('숨김 도구 24개 · 현재 카탈로그 밖 도구 0개')
    expect(text).toContain('현재 프로세스 호출과 SQLite 보존 기록을 합산합니다')
    // The same sentence used to say the records were "복원에 성공한" and then
    // that this response does not check restore state. It cannot claim a
    // success it never reads: startup hydration can fail and the server
    // carries on with the in-memory snapshot while metrics_source stays the
    // same, so an empty retention and a failed restore look identical here.
    expect(text).not.toContain('복원에 성공한')
    expect(text).toContain('복원·저장 성공 여부를 확인하지 않으므로')
    expect(text).toContain('보존 기록이 비어 있는 것과 복원이 실패한 것을 구분하지 않습니다')
    expect(text).toContain('보존 범위 밖의 과거 사용 여부는 알 수 없습니다')
    expect(text).not.toContain('등록됨')
    expect(text).not.toContain('모든 MCP 서버')
    expect(text).not.toContain('재시작 시 초기화')
    expect(text).not.toContain('645')
    expect(text).not.toContain('tool_usage')
  })
})
