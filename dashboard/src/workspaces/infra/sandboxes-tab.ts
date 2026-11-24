/**
 * Infra L1 Tab 1: Sandboxes
 *
 * - GET /api/v1/infra/sandboxes (V2Envelope per #36)
 * - Displays probe_state, shim_parity, MicroVM guests, SSH pools (+ unbound keepers,
 *   honestly formatting ssh_active_sessions: null as "미보고"!), Docker keepers,
 *   Volume GC / Host storage, unobserved_reasons, and POST /api/v1/infra/sandboxes/probe trigger.
 */

import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import {
  apiGetV2,
  apiMutate,
  formatObserved,
  observedUnreported,
  observedValue,
  resourceCache,
} from '../../core'
import { DataTable, type DataTableColumn } from '../../components/primitives'
import { KeeperBadge } from '../../components/keeper-badge'
import {
  formatUnixTs,
  type InfraDockerKeeper,
  type InfraMicroVmGuest,
  type InfraSandboxesData,
  type InfraSshPool,
  type WorkspaceViewProps,
} from './types'

function parityBadgeStyle(status: InfraSandboxesData['shim_parity']['status']) {
  switch (status) {
    case 'matched':
      return { background: 'var(--ok-soft)', border: '1px solid var(--ok-border)', color: 'var(--ok-fg)' }
    case 'mismatch':
      return { background: 'var(--err-soft)', border: '1px solid var(--err-border)', color: 'var(--err-fg)' }
    case 'undeclared':
      return { background: 'var(--idle-soft)', border: '1px solid var(--idle-border)', color: 'var(--fg-3)' }
    case 'unavailable':
      return { background: 'var(--warn-soft)', border: '1px solid var(--warn-border)', color: 'var(--warn-fg)' }
  }
}

function probeStateStyle(kind: InfraSandboxesData['probe_state']['kind']) {
  switch (kind) {
    case 'fresh':
      return { background: 'var(--ok-soft)', border: '1px solid var(--ok-border)', color: 'var(--ok-fg)' }
    case 'warming':
      return { background: 'var(--info-soft)', border: '1px solid var(--info-border)', color: 'var(--info-fg)' }
    case 'stale':
      return { background: 'var(--warn-soft)', border: '1px solid var(--warn-border)', color: 'var(--warn-fg)' }
    case 'error':
      return { background: 'var(--err-soft)', border: '1px solid var(--err-border)', color: 'var(--err-fg)' }
  }
}

export function SandboxesTab(props: WorkspaceViewProps) {
  const obs = resourceCache.observe<InfraSandboxesData>('infra:sandboxes').value
  const [probing, setProbing] = useState(false)
  const [banner, setBanner] = useState<{ kind: 'ok' | 'err'; text: string } | null>(null)

  const loadSandboxes = (reason: 'mount' | 'manual' = 'mount') => {
    void resourceCache.fetch<InfraSandboxesData>(
      'infra:sandboxes',
      (signal) => apiGetV2<InfraSandboxesData>('/api/v1/infra/sandboxes', { signal }),
      { ttlMs: 15_000, topics: ['infra_sandboxes', 'sandboxes'], reason },
    )
  }

  useEffect(() => {
    loadSandboxes('mount')
  }, [])

  const handleTriggerProbe = async () => {
    setProbing(true)
    setBanner(null)
    const res = await apiMutate<unknown>('POST', '/api/v1/infra/sandboxes/probe', {})
    setProbing(false)
    if (!res.ok) {
      setBanner({ kind: 'err', text: `샌드박스 프로브 실행 실패: ${res.error.message}` })
      return
    }
    setBanner({ kind: 'ok', text: '샌드박스 프로브 요청이 접수되었습니다.' })
    loadSandboxes('manual')
  }

  const microVmColumns = useMemo<readonly DataTableColumn<InfraMicroVmGuest>[]>(() => [
    {
      id: 'name',
      header: '게스트 / Keeper',
      sortable: true,
      sortValue: (r) => r.name ?? r.keeper ?? r.id ?? '',
      cell: (r) => r.keeper
        ? html`<${KeeperBadge} id=${r.keeper} size="sm" />`
        : html`<span class="mono">${r.name ?? r.id ?? '없음'}</span>`,
    },
    { id: 'state', header: '상태', accessor: (r) => r.state ?? r.status ?? null },
    {
      id: 'socket',
      header: '소켓',
      cell: (r) => r.socket_present === undefined
        ? html`<span class="dtable-absent">미보고</span>`
        : html`<span class="mono" style=${{ color: r.socket_present ? 'var(--ok-fg)' : 'var(--err-fg)' }}>${r.socket_present ? 'present' : 'missing'}</span>`,
    },
    { id: 'parity', header: 'Shim Parity', accessor: (r) => r.shim_parity ?? null },
    {
      id: 'pid',
      header: 'PID',
      numeric: true,
      observed: (r) => typeof r.pid === 'number' ? observedValue(r.pid) : observedUnreported(),
    },
  ], [])

  const sshPoolColumns = useMemo<readonly DataTableColumn<InfraSshPool>[]>(() => [
    { id: 'name', header: 'SSH 풀', sortable: true, accessor: (r) => r.name ?? r.id ?? r.host ?? null },
    { id: 'host', header: '호스트', cell: (r) => html`<span class="mono" style=${{ fontSize: 'var(--fs-12)' }}>${r.host ?? '없음'}</span>` },
    {
      id: 'rtt',
      header: 'RTT (ms)',
      numeric: true,
      observed: (r) => typeof r.rtt_ms === 'number' ? observedValue(r.rtt_ms) : observedUnreported(),
      formatValue: (v) => `${Math.round(Number(v))}ms`,
    },
    {
      id: 'sessions',
      header: '활성 / 최대 세션',
      numeric: true,
      cell: (r) => html`
        <span class="mono tnum">
          ${typeof r.active_sessions === 'number' ? r.active_sessions : '미보고'} / ${typeof r.max_sessions === 'number' ? r.max_sessions : '없음'}
        </span>
      `,
    },
    {
      id: 'keepers',
      header: '연결 Keeper 수',
      numeric: true,
      observed: (r) => Array.isArray(r.keepers) ? observedValue(r.keepers.length) : observedUnreported(),
    },
  ], [])

  const dockerColumns = useMemo<readonly DataTableColumn<InfraDockerKeeper>[]>(() => [
    {
      id: 'keeper',
      header: 'Keeper',
      cell: (r) => r.keeper ? html`<${KeeperBadge} id=${r.keeper} size="sm" />` : html`<span class="dtable-absent">없음</span>`,
    },
    { id: 'container', header: '컨테이너', cell: (r) => html`<span class="mono" style=${{ fontSize: 'var(--fs-11)' }}>${r.container_id ?? '없음'}</span>` },
    { id: 'image', header: '이미지', cell: (r) => html`<span class="mono" style=${{ fontSize: 'var(--fs-11)' }}>${r.image ?? '없음'}</span>` },
    { id: 'status', header: '상태', accessor: (r) => r.status ?? null },
  ], [])

  const data = obs.kind === 'value' ? obs.data : null
  const activeSshObs = data
    ? (data.summary.ssh_active_sessions === null ? observedUnreported() : observedValue(data.summary.ssh_active_sessions))
    : observedUnreported()

  return html`
    <div class="ov" data-testid="infra-sandboxes-tab">
      <header class="ov-head">
        <div>
          <span class="ov-eyebrow">6 INFRA · SANDBOXES</span>
          <h1>MicroVM · SSH 풀 · Docker · 볼륨 스토리지</h1>
          <p class="ov-sub">
            ${data ? `마지막 측정: ${formatUnixTs(data.probe_state.measured_at_unix)}` : 'V2 스냅샷 대기 중'}
          </p>
        </div>
        <div style=${{ display: 'flex', alignItems: 'center', gap: 'var(--sp-2)', flexWrap: 'wrap' }}>
          ${data && html`
            <span
              class="mono"
              data-testid="sandbox-probe-state"
              style=${{ ...probeStateStyle(data.probe_state.kind), padding: '3px 8px', borderRadius: 'var(--radius-pill)', fontSize: 'var(--fs-11)', fontWeight: 600 }}
            >
              probe: ${data.probe_state.kind}
            </span>
          `}
          <button type="button" class="btn-primary" disabled=${probing} onClick=${handleTriggerProbe}>
            ${probing ? '프로브 실행 중…' : '지금 프로브 실행'}
          </button>
          <button type="button" class="btn-ghost" onClick=${() => loadSandboxes('manual')}>새로고침</button>
        </div>
      </header>

      ${banner && html`
        <div
          role="status"
          class=${banner.kind === 'err' ? 'ap-error' : 'wka-card'}
          style=${banner.kind === 'ok' ? { borderColor: 'var(--ok-border)', background: 'var(--ok-soft)', color: 'var(--ok-fg)' } : undefined}
        >
          ${banner.text}
        </div>
      `}

      ${obs.kind === 'loading' && html`<div class="wka-card dtable-absent">샌드박스 인벤토리 불러오는 중…</div>`}

      ${obs.kind === 'failed' && html`
        <div class="ap-error" role="alert">
          ${obs.error.kind === 'forbidden'
            ? '관리자(Admin) 권한이 필요한 플리트 샌드박스 뷰입니다 (HTTP 403).'
            : `샌드박스 조회 실패: ${obs.error.message}`}
        </div>
      `}

      ${data && html`
        <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-4)', minWidth: 0 }}>
          ${data.probe_state.kind === 'error' && data.probe_state.error && html`
            <div class="ap-error" role="alert">프로브 오류: ${data.probe_state.error}</div>
          `}

          <section class="ov-kpis" aria-label="샌드박스 요약 KPI">
            <div class="ov-kpi">
              <div class="ov-kpi-k">MicroVM 실행 / 선언</div>
              <div class="ov-kpi-v ok">${data.summary.microvm_running} / ${data.summary.microvm_declared}</div>
            </div>
            <div class="ov-kpi">
              <div class="ov-kpi-k">소켓 정상 / Shim 불일치</div>
              <div class=${`ov-kpi-v ${data.summary.microvm_shim_mismatch > 0 ? 'bad' : ''}`}>
                ${data.summary.microvm_sockets_present} / ${data.summary.microvm_shim_mismatch}
              </div>
            </div>
            <div class="ov-kpi">
              <div class="ov-kpi-k">SSH 풀 / 활성 세션</div>
              <div class="ov-kpi-v">
                ${data.summary.ssh_pools} (${formatObserved(activeSshObs)} / ${data.summary.ssh_max_sessions})
              </div>
            </div>
            <div class="ov-kpi">
              <div class="ov-kpi-k">Docker Keepers</div>
              <div class="ov-kpi-v">${data.summary.docker_keepers}</div>
            </div>
          </section>

          <!-- Shim Parity Card -->
          <section class="wka-card" data-testid="sandbox-shim-parity" style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)' }}>
            <div class="wka-h">
              <h3>Shim Parity 검증</h3>
              <span
                class="mono"
                style=${{ ...parityBadgeStyle(data.shim_parity.status), padding: '2px 8px', borderRadius: 'var(--radius-pill)', fontSize: 'var(--fs-11)', fontWeight: 600 }}
              >
                ${data.shim_parity.status}
              </span>
            </div>
            <div class="mono" style=${{ display: 'flex', flexWrap: 'wrap', gap: 'var(--sp-3)', fontSize: 'var(--fs-11)', color: 'var(--fg-2)' }}>
              <span>build: ${data.shim_parity.build_identity ?? '없음'}</span>
              <span>shim: ${data.shim_parity.shim_identity ?? '없음'}</span>
              <span>server: ${data.shim_parity.server_identity ?? '없음'}</span>
            </div>
            ${data.shim_parity.detail && html`
              <div style=${{ fontSize: 'var(--fs-12)', color: 'var(--fg-2)' }}>${data.shim_parity.detail}</div>
            `}
          </section>

          <!-- Unobserved Reasons (Honesty contract) -->
          ${data.unobserved_reasons.length > 0 && html`
            <section class="ap-error sev-warn" data-testid="sandbox-unobserved-reasons">
              <strong>미관측 사유 (${data.unobserved_reasons.length}건):</strong>
              <ul style=${{ margin: 'var(--sp-1) 0 0', paddingLeft: '18px', fontSize: 'var(--fs-12)' }}>
                ${data.unobserved_reasons.map((item, idx) => html`
                  <li key=${`${item.scope}-${idx}`}>
                    <span class="mono">${item.scope}</span>: ${item.reason}
                  </li>
                `)}
              </ul>
            </section>
          `}

          <!-- MicroVM Guests -->
          <section style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)', minWidth: 0 }}>
            <h3 style=${{ margin: 0, fontSize: 'var(--fs-13)' }}>MicroVM 게스트 (${data.microvm_guests.length})</h3>
            <${DataTable}
              data=${data.microvm_guests}
              columns=${microVmColumns}
              getRowId=${(r: InfraMicroVmGuest, i: number) => r.id ?? r.name ?? `vm-${i}`}
              virtualizeThreshold=${30}
              maxHeight=${320}
              emptyLabel="선언된 MicroVM 게스트 없음"
            />
          </section>

          <!-- SSH Pools -->
          <section style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)', minWidth: 0 }}>
            <div class="wka-h">
              <h3>SSH 풀 (${data.ssh_pools.length}) · 미바인딩 Keeper ${data.summary.ssh_unbound_keepers}명</h3>
            </div>
            <${DataTable}
              data=${data.ssh_pools}
              columns=${sshPoolColumns}
              getRowId=${(r: InfraSshPool, i: number) => r.id ?? r.name ?? `ssh-${i}`}
              virtualizeThreshold=${30}
              maxHeight=${300}
              emptyLabel="등록된 SSH 풀 없음"
            />
          </section>

          <!-- Docker Keepers -->
          <section style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)', minWidth: 0 }}>
            <h3 style=${{ margin: 0, fontSize: 'var(--fs-13)' }}>Docker Keepers (${data.docker_keepers.length})</h3>
            <${DataTable}
              data=${data.docker_keepers}
              columns=${dockerColumns}
              getRowId=${(r: InfraDockerKeeper, i: number) => r.container_id ?? r.keeper ?? `dk-${i}`}
              virtualizeThreshold=${30}
              maxHeight=${280}
              emptyLabel="실행 중인 Docker Keeper 없음"
            />
          </section>

          <!-- Volume GC & Host Storage -->
          <section style=${{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(280px, 1fr))', gap: 'var(--sp-3)', minWidth: 0 }}>
            <div class="wka-card">
              <div class="wka-h">
                <h3>Volume GC 리포트</h3>
                <button
                  type="button"
                  class="btn-ghost"
                  onClick=${() => props.onInspect({
                    title: 'Volume GC Report',
                    kind: 'volume_gc',
                    data: data.volume_gc_report,
                    render: () => html`<pre class="mono" style=${{ margin: 0, fontSize: 'var(--fs-11)', whiteSpace: 'pre-wrap' }}>${JSON.stringify(data.volume_gc_report, null, 2)}</pre>`,
                  })}
                >
                  [⤢] 원본
                </button>
              </div>
              <pre class="mono" style=${{ margin: 0, fontSize: 'var(--fs-11)', overflowX: 'auto', whiteSpace: 'pre-wrap', color: 'var(--fg-2)' }}>
                ${data.volume_gc_report ? JSON.stringify(data.volume_gc_report, null, 2) : '없음'}
              </pre>
            </div>

            <div class="wka-card">
              <div class="wka-h">
                <h3>호스트 스토리지</h3>
                <button
                  type="button"
                  class="btn-ghost"
                  onClick=${() => props.onInspect({
                    title: 'Host Storage',
                    kind: 'host_storage',
                    data: data.host_storage,
                    render: () => html`<pre class="mono" style=${{ margin: 0, fontSize: 'var(--fs-11)', whiteSpace: 'pre-wrap' }}>${JSON.stringify(data.host_storage, null, 2)}</pre>`,
                  })}
                >
                  [⤢] 원본
                </button>
              </div>
              <pre class="mono" style=${{ margin: 0, fontSize: 'var(--fs-11)', overflowX: 'auto', whiteSpace: 'pre-wrap', color: 'var(--fg-2)' }}>
                ${data.host_storage ? JSON.stringify(data.host_storage, null, 2) : '없음'}
              </pre>
            </div>
          </section>
        </div>
      `}
    </div>
  `
}
