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
    label: '관찰',
    description: '지금 상태, 실행 압력, 계획 상태를 먼저 읽는 운영 표면',
  },
  {
    id: 'context',
    label: '맥락',
    description: '비동기 메모리와 의사결정 거버넌스를 분리해서 보는 표면',
  },
  {
    id: 'act',
    label: '개입',
    description: '개입과 운영 기준 지휘를 실행하는 표면',
  },
  {
    id: 'lab',
    label: '실험',
    description: '실험적 기능은 메인 operator console 밖으로 분리',
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
    id: 'proof',
    label: '근거',
    icon: '\uD83D\uDD0D',
    group: 'observe',
    description: '협업, 대화, 도구, 근거 기록을 증명 중심으로 읽는 표면',
  },
  {
    id: 'execution',
    label: '실행',
    icon: '\uD83E\uDD16',
    group: 'observe',
    description: '워커, 태스크, 키퍼 연속성을 분리해서 보는 실행 표면',
  },
  {
    id: 'live',
    label: '라이브',
    icon: '\uD83D\uDCE1',
    group: 'observe',
    description: '실시간 에이전트 활동과 이벤트 스트림을 한눈에 모니터링',
  },
  {
    id: 'planning',
    label: '계획',
    icon: '\uD83C\uDFAF',
    group: 'observe',
    description: '목표, 지표 루프, 백로그 압력을 읽는 계획 표면',
  },
  {
    id: 'memory',
    label: '메모리',
    icon: '\uD83D\uDCAC',
    group: 'context',
    description: '게시글과 댓글로 room의 비동기 메모리를 읽는 표면',
  },
  {
    id: 'governance',
    label: '거버넌스',
    icon: '\u2696\uFE0F',
    group: 'context',
    description: '토론과 표결을 분리해 의사결정 상태를 보는 표면',
  },
  {
    id: 'intervene',
    label: '개입',
    icon: '\uD83C\uDFAE',
    group: 'act',
    description: '룸, 세션, 키퍼 액션을 실행하는 개입 화면',
  },
  {
    id: 'command',
    label: '지휘',
    icon: '\uD83E\uDDED',
    group: 'act',
    description: '유닛 계층, 작전 체인, 승인, 추적 이력을 보는 상세 화면',
  },
  {
    id: 'lab',
    label: '실험',
    icon: '\u2694\uFE0F',
    group: 'lab',
    description: 'TRPG 같은 실험 표면을 메인 콘솔 밖에서 다룹니다',
  },
]
