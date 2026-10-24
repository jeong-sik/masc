import { html } from 'htm/preact'
import type { RequestObservation } from '../../api/request-observation'

export function RequestObservationFacts({ observations }: { observations: RequestObservation[] }) {
  if (observations.length === 0) return html`<p>요청 결정 관측 없음</p>`
  return html`<div>${observations.map(observation => {
    const evidence = observation.evidence
    let content
    switch (evidence.status) {
      case 'not_dispatched': content = '실행 전 거절'; break
      case 'no_durable_scope': content = '영속 실행 scope 없음 · wire 값 미관측'; break
      case 'no_matching_call': content = '이번 호출의 request 증거 없음 · wire 값 미관측'; break
      case 'read_failed': content = `요청 증거 읽기 실패: ${evidence.detail}`; break
      case 'recorded': content = html`<div title=${evidence.call_id}>${evidence.requests.length === 0 ? 'provider attempt 없음' : evidence.requests.map(request => {
        const fact = request.provenance
        if (fact === null) return html`<p title=${request.node_id}>T${request.turn} · 요청 결정 미기록</p>`
        switch (fact.state) {
          case 'not_serialized': return html`<p>T${request.turn} · 직렬화 증거 없음</p>`
          case 'external_unobserved': return html`<p>T${request.turn} · 외부 transport wire 미관측</p>`
          case 'interrupted_unobserved': return html`<p>T${request.turn} · 중단되어 wire 값 미관측</p>`
          case 'serialized': case 'cache_reused': {
            const receipt = fact.request.output_token_receipt
            return html`<p title=${request.node_id}>T${request.turn} · ${fact.state === 'cache_reused' ? '캐시 조회' : '직렬화'} · 요청 ${receipt.requested ?? '생략'} → wire ${receipt.effective ?? '생략'} · ${receipt.policy} · ceiling ${receipt.ceiling ?? '미상'} · ${receipt.envelope}</p>`
          }
        }
      })}</div>`; break
    }
    return html`<div><strong>${observation.runtime_profile} · 시도 ${observation.attempt}</strong>${content}</div>`
  })}</div>`
}
