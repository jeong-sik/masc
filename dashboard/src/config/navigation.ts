import type { TabId } from '../types'

// --- Surface grouping: 12 tabs -> 5 surfaces ---

export type SurfaceId = 'home' | 'agents' | 'work' | 'control' | 'lab'

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
    icon: '\uD83C\uDFE0',
    description: '에이전트 생태계 전체를 한눈에',
    defaultTab: 'home',
    tabs: ['home'],
  },
  {
    id: 'agents',
    label: '에이전트',
    icon: '\uD83E\uDD16',
    description: '에이전트, 키퍼, 세션, 관계',
    defaultTab: 'agent-roster',
    tabs: ['agent-roster', 'keeper-roster', 'mission', 'execution', 'live', 'social'],
  },
  {
    id: 'work',
    label: '작업',
    icon: '\uD83D\uDCCB',
    description: '태스크, 근거, 거버넌스, 메모리',
    defaultTab: 'proof',
    tabs: ['proof', 'memory', 'governance'],
  },
  {
    id: 'control',
    label: '운영',
    icon: '\uD83C\uDFAE',
    description: '목표, 도구, 개입',
    defaultTab: 'planning',
    tabs: ['planning', 'tools', 'intervene'],
  },
  {
    id: 'lab',
    label: '실험',
    icon: '\u2694\uFE0F',
    description: '지휘, TRPG, 실험',
    defaultTab: 'command',
    tabs: ['command', 'lab'],
  },
]

// Full nav item list (all 13 tabs including 'home')
export const DASHBOARD_NAV_ITEMS: DashboardNavItem[] = [
  {
    id: 'home',
    label: '홈',
    icon: '\uD83C\uDFE0',
    group: 'home',
    description: '에이전트 생태계 전체를 한눈에 보는 개요',
  },
  {
    id: 'agent-roster',
    label: '에이전트 목록',
    icon: '\uD83D\uDC65',
    group: 'agents',
    description: '전체 에이전트를 스크롤하며 탐색하는 목록 화면',
  },
  {
    id: 'keeper-roster',
    label: '키퍼 목록',
    icon: '\uD83D\uDEE1\uFE0F',
    group: 'agents',
    description: '전체 키퍼를 스크롤하며 탐색하는 목록 화면',
  },
  {
    id: 'mission',
    label: '상황판',
    icon: '\uD83C\uDFE0',
    group: 'agents',
    description: '방 중심으로 지금 상황과 흐름을 가장 먼저 읽는 기본 화면',
  },
  {
    id: 'execution',
    label: '실행',
    icon: '\uD83E\uDD16',
    group: 'agents',
    description: '에이전트, 키퍼, 세션을 중심으로 참여자를 파악하는 화면',
  },
  {
    id: 'live',
    label: '라이브',
    icon: '\uD83D\uDCE1',
    group: 'agents',
    description: '실시간 에이전트 활동과 이벤트 흐름을 관찰하는 화면',
  },
  {
    id: 'social',
    label: '소셜',
    icon: '\uD83D\uDD17',
    group: 'agents',
    description: '에이전트 관계 그래프와 활동 흐름을 보는 관계 분석 화면',
  },
  {
    id: 'proof',
    label: '근거',
    icon: '\uD83D\uDD0D',
    group: 'work',
    description: '협업, 대화, 실행의 증거 경로를 확인하는 화면',
  },
  {
    id: 'memory',
    label: '메모리',
    icon: '\uD83D\uDCAC',
    group: 'work',
    description: '게시글, 댓글, 비동기 기억으로 방의 누적 맥락을 읽는 화면',
  },
  {
    id: 'governance',
    label: '거버넌스',
    icon: '\u2696\uFE0F',
    group: 'work',
    description: '토론, 표결, 판단 구조를 규범과 결정의 관점에서 읽는 화면',
  },
  {
    id: 'planning',
    label: '계획',
    icon: '\uD83C\uDFAF',
    group: 'control',
    description: '목표, 백로그, 우선순위를 운영 관점으로 읽는 계획 화면',
  },
  {
    id: 'tools',
    label: '도구',
    icon: '\uD83E\uDDF0',
    group: 'control',
    description: '시스템 전체 도구 목록과 사용 현황을 확인하는 운영 화면',
  },
  {
    id: 'intervene',
    label: '개입',
    icon: '\uD83C\uDFAE',
    group: 'control',
    description: '룸, 세션, 키퍼에 직접 개입하는 운영 화면',
  },
  {
    id: 'command',
    label: '지휘',
    icon: '\uD83E\uDDED',
    group: 'lab',
    description: 'command-plane, swarm, resolution 같은 고급 지휘/실험 화면',
  },
  {
    id: 'lab',
    label: '실험',
    icon: '\u2694\uFE0F',
    group: 'lab',
    description: 'TRPG 같은 실험 기능을 메인 대시보드 밖에서 다룹니다',
  },
]

// Legacy compatibility: old section types used by SideRail
export type DashboardNavGroupLegacy = 'now' | 'why' | 'act' | 'lab'

export interface DashboardNavSection {
  id: DashboardNavGroupLegacy
  label: string
  description: string
}

// Kept for backward compat — unused in the new nav but referenced by semantic-layer
export const DASHBOARD_NAV_SECTIONS: DashboardNavSection[] = [
  { id: 'now', label: '지금', description: '현재 상태' },
  { id: 'why', label: '이유', description: '근거와 맥락' },
  { id: 'act', label: '개입', description: '운영 액션' },
  { id: 'lab', label: '실험', description: '실험 화면' },
]

// Surface lookup by tab id
export function surfaceForTab(tabId: TabId): SurfaceId {
  for (const surface of DASHBOARD_SURFACES) {
    if (surface.tabs.includes(tabId)) return surface.id
  }
  return 'home'
}
