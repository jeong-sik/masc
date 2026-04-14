import type { RouteState, TabId } from '../types'

export type SurfaceId = TabId
export type SurfaceSectionId =
  | 'observatory'
  | 'agents'
  | 'activity'
  | 'board'
  | 'governance'
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
  | 'connectors'
  | 'memory-subsystems'
  | 'fsm-hub'
  | 'metrics'

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
    description: '에이전트/키퍼 현황 및 observability 관찰',
    defaultTab: 'monitoring',
    defaultParams: { section: 'agents' },
    tabs: ['monitoring'],
  },
  {
    id: 'command',
    label: '운영',
    icon: '🎛️',
    description: '실시간 개입과 거버넌스 판단/승인 운영 화면',
    defaultTab: 'command',
    defaultParams: { section: 'intervene' },
    tabs: ['command'],
  },
  {
    id: 'workspace',
    label: '작업',
    icon: '📋',
    description: '작업 게시판, 증명/판정, 계획 이력 탐색',
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
      id: 'observatory',
      label: '관찰소 (beta)',
      description: '이벤트/메트릭을 단일 timeline에 통합. RFC-MASC-006 Phase 2a.',
      params: { section: 'observatory' },
    },
    {
      id: 'agents',
      label: '에이전트 & 키퍼',
      description: '이름과 운영 상태를 함께 봅니다. 세션 요약은 오버뷰에서.',
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
    {
      id: 'governance',
      label: '도구 이벤트',
      description: '읽기 전용: 도구 거부 집계, 승인 큐 깊이/지연. 승인 액션은 운영 › 거버넌스에서.',
      params: { section: 'governance' },
    },
    {
      id: 'memory-subsystems',
      label: '기억 서브시스템',
      description: 'Hebbian 시냅스 그래프, 에피소드 기록, compaction 상태.',
      params: { section: 'memory-subsystems' },
    },
    {
      id: 'fsm-hub',
      label: 'FSM 허브',
      description: 'Composite lifecycle — Decision/Cascade/Memory/Compaction FSM 교차 뷰와 invariants.',
      params: { section: 'fsm-hub' },
    },
    {
      id: 'metrics',
      label: 'Prometheus',
      description: '저수준 raw 지표(/metrics): counter·gauge·summary. 디버깅과 알림 소스용.',
      params: { section: 'metrics' },
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
  command: [
    {
      id: 'intervene',
      label: '실시간 개입',
      description: '쓰기 액션: 네임스페이스 브로드캐스트, 키퍼에게 직접 메시지 발송. 세션 읽기는 모니터링 › 세션에서.',
      params: { section: 'intervene' },
    },
    {
      id: 'governance',
      label: '승인 큐',
      description: '쓰기 액션: 자율 결정 검토·승인·반려. 추이 관찰은 모니터링 › 도구 이벤트에서.',
      params: { section: 'governance' },
    },
    {
      id: 'connectors',
      label: '커넥터',
      description: '외부 채널(Discord 등) 연결 상태, 바인딩 관리, 이벤트 로그.',
      params: { section: 'connectors' },
    },
    {
      id: 'inspector',
      label: '운영 인스펙터',
      description: '피처 플래그와 서버 설정을 한 화면으로 묶은 운영 진단/점검 화면.',
      params: { section: 'inspector' },
    },
  ],
  workspace: [
    {
      id: 'board',
      label: '작업 게시판',
      description: '에이전트가 남긴 직접 작성 글, 자동화 글, 시스템 글을 한 곳에서 봅니다.',
      params: { section: 'board' },
    },
    {
      id: 'planning',
      label: '작업 큐',
      description: '실행 단위의 칸반과 백로그. 상위 의도 구조는 목표 트리에서.',
      params: { section: 'planning' },
    },
    {
      id: 'goals',
      label: '목표 트리',
      description: '의도의 부모-자식 계층과 수렴도. 실행 단위 태스크는 작업 큐에서.',
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
      description: '평가 모델, 압축 전 상태, 세대 교체 rail 감시 상태.',
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

  // Phase 0 (RFC-MASC-006): sessions stub removed — redirect to agents
  if (tabId === 'monitoring' && next.section === 'sessions') {
    next.section = 'agents'
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
