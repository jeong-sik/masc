import type { TabId } from '../types'

export type DashboardNavGroup = 'observe' | 'coordinate' | 'command'

export interface DashboardNavItem {
  id: TabId
  label: string
  icon: string
  group: DashboardNavGroup
  description: string
}

export interface DashboardNavSection {
  id: DashboardNavGroup
  label: string
  description: string
}

export const DASHBOARD_NAV_SECTIONS: DashboardNavSection[] = [
  {
    id: 'observe',
    label: '먼저 보기',
    description: '지금 상태와 우선순위를 먼저 읽는 운영 랜딩',
  },
  {
    id: 'coordinate',
    label: '보조 공간',
    description: '대화, 계획, 에이전트 상태를 보조 작업 공간으로 분리',
  },
  {
    id: 'command',
    label: '통제',
    description: '개입과 지휘를 직접 실행하는 화면',
  },
]

export const DASHBOARD_NAV_ITEMS: DashboardNavItem[] = [
  {
    id: 'mission',
    label: '상황판',
    icon: '\uD83C\uDFE0',
    group: 'observe',
    description: '지금 문제, 다음 액션, 운영 포커스를 먼저 보는 기본 랜딩',
  },
  {
    id: 'intervene',
    label: '개입',
    icon: '\uD83C\uDFAE',
    group: 'command',
    description: 'room, session, supervisor 액션을 실행하는 개입 화면',
  },
  {
    id: 'command',
    label: '지휘',
    icon: '\uD83E\uDDED',
    group: 'command',
    description: '유닛 계층, 작전 체인, 승인, 추적 이력을 보는 상세 화면',
  },
  {
    id: 'agents',
    label: '에이전트',
    icon: '\uD83E\uDD16',
    group: 'observe',
    description: 'agent 상태, 활동 신호, 작업 배정을 보는 모니터',
  },
  {
    id: 'board',
    label: '보드',
    icon: '\uD83D\uDCAC',
    group: 'coordinate',
    description: '사람과 agent 대화를 시스템 노이즈를 줄여서 보는 피드',
  },
  {
    id: 'goals',
    label: '계획',
    icon: '\uD83C\uDFAF',
    group: 'coordinate',
    description: 'goal, 메트릭 루프, backlog를 보는 계획 화면',
  },
  {
    id: 'trpg',
    label: 'TRPG 롤플레이',
    icon: '\u2694\uFE0F',
    group: 'command',
    description: '서사 세션 제어와 게임 상태',
  },
]
