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
  | 'intervene'
  | 'command'
  | 'tools'
  | 'overview'
  | 'trpg'
  | 'avatars'

type NonHomeTabId = Exclude<TabId, 'home'>
const OPERATIONS_COMMAND_SURFACES = new Set([
  'warroom',
  'summary',
  'orchestra',
  'swarm',
  'operations',
  'topology',
  'alerts',
  'trace',
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
}

export const DASHBOARD_SURFACES: DashboardNavGroup[] = [
  {
    id: 'home',
    label: '홈',
    icon: '🏠',
    description: '지금 필요한 신호만 빠르게 보는 첫 화면',
    defaultTab: 'home',
    tabs: ['home'],
  },
  {
    id: 'status',
    label: '현황',
    icon: '📡',
    description: '세션, 에이전트, 활동 흐름을 읽는 기본 관찰면',
    defaultTab: 'status',
    defaultParams: { section: 'sessions' },
    tabs: ['status'],
  },
  {
    id: 'work',
    label: '작업',
    icon: '📋',
    description: '게시판, 거버넌스, 근거, 계획을 모아 보는 작업면',
    defaultTab: 'work',
    defaultParams: { section: 'board' },
    tabs: ['work'],
  },
  {
    id: 'operations',
    label: '운영',
    icon: '🎛️',
    description: '개입, 지휘, 도구를 다루는 운영면',
    defaultTab: 'operations',
    defaultParams: { section: 'intervene' },
    tabs: ['operations'],
  },
  {
    id: 'lab',
    label: '실험',
    icon: '🧪',
    description: 'TRPG와 실험 기능을 분리한 실험면',
    defaultTab: 'lab',
    defaultParams: { section: 'overview' },
    tabs: ['lab'],
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
  status: [
    {
      id: 'sessions',
      label: '세션',
      description: '지금 진행 중인 세션과 attention을 먼저 읽습니다.',
      params: { section: 'sessions' },
    },
    {
      id: 'agents',
      label: '에이전트',
      description: '에이전트, 키퍼, 세션을 한곳에서 탐색합니다.',
      params: { section: 'agents' },
    },
    {
      id: 'activity',
      label: '활동',
      description: '실시간 이벤트 흐름과 소셜 그래프를 봅니다.',
      params: { section: 'activity' },
    },
  ],
  work: [
    {
      id: 'board',
      label: '게시판',
      description: '팀 대화와 지식 공유를 보는 기본 작업면입니다.',
      params: { section: 'board' },
    },
    {
      id: 'governance',
      label: '거버넌스',
      description: '의사결정 기록과 판결 흐름을 봅니다.',
      params: { section: 'governance' },
    },
    {
      id: 'evidence',
      label: '근거',
      description: '작업 증거와 검증 결과를 봅니다.',
      params: { section: 'evidence' },
    },
    {
      id: 'planning',
      label: '계획',
      description: '장기 목표와 메트릭 루프를 봅니다.',
      params: { section: 'planning' },
    },
  ],
  operations: [
    {
      id: 'intervene',
      label: '개입',
      description: '방, 세션, 키퍼에 바로 개입하는 화면입니다.',
      params: { section: 'intervene' },
    },
    {
      id: 'command',
      label: '지휘',
      description: '워룸, 스웜, 오케스트라를 포함한 지휘면입니다.',
      params: { section: 'command' },
    },
    {
      id: 'tools',
      label: '도구',
      description: '도구 인벤토리와 도구 메트릭을 봅니다.',
      params: { section: 'tools' },
    },
  ],
  lab: [
    {
      id: 'overview',
      label: '개요',
      description: '실험면의 성격과 진입점을 먼저 보여줍니다.',
      params: { section: 'overview' },
    },
    {
      id: 'trpg',
      label: 'TRPG',
      description: 'TRPG 실험 기능을 분리해 둔 화면입니다.',
      params: { section: 'trpg' },
    },
    {
      id: 'avatars',
      label: '아바타',
      description: '아바타 갤러리와 표현 실험을 봅니다.',
      params: { section: 'avatars' },
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
  if (tabId === 'home') return []
  return DASHBOARD_SECTION_ITEMS[tabId]
}

export function surfaceForTab(tabId: TabId): SurfaceId {
  return tabId
}

export function normalizeRouteParams(tabId: TabId, params: Record<string, string>): Record<string, string> {
  const next = { ...params }

  if (tabId === 'home') {
    delete next.section
    delete next.surface
    return next
  }

  if (tabId === 'status') {
    if (!validSectionIds('status').includes(next.section as SurfaceSectionId)) {
      next.section = 'sessions'
    }
    delete next.surface
    return next
  }

  if (tabId === 'work') {
    if (!validSectionIds('work').includes(next.section as SurfaceSectionId)) {
      next.section = 'board'
    }
    delete next.surface
    return next
  }

  if (tabId === 'operations') {
    if (!validSectionIds('operations').includes(next.section as SurfaceSectionId)) {
      next.section =
        typeof next.surface === 'string' && OPERATIONS_COMMAND_SURFACES.has(next.surface)
          ? 'command'
          : 'intervene'
    }
    if (next.section === 'command') {
      if (next.surface && !OPERATIONS_COMMAND_SURFACES.has(next.surface)) {
        delete next.surface
      }
    } else {
      delete next.surface
    }
    return next
  }

  if (!validSectionIds('lab').includes(next.section as SurfaceSectionId)) {
    if (next.surface === 'trpg' || next.surface === 'avatars') next.section = next.surface
    else next.section = 'overview'
  }
  delete next.surface
  return next
}

export function currentSectionForRoute(routeState: Pick<RouteState, 'tab' | 'params'>): DashboardSectionNavItem | null {
  if (routeState.tab === 'home') return null
  const normalized = normalizeRouteParams(routeState.tab, routeState.params)
  return sectionItemsForTab(routeState.tab).find(item => item.params.section === normalized.section) ?? null
}
