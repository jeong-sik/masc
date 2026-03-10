import type { TabId } from '../types'

export type DashboardNavGroup = 'observe' | 'context' | 'act' | 'lab'

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
    label: 'Observe',
    description: '지금 상태, 실행 압력, 계획 상태를 먼저 읽는 운영 표면',
  },
  {
    id: 'context',
    label: 'Context',
    description: '비동기 메모리와 의사결정 거버넌스를 분리해서 보는 표면',
  },
  {
    id: 'act',
    label: 'Act',
    description: '개입과 system-of-record 지휘를 실행하는 표면',
  },
  {
    id: 'lab',
    label: 'Lab',
    description: '실험적 기능은 메인 operator console 밖으로 분리',
  },
]

export const DASHBOARD_NAV_ITEMS: DashboardNavItem[] = [
  {
    id: 'mission',
    label: 'Mission',
    icon: '\uD83C\uDFE0',
    group: 'observe',
    description: '지금 문제, 다음 액션, 운영 포커스를 먼저 보는 기본 랜딩',
  },
  {
    id: 'execution',
    label: 'Execution',
    icon: '\uD83E\uDD16',
    group: 'observe',
    description: 'worker, task, keeper continuity를 분리해서 보는 실행 표면',
  },
  {
    id: 'planning',
    label: 'Planning',
    icon: '\uD83C\uDFAF',
    group: 'observe',
    description: 'goal, metric loop, backlog 압력을 읽는 계획 표면',
  },
  {
    id: 'memory',
    label: 'Memory',
    icon: '\uD83D\uDCAC',
    group: 'context',
    description: 'posts/comments만으로 room의 비동기 메모리를 읽는 표면',
  },
  {
    id: 'governance',
    label: 'Governance',
    icon: '\u2696\uFE0F',
    group: 'context',
    description: 'debate와 voting만 분리해 의사결정 상태를 보는 표면',
  },
  {
    id: 'intervene',
    label: 'Intervene',
    icon: '\uD83C\uDFAE',
    group: 'act',
    description: 'room, session, keeper 액션을 실행하는 개입 화면',
  },
  {
    id: 'command',
    label: 'Command',
    icon: '\uD83E\uDDED',
    group: 'act',
    description: '유닛 계층, 작전 체인, 승인, 추적 이력을 보는 상세 화면',
  },
  {
    id: 'lab',
    label: 'Lab',
    icon: '\u2694\uFE0F',
    group: 'lab',
    description: 'TRPG 같은 실험 surface를 메인 console 밖에서 다룹니다',
  },
]
