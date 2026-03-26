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
  | 'worktrees'
  | 'intervene'
  | 'warroom'
  | 'tools'
  | 'autoresearch'
  | 'harness'

type NonHomeTabId = Exclude<TabId, 'overview' | 'logs'>
const OPERATIONS_COMMAND_SURFACES = new Set([
  'orchestra',
  'swarm',
  'operations',
  'chains',
  'control',
])

export interface DashboardNavGroup {
  id: SurfaceId
  label: string
  icon: string
  description: string
  defaultTab: TabId
  defaultParams?: Record<string, string>
  tabs: TabId[]
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
    description: '세션 룸 및 에이전트/키퍼 현황 관찰',
    defaultTab: 'monitoring',
    defaultParams: { section: 'sessions' },
    tabs: ['monitoring'],
  },
  {
    id: 'command',
    label: '운영 개입',
    icon: '🎛️',
    description: '실시간 개입과 운영 제어',
    defaultTab: 'command',
    defaultParams: { section: 'intervene' },
    tabs: ['command'],
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
    description: '시스템 도구 테스트',
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
      label: '세션 & 룸',
      description: '진행 중인 세션과 룸 현황을 봅니다.',
      params: { section: 'sessions' },
    },
    {
      id: 'agents',
      label: '에이전트 & 키퍼',
      description: '일반 에이전트와 키퍼 런타임을 나눠 봅니다.',
      params: { section: 'agents' },
    },
    {
      id: 'activity',
      label: '활동 그래프',
      description: '실시간 이벤트 흐름을 봅니다.',
      params: { section: 'activity' },
    },
  ],
  command: [
    {
      id: 'intervene',
      label: '실시간 개입',
      description: '방, 세션, 키퍼에 바로 개입합니다.',
      params: { section: 'intervene' },
    },
    {
      id: 'warroom',
      label: '관제면',
      description: '오케스트라, 스웜, 체인, 제어 실험 표면입니다.',
      params: { section: 'warroom' },
      hidden: true,
    },
    {
      id: 'governance',
      label: '거버넌스',
      description: '의사결정 기록 및 판결 흐름 제어입니다.',
      params: { section: 'governance' },
    },
  ],
  workspace: [
    {
      id: 'board',
      label: '작업 게시판',
      description: '에이전트 게시판과 지식 공유를 봅니다.',
      params: { section: 'board' },
    },
    {
      id: 'evidence',
      label: '근거 및 이력',
      description: '작업 증거와 검증 결과를 봅니다.',
      params: { section: 'evidence' },
    },
    {
      id: 'planning',
      label: '계획 및 메트릭',
      description: '장기 목표와 루프를 봅니다.',
      params: { section: 'planning' },
    },
    {
      id: 'worktrees',
      label: '워크트리',
      description: '현재 활성화된 작업 공간입니다.',
      params: { section: 'worktrees' },
    },
  ],
  lab: [
    {
      id: 'tools',
      label: '도구 & 실험',
      description: '도구 인벤토리와 기타 실험을 진행합니다.',
      params: { section: 'tools' },
    },
    {
      id: 'autoresearch',
      label: '오토리서치',
      description: '자율 실험 루프 상태와 이력을 봅니다.',
      params: { section: 'autoresearch' },
    },
    {
      id: 'harness',
      label: '하네스 헬스',
      description: 'Evaluator 캘리브레이션, 컴팩션 전략, DNA 품질 추이를 봅니다.',
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

  if (tabId === 'command') {
    if (next.section === 'warroom') {
      if (next.surface && !OPERATIONS_COMMAND_SURFACES.has(next.surface)) {
        delete next.surface
      }
    } else {
      delete next.surface
    }
  } else {
    delete next.surface
  }

  return next
}

export function currentSectionForRoute(routeState: Pick<RouteState, 'tab' | 'params'>): DashboardSectionNavItem | null {
  if (routeState.tab === 'overview' || routeState.tab === 'logs') return null
  const normalized = normalizeRouteParams(routeState.tab, routeState.params)
  return sectionItemsForTab(routeState.tab).find(item => item.params.section === normalized.section) ?? null
}
