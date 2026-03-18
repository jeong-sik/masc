import type { TabId } from '../types'

// --- Surface grouping: 7 tabs -> 5 surfaces ---

export type SurfaceId = 'home' | 'observe' | 'work' | 'control' | 'lab'

export interface DashboardNavGroup {
  id: SurfaceId
  label: string
  icon: string
  description: string
  defaultTab: TabId
  tabs: TabId[]
}

export interface DashboardNavItem {
  id: TabId
  label: string
  icon: string
  group: SurfaceId
  description: string
}

// 5 primary surfaces
export const DASHBOARD_SURFACES: DashboardNavGroup[] = [
  {
    id: 'home',
    label: '홈',
    icon: '🏠',
    description: '에이전트 생태계 전체를 한눈에',
    defaultTab: 'home',
    tabs: ['home'],
  },
  {
    id: 'observe',
    label: '관찰',
    icon: '🔭',
    description: '에이전트, 상황, 활동 흐름',
    defaultTab: 'situation',
    tabs: ['situation', 'agents', 'activity'],
  },
  {
    id: 'work',
    label: '작업',
    icon: '📋',
    description: '게시판, 거버넌스, 근거, 계획',
    defaultTab: 'work',
    tabs: ['work'],
  },
  {
    id: 'control',
    label: '운영',
    icon: '🎮',
    description: '개입, 도구 현황',
    defaultTab: 'control',
    tabs: ['control'],
  },
  {
    id: 'lab',
    label: '실험',
    icon: '⚗️',
    description: '지휘, TRPG, 실험',
    defaultTab: 'lab',
    tabs: ['lab'],
  },
]

// Full nav item list (all 7 tabs)
export const DASHBOARD_NAV_ITEMS: DashboardNavItem[] = [
  {
    id: 'home',
    label: '홈',
    icon: '🏠',
    group: 'home',
    description: '에이전트 생태계 전체를 한눈에 보는 개요',
  },
  {
    id: 'situation',
    label: '상황판',
    icon: '🏠',
    group: 'observe',
    description: '방 중심으로 지금 상황과 흐름을 가장 먼저 읽는 기본 화면',
  },
  {
    id: 'agents',
    label: '에이전트',
    icon: '👥',
    group: 'observe',
    description: '에이전트, 키퍼, 세션을 한곳에서 탐색',
  },
  {
    id: 'activity',
    label: '활동',
    icon: '📡',
    group: 'observe',
    description: '실시간 이벤트 흐름과 소셜 그래프',
  },
  {
    id: 'work',
    label: '작업',
    icon: '📋',
    group: 'work',
    description: '게시판, 거버넌스, 근거, 계획을 서브섹션으로 탐색',
  },
  {
    id: 'control',
    label: '운영',
    icon: '🎮',
    group: 'control',
    description: '룸/세션/키퍼에 직접 개입하고 도구 현황을 확인',
  },
  {
    id: 'lab',
    label: '실험',
    icon: '⚗️',
    group: 'lab',
    description: '지휘면, TRPG 등 실험 기능',
  },
]

// Surface lookup by tab id
export function surfaceForTab(tabId: TabId): SurfaceId {
  for (const surface of DASHBOARD_SURFACES) {
    if (surface.tabs.includes(tabId)) return surface.id
  }
  return 'home'
}
