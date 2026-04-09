import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { Card } from './common/card'
import { FeatureHealth } from './feature-health'
import { ServerConfig } from './server-config'
import { ExcusePatterns } from './excuse-patterns'
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
    title: 'Agents & Keepers',
    description: '키퍼 상태, 런타임 품질, 텔레메트리를 가장 빠르게 확인하는 핵심 운영 화면입니다.',
    action: '모니터링으로 이동',
    tab: 'monitoring',
    params: { section: 'agents' },
  },
  {
    title: 'Ops Queue',
    description: '자동 판단, review queue, 승인 대기, 실행 경로를 한 화면에서 확인합니다.',
    action: '운영 큐로 이동',
    tab: 'command',
    params: { section: 'intervene' },
  },
  {
    title: 'Board & Evidence',
    description: '실제 협업 근거와 게시판 흐름을 확인해 운영 판단을 뒷받침합니다.',
    action: '작업 화면으로 이동',
    tab: 'workspace',
    params: { section: 'evidence' },
  },
  {
    title: 'Harness',
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
        'rounded-full border px-3 py-1.5 text-[11px] font-semibold transition-colors',
        active
          ? 'border-accent/30 bg-[var(--accent-10)] text-[var(--accent)]'
          : 'border-card-border bg-[var(--white-3)] text-[var(--text-muted)] hover:text-[var(--text-body)] hover:bg-[var(--white-6)]',
      ].join(' ')}
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
      <${Card} title="Dashboard Focus" class="section">
        <div class="grid gap-3">
          <div class="rounded-xl border border-card-border/35 bg-black/10 px-4 py-3 text-[13px] leading-[1.7] text-[var(--text-body)]">
            이제 대시보드는 <strong class="text-[var(--text-strong)]">핵심 운영 화면</strong>에 더 집중합니다.
            낮은 활용도의 화면은 줄이고, 진짜 자주 보는 상태/개입/근거 화면으로 빠르게 이동할 수 있게 정리했습니다.
          </div>
          <div class="grid grid-cols-[repeat(auto-fit,minmax(220px,1fr))] gap-3">
            ${FOCUS_SURFACES.map(surface => html`
              <div class="rounded-xl border border-card-border/35 bg-black/10 px-4 py-3">
                <div class="text-[12px] font-semibold text-[var(--text-strong)]">${surface.title}</div>
                <div class="mt-2 text-[11px] leading-[1.6] text-[var(--text-muted)]">${surface.description}</div>
                <button
                  type="button"
                  class="mt-3 rounded-lg border border-accent/25 bg-[var(--accent-10)] px-2.5 py-1.5 text-[11px] font-semibold text-[var(--accent)] transition-colors hover:bg-[var(--accent-20)]"
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
    <div class="flex flex-col gap-4">
      <${Card} title="운영 인스펙터" class="section">
        <div class="flex flex-col gap-3">
          <div class="text-[13px] leading-[1.7] text-[var(--text-body)]">
            피처 플래그와 서버 설정을 한 곳에서 보고, 대시보드에서 실제 자주 쓰는 운영 화면으로 빠르게 이동합니다.
          </div>
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
                <${ExcusePatterns} />
              </div>
            `}
    </div>
  `
}
