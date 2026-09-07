import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import type { BoardPost } from '../../types'
import { fetchBoardPost } from '../../api/board'
import type { FusionHistoricalEvidence, FusionReplay } from '../../api/dashboard-fusion'
import { navigate } from '../../router'
import { RichContent } from '../common/rich-content'
import { TimeAgo } from '../common/time-ago'
import { asRecord } from '../common/normalize'
import { firstNumber, normalizeFusionUsage } from '../../lib/fusion-meta'

export function FusionReplayNotice({ replay }: { replay: FusionReplay | null }) {
  let text: string
  switch (replay?.status) {
    case undefined: text = '서버가 레지스트리 재생 상태를 제공하지 않았습니다.'; break
    case 'not_replayed': text = '레지스트리 원장을 아직 재생하지 않았습니다.'; break
    case 'absent': text = '레지스트리 원장 파일이 없습니다. 보드에 남은 원문은 아래에서 확인할 수 있습니다.'; break
    case 'complete': case 'incomplete':
      text = `${replay.status === 'complete' ? '원장 끝까지 읽음' : '원장 읽기 미완료'} · 읽은 행 ${replay.linesRead} · 해석 실패 ${replay.malformedLines} · 복구하지 못한 진행 기록 ${replay.droppedRunning}`
      break
  }
  return html`<div class="fus-reality-notice" role="status" data-testid="fusion-replay-notice">
    <strong>원장 재생</strong><span>${text}</span>
  </div>`
}

type EvidenceRead =
  | { state: 'loading' }
  | { state: 'failed'; detail: string }
  | { state: 'loaded'; post: BoardPost }

function HistoricalUsage({ post }: { post: BoardPost }) {
  const meta = asRecord(post.meta) ?? {}
  // Read the existing observation without inferring missing provider usage
  // from a panel count or turning an absent dollar figure into zero.
  const usage = normalizeFusionUsage(meta)
  const cost = firstNumber(meta, ['cost_usd', 'costUsd', 'observed_cost_usd'])
  return html`<dl class="fus-kpis" data-testid="fusion-historical-usage">
    <div class="fus-kpi"><dt class="k">입력 토큰 (관측)</dt><dd class="v">${usage.inputTokens?.toLocaleString('en-US') ?? '미관측'}</dd></div>
    <div class="fus-kpi"><dt class="k">출력 토큰 (관측)</dt><dd class="v">${usage.outputTokens?.toLocaleString('en-US') ?? '미관측'}</dd></div>
    <div class="fus-kpi"><dt class="k">비용 (관측)</dt><dd class="v">${cost === null ? '미관측' : `$${cost.toFixed(4)}`}</dd></div>
    <div class="fus-kpi"><dt class="k">증거 출처</dt><dd class="v">보드 원문</dd></div>
  </dl>`
}

export function FusionHistoricalDetail({ evidence }: { evidence: FusionHistoricalEvidence }) {
  const [read, setRead] = useState<EvidenceRead>({ state: 'loading' })
  const [attempt, setAttempt] = useState(0)
  useEffect(() => {
    let current = true
    setRead({ state: 'loading' })
    void fetchBoardPost(evidence.postId).then(post => {
      if (!current) return
      if (post.id !== evidence.postId || post.origin?.source !== 'fusion'
          || post.origin.fusion_run_id !== evidence.runId) {
        setRead({ state: 'failed', detail: '보드 원문의 Fusion 출처가 선택한 기록과 일치하지 않습니다.' })
      } else setRead({ state: 'loaded', post })
    }).catch((error: unknown) => {
      if (current) setRead({ state: 'failed', detail: error instanceof Error ? error.message : String(error) })
    })
    return () => { current = false }
  }, [evidence.postId, evidence.runId, attempt])

  return html`<div class="fus-run-scroll" data-testid="fusion-historical-detail">
    <div class="fus-run-head">
      <div class="fus-run-id-row"><h1 class="mono break-words">${evidence.title}</h1></div>
      <div class="mono">${evidence.runId}</div>
      <p>보드에 남은 원문입니다. 레지스트리에 실행 기록이 없어 성공·실패와 시작·완료 시각은 확인할 수 없습니다.</p>
      <p>보드 게시 시각 · <${TimeAgo} timestamp=${evidence.createdAt} mode="both" /></p>
      <button class="fus-link inline" type="button"
        onClick=${() => navigate('board', { post: evidence.postId })}>보드 원문 · ${evidence.postId}</button>
    </div>
    <div class="fus-block">
      ${read.state === 'loading' ? html`<p role="status">보드 원문을 읽는 중입니다.</p>`
        : read.state === 'failed' ? html`<div role="alert">${read.detail}
            <button type="button" onClick=${() => setAttempt(attempt + 1)}>원문 다시 읽기</button></div>`
        : html`<${HistoricalUsage} post=${read.post} />
            <${RichContent} text=${read.post.body} previewLimit=${0} />`}
    </div>
  </div>`
}
