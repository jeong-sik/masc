// MASC Dashboard — Approvals Surface
// Dedicated operator view of the Keeper HITL approval queue: keeper tool calls
// gated above the risk threshold wait here for an approve / approve+always / reject
// decision. This is a focused, standalone surface; the broader Governance panel
// (Command surface) keeps its rules/decisions/monitoring role and shares the SAME
// underlying signal + action, so resolving here updates both.
//
// Data source: governanceData.value?.approval_queue (KeeperApprovalQueueItem[]).
// Actions: respondToKeeperApproval(id, 'approve' | 'reject', rememberRule).
// The live decision model is the closed set {approve, reject} (+ rememberRule);
// there is no defer/undo endpoint, so the prototype's 보류/되돌리기/처리이력 are
// intentionally not rendered. Visual layout ports the keeper-v2 .ap-* design.

import { html } from 'htm/preact'
import { useEffect, useMemo } from 'preact/hooks'
import type { KeeperApprovalQueueItem } from '../../types'
import { TELEMETRY_AUTO_REFRESH_MS } from '../../config/constants'
import { setupVisibleAutoRefresh } from '../../lib/auto-refresh'
import { navigate } from '../../router'
import { AgentAvatar } from '../overview/agent-avatar'
import {
  governanceData,
  governanceError,
  governanceApprovalActing,
  refreshGovernance,
  respondToKeeperApproval,
} from '../governance-store'

type Sev = 'bad' | 'warn' | 'info'

// risk_level → prototype severity rail. critical/high are the irreversible-risk
// band; medium warns; low/unknown is informational. Mirrors the live
// approvalRiskToneClass banding (governance.ts) but emits the .ap- sev token.
function apSev(riskLevel: string | null | undefined): Sev {
  const r = (riskLevel ?? '').trim().toLowerCase()
  if (r === 'critical' || r === 'high') return 'bad'
  if (r === 'medium') return 'warn'
  return 'info'
}

// seconds-waited → "N분 N초 대기" (prototype apAge).
function apAge(sec: number | null | undefined): string {
  const s = Math.max(0, Math.round(sec ?? 0))
  const m = Math.floor(s / 60)
  const r = s % 60
  return m ? `${m}분 ${r}초 대기` : `${r}초 대기`
}

// Open this keeper's workspace conversation (work.ts idiom).
function openKeeperWorkspace(name: string): void {
  navigate('monitoring', { section: 'agents', view: 'keepers', keeper: name })
}

function ApprovalCard({ item }: { item: KeeperApprovalQueueItem }) {
  const sev = apSev(item.risk_level)
  const actingId = governanceApprovalActing.value
  const busy = actingId === item.id
  const anyBusy = Boolean(actingId)
  const title = item.action_key?.trim() || `${item.tool_name} 실행 승인 요청`
  const sandbox = item.runtime_contract?.sandbox_profile?.trim() || item.sandbox_target?.trim() || null
  const detailReason = item.disposition_reason?.trim() || null

  return html`
    <article class=${`ap-card sev-${sev}`} data-testid="approval-card" data-approval-id=${item.id}>
      <div class="ap-rail"></div>
      <div class="ap-main">
        <div class="ap-h">
          <span class=${`ap-kind sev-${sev}`}>${(item.risk_level ?? 'unknown').toUpperCase()}</span>
          <span class="ap-tool mono">${item.tool_name}</span>
          <span class="ap-id mono">${item.id}</span>
          <span class=${`ap-age sev-${sev}`}>${apAge(item.waiting_s)}</span>
        </div>
        <h3 class="ap-title">${title}</h3>
        ${detailReason ? html`<p class="ap-detail">${detailReason}</p>` : null}
        <div class="ap-req">
          <${AgentAvatar} name=${item.keeper_name} size="sm" />
          <div class="ap-req-body">
            <div class="ap-req-who">
              <button
                type="button"
                class="ap-klink"
                onClick=${() => openKeeperWorkspace(item.keeper_name)}
                title=${`${item.keeper_name} 대화 열기`}
              >${item.keeper_name}</button>
              ${item.task_id || item.goal_id
                ? html`<button
                    type="button"
                    class="ap-req-goal mono"
                    onClick=${() => navigate('workspace', { section: 'work' })}
                    title="작업 보기"
                  >${[item.task_id ? `task ${item.task_id}` : null, item.goal_id ? `goal ${item.goal_id}` : null]
                    .filter(Boolean)
                    .join(' · ')}</button>`
                : null}
              ${sandbox ? html`<span class="ap-req-goal mono">sandbox ${sandbox}</span>` : null}
            </div>
            <div class="ap-req-quote">
              ${item.input_preview?.trim() ? `“${item.input_preview.trim()}”` : '입력 미리보기 없음'}
            </div>
          </div>
        </div>
        <div class="ap-actions">
          <button
            type="button"
            class="ap-act approve"
            onClick=${() => void respondToKeeperApproval(item.id, 'approve')}
            disabled=${anyBusy}
          >${busy ? '처리 중…' : '승인'}</button>
          <button
            type="button"
            class="ap-act always"
            onClick=${() => void respondToKeeperApproval(item.id, 'approve', true)}
            title="승인하고 동일 요청을 자동 승인하는 Always 규칙을 저장합니다"
            disabled=${anyBusy}
          >${busy ? '처리 중…' : '항상 승인'}</button>
          <button
            type="button"
            class="ap-act deny"
            onClick=${() => void respondToKeeperApproval(item.id, 'reject')}
            disabled=${anyBusy}
          >${busy ? '처리 중…' : '거부'}</button>
          <button
            type="button"
            class="ap-act ghost"
            onClick=${() => openKeeperWorkspace(item.keeper_name)}
            title="맥락 보기"
            disabled=${anyBusy}
          >대화에서 검토 →</button>
        </div>
      </div>
    </article>
  `
}

export function ApprovalsSurface() {
  useEffect(() => {
    void refreshGovernance()
    const disposeAutoRefresh = setupVisibleAutoRefresh(refreshGovernance, TELEMETRY_AUTO_REFRESH_MS)
    return () => {
      disposeAutoRefresh()
    }
  }, [])

  const items = governanceData.value?.approval_queue ?? []
  const error = governanceError.value

  const stats = useMemo(() => {
    const risky = items.filter(i => apSev(i.risk_level) === 'bad').length
    const longest = items.reduce((max, i) => Math.max(max, i.waiting_s ?? 0), 0)
    const keepers = new Set(items.map(i => i.keeper_name)).size
    return { risky, longest, keepers }
  }, [items])

  return html`
    <main class="ov ss-surface bg-surface-page text-text-primary" data-testid="approvals-surface">
      <div class="ov-scroll">
        <header class="ov-head">
          <div>
            <h1>승인 · HITL 큐</h1>
            <p class="ov-sub">
              keeper가 위험·비가역 행동 전 결재를 청한 항목 ·
              <span title="감독자가 보는 단일 결재 지점">operator가 직접 승인·거부</span>
            </p>
          </div>
          ${items.length > 0
            ? html`<span class="ap-sla mono" title="가장 오래 대기 중인 건">최장 대기 ${apAge(stats.longest)}</span>`
            : null}
        </header>

        ${error ? html`<div class="ap-error" data-testid="approvals-error">${error}</div>` : null}

        <section class="ov-kpis" style=${{ gridTemplateColumns: 'repeat(4, 1fr)' }}>
          <div class="ov-kpi">
            <div class="ov-kpi-k">열린 승인</div>
            <div class=${`ov-kpi-v ${items.length ? 'warn' : 'ok'}`}>${items.length}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">위험 · 높음</div>
            <div class=${`ov-kpi-v ${stats.risky ? 'bad' : ''}`}>${stats.risky}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">최장 대기</div>
            <div class="ov-kpi-v">${items.length ? apAge(stats.longest) : '—'}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">관련 키퍼</div>
            <div class="ov-kpi-v volt">${stats.keepers}</div>
          </div>
        </section>

        ${items.length === 0
          ? html`
              <div class="ap-clear" data-testid="approvals-empty">
                <div class="ico">${'✓'}</div>
                <h3>열린 승인이 없습니다</h3>
                <div class="ap-clear-sub">HITL 큐가 비어 있습니다 — keeper들이 결재 대기 없이 진행 중입니다.</div>
              </div>
            `
          : html`
              <div class="ap-queue" data-testid="approvals-queue">
                ${items.map(item => html`<${ApprovalCard} key=${item.id} item=${item} />`)}
              </div>
            `}
      </div>
    </main>
  `
}
