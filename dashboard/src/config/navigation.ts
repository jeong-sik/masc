import type { RouteState, TabId } from '../types'

export type SurfaceId = TabId
export type SurfaceSectionId =
  | 'sessions'
  | 'agents'
  | 'activity'
  | 'board'
  | 'governance'
  | 'evidence'
  | 'planning'
  | 'goals'
  | 'intervene'
  | 'tools'
  | 'autoresearch'
  | 'harness'
  | 'inspector'
  | 'runtime'
  | 'telemetry'
  | 'tool-quality'
  | 'fleet'

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
    description: '세션, 에이전트/키퍼 현황 관찰',
    defaultTab: 'monitoring',
    defaultParams: { section: 'sessions' },
    tabs: ['monitoring'],
  },
  {
    id: 'command',
    label: '운영 개입',
    icon: '🎛️',
    description: 'Retired compatibility surface kept only for old deep links.',
    defaultTab: 'command',
    defaultParams: { section: 'intervene' },
    tabs: ['command'],
    hidden: true,
  },
  {
    id: 'workspace',
    label: '작업',
    icon: '📋',
    description: '작업 게시판, 근거 및 계획 이력 탐색',
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
      id: 'sessions',
      label: '세션',
      description: '실시간 세션 상태와 주의 신호.',
      params: { section: 'sessions' },
    },
    {
      id: 'agents',
      label: '에이전트 & 키퍼',
      description: '에이전트 = 작업 수행 프로세스. 키퍼 = 장기 컨텍스트를 유지하는 상주 런타임.',
      params: { section: 'agents' },
    },
    {
      id: 'activity',
      label: '활동 그래프',
      description: '실시간 이벤트 흐름 (broadcast, task, keeper 이벤트).',
      params: { section: 'activity' },
    },
    {
      id: 'runtime',
      label: '런타임',
      description: 'provider health, 슬롯 용량, model inference snapshot.',
      params: { section: 'runtime' },
    },
    {
      id: 'telemetry',
      label: '텔레메트리',
      description: 'append-only 이벤트 기록. runtime snapshot은 별도 런타임 탭에서 봅니다.',
      params: { section: 'telemetry' },
    },
  ],
  command: [
    {
      id: 'intervene',
      label: '실시간 개입',
      description: '프로젝트 일시정지, 세션 중단, 키퍼 재시작 등 운영 개입.',
      params: { section: 'intervene' },
    },
    {
      id: 'governance',
      label: '거버넌스',
      description: '에이전트 자율 결정의 검토/승인 기록. 위험 행동 방지 레이어.',
      params: { section: 'governance' },
    },
  ],
  workspace: [
    {
      id: 'board',
      label: '작업 게시판',
      description: '에이전트 간 지식 공유 게시판. 직접 작성 글, 자동화 글, 시스템 글을 함께 보여줍니다.',
      params: { section: 'board' },
    },
    {
      id: 'evidence',
      label: '근거 및 이력',
      description: '협업 증거. team turn, broadcast, 멘션 등 백엔드에서 실시간 동적 집계한 결과.',
      params: { section: 'evidence' },
    },
    {
      id: 'planning',
      label: '계획 및 메트릭',
      description: 'backlog와 수동 등록형 goal 상태를 함께 보는 화면. goal은 자동 생성되지 않습니다.',
      params: { section: 'planning' },
    },
    {
      id: 'goals',
      label: '목표 트리',
      description: '목표의 부모-자식 계층 구조와 수렴도. 태스크 연결, 에이전트 배정 상태 시각화.',
      params: { section: 'goals' },
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
      description: 'Evaluator, compaction, DNA safety rail 감시 상태.',
      params: { section: 'harness' },
    },
    {
      id: 'inspector',
      label: '운영 인스펙터',
      description: '피처 플래그와 서버 설정을 한 화면으로 묶은 운영 진단/점검 화면.',
      params: { section: 'inspector' },
    },
    {
      id: 'tool-quality',
      label: '도구 품질',
      description: 'Keeper tool call 성공률, 실패 카테고리, keeper별 품질 지표.',
      params: { section: 'tool-quality' },
    },
    {
      id: 'fleet',
      label: 'Fleet 텔레메트리',
      description: 'Keeper 전체 비교: tok/sec, latency, error 분류, model 분포, compaction.',
      params: { section: 'fleet' },
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

export function normalizeRouteParams(tabId: TabId, params: Record<string, string>): Record<string, string> {
  const next = { ...params }

  if (tabId === 'overview' || tabId === 'logs') {
    delete next.section
    delete next.surface
    return next
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
