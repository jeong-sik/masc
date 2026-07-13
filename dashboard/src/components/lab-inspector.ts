import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { SectionCard } from './common/card'
import { FeatureHealth } from './feature-health'
import { ServerConfig } from './server-config'
import { navigate } from '../router'

type InspectorSection = 'overview' | 'features' | 'config'

const inspectorSection = signal<InspectorSection>('overview')

interface FocusSurface {
  title: string
  description: string
  action: string
  tab: 'monitoring' | 'command' | 'workspace' | 'lab'
  params: Record<string, string>
}

const FOCUS_SURFACES: FocusSurface[] = [
  {
    title: 'Agent 와 Keeper',
    description: '키퍼 상태, 런타임 품질, 텔레메트리를 가장 빠르게 확인하는 핵심 운영 화면입니다.',
    action: '모니터링으로 이동',
    tab: 'monitoring',
    params: { section: 'agents' },
  },
  {
    title: '운영 큐',
    description: '빠른 개입(QuickIntervene), 흐름 제어, 최근 운영 활동을 한 화면에서 확인합니다. Auto Judge·HITL은 Gate 화면에 있습니다.',
    action: '운영 큐로 이동',
    tab: 'command',
    params: { section: 'operations' },
  },
  {
    title: '보드',
    description: '에이전트 게시판 흐름을 확인해 운영 판단을 뒷받침합니다.',
    action: '작업 화면으로 이동',
    tab: 'workspace',
    params: { section: 'board' },
  },
  {
    title: '하네스',
    description: '안전 레일과 evaluator 흐름까지 이어서 점검할 때 가장 유용합니다.',
    action: '하네스로 이동',
    tab: 'lab',
    params: { section: 'harness' },
  },
]

function InspectorTabButton({
  id,
  label,
}: {
  id: InspectorSection
  label: string
}) {
  const active = inspectorSection.value === id
  return html`
    <button
      type="button"
      class=${[
        'v2-command-action rounded-md border px-3 py-1.5 text-[12px] font-semibold transition-colors min-h-11 min-w-11',
        active
          ? 'border-brand/30 bg-brand/10 text-brand'
          : 'border-border bg-surface-subtle text-text-secondary hover:text-text-primary hover:bg-surface-muted',
      ].join(' ')}
      aria-pressed=${active ? 'true' : 'false'}
      onClick=${() => {
        inspectorSection.value = id
      }}
    >
      ${label}
    </button>
  `
}

function InspectorOverview() {
  return html`
    <div class="grid gap-4">
      <${SectionCard} label="대시보드 포커스" class="section">
        <div class="grid gap-3">
          <div class="v2-command-panel rounded-xl border border-border/35 bg-surface-subtle px-4 py-3 text-[14px] leading-relaxed text-text-primary">
            이제 대시보드는 <strong class="text-text-secondary">핵심 운영 화면</strong>에 더 집중합니다.
            낮은 활용도의 화면은 줄이고, 진짜 자주 보는 상태/개입/근거 화면으로 빠르게 이동할 수 있게 정리했습니다.
          </div>
          <div class="grid grid-cols-[repeat(auto-fit,minmax(220px,1fr))] gap-3">
            ${FOCUS_SURFACES.map(surface => html`
              <div class="v2-command-card rounded-xl border border-border/35 bg-surface-subtle px-4 py-3">
                <div class="text-[14px] font-bold text-text-secondary">${surface.title}</div>
                <div class="mt-2 text-[13px] leading-loose text-text-tertiary">${surface.description}</div>
                <button
                  type="button"
                  class="v2-command-action mt-3 rounded-md border border-brand/25 bg-brand/10 px-2.5 py-1.5 text-[12px] font-semibold text-brand transition-colors hover:bg-brand/20"
                  onClick=${() => navigate(surface.tab, surface.params)}
                >
                  ${surface.action}
                </button>
              </div>
            `)}
          </div>
        </div>
      <//>
    </div>
  `
}

export function LabInspector() {
  const current = inspectorSection.value

  return html`
    <div class="v2-command-surface ss-surface bg-surface-page flex flex-col gap-4 px-6 py-6">
      <${SectionCard} label="운영 인스펙터" class="section v2-command-panel">
        <div class="flex flex-col gap-3">
          <div class="flex flex-wrap gap-2">
            <${InspectorTabButton} id="overview" label="개요" />
            <${InspectorTabButton} id="features" label="피처 플래그" />
            <${InspectorTabButton} id="config" label="서버 설정" />
          </div>
        </div>
      <//>

      ${current === 'overview'
        ? html`<${InspectorOverview} />`
        : current === 'features'
          ? html`<${FeatureHealth} />`
          : html`
              <div class="flex flex-col gap-4">
                <${ServerConfig} />
              </div>
            `}
    </div>
  `
}
