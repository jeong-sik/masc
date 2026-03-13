import type { TabId } from '../types'

export type DashboardNavGroup = 'now' | 'why' | 'act' | 'lab'

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
    id: 'now',
    label: '지금',
    description: '지금 무슨 일이 벌어지는지 사회의 현재 상태를 먼저 읽는 표면',
  },
  {
    id: 'why',
    label: '이유',
    description: '왜 그렇게 보이는지 근거, 메모리, 거버넌스로 뒤를 파는 표면',
  },
  {
    id: 'act',
    label: '개입',
    description: '운영자 액션과 계획 조정을 통해 지금 상태를 바꾸는 표면',
  },
  {
    id: 'lab',
    label: '실험',
    description: '실험적 오케스트레이션과 고급 지휘 표면을 분리해서 보는 영역',
  },
]

export const DASHBOARD_NAV_ITEMS: DashboardNavItem[] = [
  {
    id: 'mission',
    label: '상황판',
    icon: '\uD83C\uDFE0',
    group: 'now',
    description: 'room 중심으로 지금 상황과 사회의 흐름을 가장 먼저 읽는 기본 랜딩',
  },
  {
    id: 'execution',
    label: '실행',
    icon: '\uD83E\uDD16',
    group: 'now',
    description: 'agents, keepers, sessions를 중심으로 사회의 행위자를 읽는 표면',
  },
  {
    id: 'live',
    label: '라이브',
    icon: '\uD83D\uDCE1',
    group: 'now',
    description: '실시간 에이전트 활동과 이벤트 흐름을 사회 관찰 관점으로 보는 표면',
  },
  {
    id: 'proof',
    label: '근거',
    icon: '\uD83D\uDD0D',
    group: 'why',
    description: '협업, 대화, 실행의 증거 경로를 확인하는 표면',
  },
  {
    id: 'memory',
    label: '메모리',
    icon: '\uD83D\uDCAC',
    group: 'why',
    description: '게시글, 댓글, 비동기 기억으로 room의 누적 맥락을 읽는 표면',
  },
  {
    id: 'governance',
    label: '거버넌스',
    icon: '\u2696\uFE0F',
    group: 'why',
    description: '토론, 표결, 판단 구조를 규범과 결정의 관점에서 읽는 표면',
  },
  {
    id: 'planning',
    label: '계획',
    icon: '\uD83C\uDFAF',
    group: 'act',
    description: '목표, 백로그, 압력을 운영 관점으로 읽는 계획 표면',
  },
  {
    id: 'tools',
    label: '도구',
    icon: '\uD83E\uDDF0',
    group: 'act',
    description: '시스템 전체 도구 inventory와 사용 건강도를 확인하는 운영 표면',
  },
  {
    id: 'intervene',
    label: '개입',
    icon: '\uD83C\uDFAE',
    group: 'act',
    description: '룸, 세션, 키퍼에 직접 개입하는 운영 화면',
  },
  {
    id: 'command',
    label: '지휘',
    icon: '\uD83E\uDDED',
    group: 'lab',
    description: 'command-plane, swarm, resolution 같은 고급 지휘/실험 표면',
  },
  {
    id: 'lab',
    label: '실험',
    icon: '\u2694\uFE0F',
    group: 'lab',
    description: 'TRPG 같은 실험 표면을 메인 사회/운영 콘솔 밖에서 다룹니다',
  },
]
