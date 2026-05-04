// BfclRankings — BFCL Function Calling benchmark rankings.
// Includes V4 category breakdown, per-model analysis, and Harness case study.

import { html } from 'htm/preact'
import {
  BFCL_RANKINGS,
  BFCL_V4_CATEGORIES,
  BFCL_MODEL_BREAKDOWN,
  HARNESS_MODELS,
  categoryLevelClass,
  categoryLevelLabel,
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
          ${BFCL_V4_CATEGORIES.map((cat, i) => html`
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
            <th class="pm-th pm-th--center">Simple</th>
            <th class="pm-th pm-th--center">Parallel</th>
            <th class="pm-th pm-th--center">Multi-turn</th>
            <th class="pm-th pm-th--center">Agentic</th>
          </tr>
        </thead>
        <tbody>
          ${BFCL_MODEL_BREAKDOWN.map((m, i) => html`
            <tr key=${m.model} class="pm-row-alt">
              <td class="pm-td font-semibold">${m.model}</td>
              <td class="pm-td pm-td--center pm-td--mono font-bold">${m.overall}</td>
              ${([m.simple, m.parallel, m.multiTurn, m.agentic] as const).map((level, j) => html`
                <td key=${j} class="pm-td pm-td--center">
                  <span class="pm-cell-badge ${categoryLevelClass(level)}">
                    ${categoryLevelLabel(level)}
                  </span>
                </td>
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
              ${HARNESS_MODELS.map((hm, i) => html`
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
          Multi-turn(30%) + Agentic(40%) = 70%가 실제 에이전트 시나리오 평가. AST 기반 코드 수준 평가로 텍스트 매칭 한계 극복.
        </p>
        <${V4CategoryTable} />
      </div>

      <div>
        <h4 class="t-label font-semibold mb-2">모델별 카테고리 성능 분포</h4>
        <p class="t-micro t-dim mb-2">
          Claude Opus 4.5, Sonnet 4.5는 전 카테고리 '높음'. GPT-5.2는 Agentic에서만 '높음'.
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

      <div class="t-micro t-dim px-1">
        출처: BFCL V4 Leaderboard (gorilla.cs.berkeley.edu, 2026-04-12 갱신, 109개 모델).
        Harness: Sam Chon, Wrtn Technologies. CoT Compliance 9.91%→100% 후속 연구.
        카테고리별 breakdown은 V4 공개 데이터 미제공으로 overall score 기반 추정.
      </div>
    </div>
  `
}
