import type { RouteState, TabId } from '../types'

export type SurfaceId = TabId
export type SurfaceSectionId =
  // monitoring
  | 'observatory'
  | 'agents'
  | 'activity'       // kept alongside observatory until observatory exits beta
  | 'runtime'
  | 'fleet-health'   // Phase 1: absorbs telemetry + fleet + tool-quality + monitoring governance
  | 'memory-subsystems'
  // command
  | 'operations'     // Phase 1: absorbs intervene + command governance
  | 'connectors'
  | 'inspector'
  // workspace
  | 'board'
  | 'planning'       // Phase 1: absorbs goals
  // lab
  | 'tools'
  | 'autoresearch'
  | 'harness'

type NonHomeTabId = Exclude<TabId, 'overview' | 'logs'>

export interface DashboardNavGroup {
  id: SurfaceId
  label: string
  icon: string
  description: string
  defaultTab: TabId
  defaultParams?: Record<string, string>
  tabs: TabId[]
  hidden?: boolean
}

export interface DashboardNavItem {
  id: TabId
  label: string
  icon: string
  description: string
  defaultParams?: Record<string, string>
}

export interface DashboardSectionNavItem {
  id: SurfaceSectionId
  label: string
  description: string
  params: Record<string, string>
  hidden?: boolean
}

export const DASHBOARD_SURFACES: DashboardNavGroup[] = [
  {
    id: 'overview',
    label: '오버뷰',
    icon: '🏠',
    description: '빠른 신호 및 브리핑 통합 화면',
    defaultTab: 'overview',
    tabs: ['overview'],
  },
  {
    id: 'monitoring',
    label: '모니터링',
    icon: '📡',
    description: '에이전트/키퍼 현황 및 observability 관찰',
    defaultTab: 'monitoring',
    defaultParams: { section: 'agents' },
    tabs: ['monitoring'],
  },
  {
    id: 'command',
    label: '운영',
    icon: '🎛️',
    description: '실시간 개입과 거버넌스 판단/승인 운영 화면',
    defaultTab: 'command',
    defaultParams: { section: 'operations' },
    tabs: ['command'],
  },
  {
    id: 'workspace',
    label: '작업',
    icon: '📋',
    description: '작업 게시판, 증명/판정, 계획 이력 탐색',
    defaultTab: 'workspace',
    defaultParams: { section: 'board' },
    tabs: ['workspace'],
  },
  {
    id: 'lab',
    label: '실험실',
    icon: '🧪',
    description: '도구 진단과 실험 제어',
    defaultTab: 'lab',
    defaultParams: { section: 'tools' },
    tabs: ['lab'],
  },
  {
    id: 'logs',
    label: '로그',
    icon: '📜',
    description: '시스템 실행 로그',
    defaultTab: 'logs',
    tabs: ['logs'],
  },
]

export const DASHBOARD_NAV_ITEMS: DashboardNavItem[] = DASHBOARD_SURFACES.map(surface => ({
  id: surface.id,
  label: surface.label,
  icon: surface.icon,
  description: surface.description,
  defaultParams: surface.defaultParams,
}))

export const DASHBOARD_SECTION_ITEMS: Record<NonHomeTabId, DashboardSectionNavItem[]> = {
  monitoring: [
    {
      id: 'observatory',
      label: '관찰소 (beta)',
      description: '이벤트/메트릭을 단일 timeline에 통합. RFC-MASC-006 Phase 2a.',
      params: { section: 'observatory' },
    },
    {
      id: 'agents',
      label: '에이전트 & 키퍼',
      description: '이름과 운영 상태를 함께 봅니다. 세션 요약은 오버뷰에서.',
      params: { section: 'agents' },
    },
    {
      id: 'activity',
      label: '활동 그래프',
      description: '실시간 이벤트 흐름 (broadcast, task, keeper 이벤트). Observatory 졸업 후 통합 예정.',
      params: { section: 'activity' },
    },
    {
      id: 'runtime',
      label: '런타임',
      description: 'provider health, 슬롯 용량, model inference snapshot.',
      params: { section: 'runtime' },
    },
    {
      id: 'fleet-health',
      label: 'Fleet 건강',
      description: '텔레메트리 이벤트, Fleet 비교, 도구 품질, 거버넌스 지표를 통합 뷰로.',
      params: { section: 'fleet-health' },
    },
    {
      id: 'memory-subsystems',
      label: '기억 서브시스템',
      description: 'Hebbian 시냅스 그래프, 에피소드 기록, compaction 상태.',
      params: { section: 'memory-subsystems' },
    },
  ],
  command: [
    {
      id: 'operations',
      label: '운영 행동',
      description: '브로드캐스트, 키퍼 메시지, 자율 결정 승인/반려를 한 화면에서.',
      params: { section: 'operations' },
    },
    {
      id: 'connectors',
      label: '커넥터',
      description: '외부 채널(Discord 등) 연결 상태, 바인딩 관리, 이벤트 로그.',
      params: { section: 'connectors' },
    },
    {
      id: 'inspector',
      label: '운영 인스펙터',
      description: '피처 플래그와 서버 설정을 한 화면으로 묶은 운영 진단/점검 화면.',
      params: { section: 'inspector' },
    },
  ],
  workspace: [
    {
      id: 'board',
      label: '작업 게시판',
      description: '에이전트가 남긴 직접 작성 글, 자동화 글, 시스템 글을 한 곳에서 봅니다.',
      params: { section: 'board' },
    },
    {
      id: 'planning',
      label: '계획 & 목표',
      description: '실행 단위 칸반과 상위 의도 구조(목표 트리)를 함께 봅니다.',
      params: { section: 'planning' },
    },
  ],
  lab: [
    {
      id: 'tools',
      label: '도구',
      description: '등록된 MCP 도구 전체 목록 (모든 서버 합산). 자주 사용하는 도구가 상단.',
      params: { section: 'tools' },
    },
    {
      id: 'autoresearch',
      label: '오토리서치',
      description: '자율 실험 루프 상태와 이력.',
      params: { section: 'autoresearch' },
    },
    {
      id: 'harness',
      label: '세이프티 하네스',
      description: '평가 모델, 압축 전 상태, 세대 교체 rail 감시 상태.',
      params: { section: 'harness' },
    },
  ],
}

function validSectionIds(tab: NonHomeTabId): SurfaceSectionId[] {
  return DASHBOARD_SECTION_ITEMS[tab].map(item => item.id)
}

export function defaultParamsForTab(tabId: TabId): Record<string, string> {
  return DASHBOARD_SURFACES.find(surface => surface.id === tabId)?.defaultParams ?? {}
}

export function sectionItemsForTab(tabId: TabId): DashboardSectionNavItem[] {
  if (tabId === 'overview' || tabId === 'logs') return []
  return DASHBOARD_SECTION_ITEMS[tabId as NonHomeTabId]
}

export function visibleSectionItemsForTab(tabId: TabId): DashboardSectionNavItem[] {
  return sectionItemsForTab(tabId).filter(item => item.hidden !== true)
}

/**
 * Redirect table for legacy section IDs.
 *
 * Key: (tab, old section) → value: { section, view? }
 *
 * `view` sets the view query param when absent, for canonicalization into
 * fleet-health sub-views.
 *
 * Contract:
 *   - Redirects are applied BEFORE section validation.
 *   - Caller-supplied query params (session_id, operation_id, worker_run_id,
 *     tool, target_id, keeper, agent, ns, range, etc.) are preserved.
 *   - This function MUST remain pure. Side effects (modal open, analytics)
 *     must live in router/app effects, not here.
 *   - Cross-surface redirects are not supported (normalizeRouteParams returns
 *     params for the same tab). Cross-surface routing lives in the router.
 */
export interface SectionRedirect {
  section: string
  view?: string
}

type TabSectionKey = `${TabId}:${string}`

export const SECTION_REDIRECTS: Record<TabSectionKey, SectionRedirect> = {
  // RFC-MASC-006 Phase 0: sessions stub removed
  'monitoring:sessions': { section: 'agents' },

  // Dashboard consolidation Phase 1: monitoring surface
  'monitoring:telemetry':    { section: 'fleet-health', view: 'event-log' },
  'monitoring:fleet':        { section: 'fleet-health', view: 'comparison' },
  'monitoring:tool-quality': { section: 'fleet-health', view: 'tool-quality' },
  'monitoring:governance':   { section: 'fleet-health', view: 'governance' },
  'monitoring:fsm-hub':      { section: 'agents', view: 'fsm' },
  'monitoring:metrics':      { section: 'runtime' },

  // Dashboard consolidation Phase 1: command surface
  'command:intervene':  { section: 'operations' },
  'command:governance': { section: 'operations' },

  // Dashboard consolidation Phase 1: workspace surface
  'workspace:goals': { section: 'planning' },
}

export function normalizeRouteParams(tabId: TabId, params: Record<string, string>): Record<string, string> {
  const next = { ...params }

  if (tabId === 'overview' || tabId === 'logs') {
    delete next.section
    delete next.surface
    return next
  }

  // Apply redirect table (pure transform: no side effects).
  const inputSection = next.section
  if (inputSection) {
    const redirect = SECTION_REDIRECTS[`${tabId}:${inputSection}` as TabSectionKey]
    if (redirect) {
      if (redirect.view && !next.view) next.view = redirect.view
      next.section = redirect.section
      // Cross-surface redirect handled by caller (router) — see contract doc.
    }
  }

  const typedTabId = tabId as NonHomeTabId

  if (!validSectionIds(typedTabId).includes(next.section as SurfaceSectionId)) {
    next.section = defaultParamsForTab(tabId).section ?? ''
  }

  delete next.surface
  delete next.operation
  delete next.run_id

  return next
}

export function currentSectionForRoute(routeState: Pick<RouteState, 'tab' | 'params'>): DashboardSectionNavItem | null {
  if (routeState.tab === 'overview' || routeState.tab === 'logs') return null
  const normalized = normalizeRouteParams(routeState.tab, routeState.params)
  return sectionItemsForTab(routeState.tab).find(item => item.params.section === normalized.section) ?? null
}
