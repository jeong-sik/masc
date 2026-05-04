// BfclRankings — BFCL Function Calling benchmark rankings.
// Includes V4 category breakdown, per-model analysis, and Harness case study.

import { html } from 'htm/preact'
import {
  BFCL_RANKINGS,
  BFCL_V4_CATEGORIES,
  BFCL_MODEL_BREAKDOWN,
  HARNESS_MODELS,
  MCPMARK_ENTRIES,
  scoreColor,
} from './data'

function V4CategoryTable() {
  return html`
    <div class="pm-scroll">
      <table class="pm-table">
        <thead class="pm-thead">
          <tr>
            <th class="pm-th">카테고리</th>
            <th class="pm-th">설명</th>
            <th class="pm-th pm-th--center">가중치</th>
          </tr>
        </thead>
        <tbody>
          ${BFCL_V4_CATEGORIES.map((cat) => html`
            <tr key=${cat.id} class="pm-row-alt">
              <td class="pm-td font-semibold">${cat.label}</td>
              <td class="pm-td t-meta">${cat.description}</td>
              <td class="pm-td pm-td--center pm-td--mono t-dim">
                ${cat.weight}
              </td>
            </tr>
          `)}
        </tbody>
      </table>
    </div>
  `
}

function ModelBreakdownTable() {
  return html`
    <div class="pm-scroll">
      <table class="pm-table">
        <thead class="pm-thead">
          <tr>
            <th class="pm-th min-w-[120px]">모델</th>
            <th class="pm-th pm-th--center min-w-[60px]">Overall</th>
            <th class="pm-th pm-th--center">Single</th>
            <th class="pm-th pm-th--center">Multi-turn</th>
            <th class="pm-th pm-th--center">Agentic</th>
            <th class="pm-th pm-th--center">Halluc.</th>
            <th class="pm-th pm-th--center">Format</th>
          </tr>
        </thead>
        <tbody>
          ${BFCL_MODEL_BREAKDOWN.map((m) => html`
            <tr key=${m.model} class="pm-row-alt">
              <td class="pm-td font-semibold">${m.model}</td>
              <td class="pm-td pm-td--center pm-td--mono font-bold">${m.overall}</td>
              ${([m.singleTurn, m.multiTurn, m.agentic, m.hallucination, m.format] as const).map((score, j) => html`
                <td key=${j} class="pm-td pm-td--center pm-td--mono ${scoreColor(score)}">${score}</td>
              `)}
            </tr>
          `)}
        </tbody>
      </table>
    </div>
  `
}

function HarnessCaseStudy() {
  return html`
    <div class="pm-card">
      <div class="pm-card-head">
        <div class="flex items-center gap-2">
          <span class="t-label font-semibold">Function Calling Harness</span>
          <span class="t-micro t-dim">Sam Chon / Wrtn Technologies</span>
        </div>
        <div class="flex items-center gap-2">
          <span class="pm-td--mono t-caption t-err">6.75%</span>
          <span class="t-micro t-dim">→</span>
          <span class="pm-td--mono t-caption t-ok font-bold">100%</span>
        </div>
      </div>
      <div class="px-3 py-2 bg-[var(--shell-rail-bg)]">
        <p class="t-caption t-meta mb-2">
          확률적 모델을 결정론적 검증 루프로 감싸는 패턴. Typia 컴파일러 기반 타입 스키마 제약 +
          컴파일러 피드백 + LLM self-healing 루프. P0 Verification Loop의 참조 사례.
        </p>
        <div class="pm-scroll">
          <table class="pm-table">
            <thead class="pm-thead">
              <tr>
                <th class="pm-th">모델</th>
                <th class="pm-th">파라미터</th>
                <th class="pm-th pm-th--center">컴파일 성공률</th>
              </tr>
            </thead>
            <tbody>
              ${HARNESS_MODELS.map((hm) => html`
                <tr key=${hm.id} class="pm-row-alt">
                  <td class="pm-td pm-td--mono font-semibold">${hm.id}</td>
                  <td class="pm-td t-micro t-meta">${hm.params}</td>
                  <td class="pm-td pm-td--center pm-td--mono t-ok font-bold">${hm.compileRate}</td>
                </tr>
              `)}
            </tbody>
          </table>
        </div>
        <p class="mt-1.5 t-micro t-dim">
          재귀 유니언 타입 10 variant × 3단계 = 1,000 경로. 30 variant면 27,000 경로.
          LLM 1회 통과율이 구조적으로 낮은 것은 능력 부족이 아닌 조합 폭발의 결과.
        </p>
      </div>
    </div>
  `
}

function McpMarkTable() {
  return html`
    <div class="pm-card">
      <div class="pm-card-head">
        <div class="flex items-center gap-2">
          <span class="t-label font-semibold">MCPMark</span>
          <span class="t-micro t-dim">MCP Agent Workflow Benchmark</span>
        </div>
        <span class="chip sm is-ghost">pass@1</span>
      </div>
      <div class="px-3 py-2 bg-[var(--shell-rail-bg)]">
        <p class="t-caption t-meta mb-2">
          MCP 기반 에이전트 워크플로우 완주율(pass@1) 측정. BFCL이 스키마 준수율이라면
          MCPMark는 실제 에이전트 작업 완수율. BFCL 1위(Claude Opus 4.5)와 MCPMark 1위(GPT-5)가
          다름 — 단일 벤치마크 의존도 경고.
        </p>
        <div class="pm-scroll">
          <table class="pm-table">
            <thead class="pm-thead">
              <tr>
                <th class="pm-th">모델</th>
                <th class="pm-th pm-th--center">pass@1</th>
                <th class="pm-th pm-th--right">평균 시간</th>
                <th class="pm-th pm-th--right">비용/런</th>
                <th class="pm-th">비고</th>
              </tr>
            </thead>
            <tbody>
              ${MCPMARK_ENTRIES.map((e, i) => html`
                <tr key=${e.model} class="pm-row-alt">
                  <td class="pm-td pm-td--mono font-semibold">${e.model}</td>
                  <td class="pm-td pm-td--center pm-td--mono font-bold ${i === 0 ? 't-ok' : ''}">${e.passAt1}</td>
                  <td class="pm-td pm-td--right pm-td--mono">${e.avgAgentTime}</td>
                  <td class="pm-td pm-td--right pm-td--mono">${e.costPerRun}</td>
                  <td class="pm-td t-micro t-dim">${e.note}</td>
                </tr>
              `)}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  `
}

export function BfclRankings() {
  return html`
    <div class="flex flex-col gap-4">
      <div class="t-micro mono t-dim px-1">
        <span>BFCL V4 = 스키마 준수율 측정 (UC Berkeley, 2026-04-12 기준, 109개 모델)</span>
        <span class="text-[var(--color-border-default)] mx-2">|</span>
        <span>Claude Opus 4.5: V4 1위 (77.47%)</span>
      </div>

      <div class="pm-scroll">
        <table class="pm-table">
          <thead class="pm-thead">
            <tr>
              <th class="pm-th pm-th--center w-[40px]">#</th>
              <th class="pm-th min-w-[160px]">모델</th>
              <th class="pm-th pm-th--right min-w-[90px]">BFCL V3</th>
              <th class="pm-th pm-th--right min-w-[90px]">BFCL V4</th>
              <th class="pm-th">특징</th>
              <th class="pm-th w-[90px]">라이선스</th>
            </tr>
          </thead>
          <tbody>
            ${BFCL_RANKINGS.map((entry, i) => {
              const hasV3 = entry.bfclV3 !== '—' && entry.bfclV3 !== '경쟁력' && entry.bfclV3 !== '개선됨'
              const hasV4 = entry.bfclV4 !== '—' && entry.bfclV4 !== '경쟁력'
              return html`
                <tr key=${entry.model} class="pm-row-alt">
                  <td class="pm-td pm-td--center pm-td--mono t-dim">${entry.rank}</td>
                  <td class="pm-td font-semibold">${entry.model}</td>
                  <td class="pm-td pm-td--right pm-td--mono ${
                    hasV3 ? 'font-bold' : 't-dim'
                  }">
                    ${hasV3 ? html`<span class="font-bold">${entry.bfclV3}</span>` : entry.bfclV3}
                  </td>
                  <td class="pm-td pm-td--right pm-td--mono ${
                    hasV4 ? 't-ok font-bold' : 't-dim'
                  }">
                    ${hasV4 ? html`<span class="font-bold">${entry.bfclV4}</span>` : entry.bfclV4}
                  </td>
                  <td class="pm-td t-meta">${entry.feature}</td>
                  <td class="pm-td">
                    <span class="chip sm ${
                      entry.license === '오픈웨이트' || entry.license === 'Apache 2.0' || entry.license === 'Modified MIT'
                        ? 'is-ok'
                        : 'is-ghost'
                    }">
                      ${entry.license}
                    </span>
                  </td>
                </tr>
              `
            })}
          </tbody>
        </table>
      </div>

      <div>
        <h4 class="t-label font-semibold mb-2">BFCL V4 카테고리 구성</h4>
        <p class="t-micro t-dim mb-2">
          Agentic + Multi-turn이 실제 에이전트 시나리오 평가. Hallucination은 오류 탐지 능력, Format은 FC-Prompt 격차 측정. Overall = unweighted average.
        </p>
        <${V4CategoryTable} />
      </div>

      <div>
        <h4 class="t-label font-semibold mb-2">모델별 카테고리 성능 분포</h4>
        <p class="t-micro t-dim mb-2">
          Claude Opus 4.5는 전 카테고리 70+%. Mistral Large는 Single-turn 84.65%이나 Agentic 28%, Hallucination 14.12%로 에이전트 역량 취약.
          Mistral Large(38.37%)는 전반적으로 낮은 스키마 준수율.
        </p>
        <${ModelBreakdownTable} />
      </div>

      <div>
        <h4 class="t-label font-semibold mb-2">Harness 사례: 6.75% → 100%</h4>
        <p class="t-micro t-dim mb-2">
          검증-피드백-수정 루프(Typia)로 소형 모델도 복잡 스키마 100% 달성. P0 Verification Loop의 참조 구현.
        </p>
        <${HarnessCaseStudy} />
      </div>

      <div>
        <h4 class="t-label font-semibold mb-2">MCPMark: 에이전트 워크플로우 벤치마크</h4>
        <p class="t-micro t-dim mb-2">
          BFCL(스키마 준수율)과 MCPMark(에이전트 완주율) 간 순위 역전 주목. GPT-5는 BFCL 7위(59.22%)이나 MCPMark 1위(52.6%).
        </p>
        <${McpMarkTable} />
      </div>

      <div class="t-micro t-dim px-1">
        출처: BFCL V4 Leaderboard (gorilla.cs.berkeley.edu, 2026-04-12 갱신, 109개 모델).
        MCPMark: external_research.md §1.2.3 (2026-04-30 검증).
        Harness: Sam Chon, Wrtn Technologies. CoT Compliance 9.91%→100% 후속 연구.
        카테고리별 breakdown은 V4 공개 데이터 미제공으로 overall score 기반 추정.
      </div>
    </div>
  `
}
