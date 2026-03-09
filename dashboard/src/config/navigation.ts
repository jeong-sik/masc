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
    label: 'Monitor',
    description: '지금 상태와 우선순위를 먼저 읽는 운영 랜딩',
  },
  {
    id: 'coordinate',
    label: 'Workspace',
    description: '대화, 계획, 에이전트 상태를 보조 작업 공간으로 분리',
  },
  {
    id: 'command',
    label: 'Act',
    description: '개입과 지휘를 실제로 실행하는 표면',
  },
]

// Primary IA for the side rail navigation.
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
    description: 'room/session/keeper 액션을 실제로 실행하는 intervention workspace',
  },
  {
    id: 'command',
    label: '지휘',
    icon: '\uD83E\uDDED',
    group: 'command',
    description: 'command plane, swarm, trace, approvals를 drill-down으로 보는 상세 화면',
  },
  {
    id: 'agents',
    label: 'Agents',
    icon: '\uD83E\uDD16',
    group: 'observe',
    description: 'Live monitor for agent status, keeper pressure, and current execution focus',
  },
  {
    id: 'board',
    label: 'Board',
    icon: '\uD83D\uDCAC',
    group: 'coordinate',
    description: 'Human and agent discussion feed with system noise filtered by default',
  },
  {
    id: 'goals',
    label: 'Planning',
    icon: '\uD83C\uDFAF',
    group: 'coordinate',
    description: 'Goals, MDAL loops, and task backlog in one planning surface',
  },
  {
    id: 'trpg',
    label: 'TRPG',
    icon: '\u2694\uFE0F',
    group: 'command',
    description: 'Narrative room control and state visibility',
  },
]
