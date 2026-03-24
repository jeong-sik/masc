import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { DashboardSurfaceReadinessResponse } from '../../api'

async function flushUi(): Promise<void> {
  for (let i = 0; i < 4; i += 1) {
    await Promise.resolve()
    await new Promise(resolve => setTimeout(resolve, 0))
  }
}

function readinessResponse(): DashboardSurfaceReadinessResponse {
  return {
    generated_at: '2026-03-25T00:00:00Z',
    proof_bar: 'fixture+live_spotcheck',
    surfaces: [
      {
        id: 'monitoring.sessions',
        label: '세션 & 룸',
        exposure_status: 'main',
        hidden_from_nav: false,
        meets_main_gate: true,
        proof_bar: 'fixture+live_spotcheck',
        rationale: '세션 운영은 fixture smoke, live session smoke, logs, metrics, proof 경로를 모두 갖춘 메인 surface입니다.',
        route_hash: '#monitoring?section=sessions',
        verification_refs: [
          { kind: 'script', label: 'fixture_harness', value: './scripts/harness_dashboard_mission_smoke.sh' },
          { kind: 'script', label: 'live_spotcheck', value: './scripts/harness_dashboard_collaboration_evidence_smoke.sh' },
          { kind: 'route', label: 'proof', value: '/api/v1/dashboard/proof' },
        ],
      },
      {
        id: 'command.warroom',
        label: '관제면',
        exposure_status: 'lab',
        hidden_from_nav: true,
        meets_main_gate: false,
        proof_bar: 'fixture+live_spotcheck',
        rationale: '오케스트라/스웜/체인/제어는 evidence bundle이 아직 약해 메인 탐색에서 숨기고 실험 surface로 유지합니다.',
        route_hash: '#command?section=warroom',
        verification_refs: [
          { kind: 'script', label: 'fixture_harness', value: './scripts/harness_agent_swarm_live.sh' },
          { kind: 'script', label: 'live_spotcheck', value: './scripts/harness/workload/agent_swarm_live.sh' },
          { kind: 'route', label: 'logs', value: '/api/v1/dashboard/logs' },
        ],
      },
      {
        id: 'lab.tools',
        label: '도구 & 실험',
        exposure_status: 'lab',
        hidden_from_nav: false,
        meets_main_gate: false,
        proof_bar: 'fixture+live_spotcheck',
        rationale: '실험적 표면과 준비도 감사는 Lab에서 유지합니다.',
        route_hash: '#lab?section=tools',
        verification_refs: [
          { kind: 'route', label: 'live_spotcheck', value: '/api/v1/tool-metrics' },
          { kind: 'route', label: 'metrics', value: '/metrics' },
          { kind: 'tool', label: 'tool_name', value: 'masc_surface_audit' },
        ],
      },
    ],
  }
}

async function loadComponent(response: DashboardSurfaceReadinessResponse) {
  const fetchDashboardSurfaceReadiness = vi.fn<() => Promise<DashboardSurfaceReadinessResponse>>()
    .mockResolvedValue(response)

  vi.resetModules()
  vi.doMock('../../api', async () => {
    const actual = await vi.importActual<typeof import('../../api')>('../../api')
    return {
      ...actual,
      fetchDashboardSurfaceReadiness,
    }
  })

  const module = await import('./surface-readiness-panel')
  return { ...module, fetchDashboardSurfaceReadiness }
}

describe('SurfaceReadinessPanel', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    window.location.hash = ''
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.resetModules()
    vi.clearAllMocks()
    vi.doUnmock('../../api')
    window.location.hash = ''
  })

  it('groups main surfaces first and hides raw audit wording from the default UI', async () => {
    const { SurfaceReadinessPanel, fetchDashboardSurfaceReadiness } = await loadComponent(readinessResponse())

    render(html`<${SurfaceReadinessPanel} />`, container)
    await flushUi()

    expect(fetchDashboardSurfaceReadiness).toHaveBeenCalledTimes(1)

    const groups = Array.from(container.querySelectorAll('[data-surface-group]'))
    expect(groups.map(group => group.getAttribute('data-surface-group'))).toEqual(['main', 'deferred'])
    expect(groups[0]?.textContent).toContain('세션 & 룸')
    expect(groups[0]?.textContent).not.toContain('관제면')
    expect(groups[1]?.textContent).toContain('관제면')
    expect(groups[1]?.textContent).toContain('도구 & 실험')

    const text = container.textContent ?? ''
    expect(text).toContain('검증 기준')
    expect(text).toContain('fixture + live spotcheck')
    expect(text).toContain('메인 메뉴 숨김')
    expect(text).toContain('검증 근거 보기')
    expect(text).toContain('Fixture')
    expect(text).toContain('Live Spotcheck')
    expect(text).not.toContain('main ready')
    expect(text).not.toContain('gate missing')
    expect(text).not.toContain('gate:')
    expect(text).not.toContain('fixture_harness')
    expect(text).not.toContain('live_spotcheck')

    const details = Array.from(container.querySelectorAll('details'))
    expect(details).toHaveLength(3)
    for (const detail of details) {
      expect(detail.hasAttribute('open')).toBe(false)
    }
  }, 10000)

  it('opens the selected route from the primary action button', async () => {
    const { SurfaceReadinessPanel } = await loadComponent(readinessResponse())

    render(html`<${SurfaceReadinessPanel} />`, container)
    await flushUi()

    const openButton = Array.from(container.querySelectorAll('button'))
      .find(button => button.textContent?.includes('화면 열기'))
    openButton?.dispatchEvent(new MouseEvent('click', { bubbles: true }))

    expect(window.location.hash).toBe('#monitoring?section=sessions')
  })
})
