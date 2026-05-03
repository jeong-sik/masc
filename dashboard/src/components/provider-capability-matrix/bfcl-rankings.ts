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
    <div class="overflow-x-auto rounded border border-[var(--color-border-default)]">
      <table class="w-full text-xs border-collapse">
        <thead>
          <tr class="bg-[var(--white-4)]">
            <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-left font-medium text-[var(--color-fg-secondary)]">카테고리</th>
            <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-left font-medium text-[var(--color-fg-secondary)]">설명</th>
            <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-center font-medium text-[var(--color-fg-secondary)]">가중치</th>
          </tr>
        </thead>
        <tbody>
          ${BFCL_V4_CATEGORIES.map((cat, i) => html`
            <tr key=${cat.id} class="${i % 2 === 0 ? '' : 'bg-[var(--white-2)]'}">
              <td class="border-b border-[var(--color-border-default)] px-3 py-1.5 font-medium text-[var(--color-fg-primary)]">${cat.label}</td>
              <td class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-[var(--color-fg-secondary)]">${cat.description}</td>
              <td class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-center font-mono text-[11px] ${
                cat.weight === '40%' ? 'text-[var(--color-status-ok)] font-bold'
                : cat.weight === '30%' ? 'text-[var(--color-status-warn)] font-bold'
                : 'text-[var(--color-fg-muted)]'
              }">
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
    <div class="overflow-x-auto rounded border border-[var(--color-border-default)]">
      <table class="w-full text-xs border-collapse">
        <thead>
          <tr class="bg-[var(--white-4)]">
            <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-left font-medium text-[var(--color-fg-secondary)] min-w-[120px]">모델</th>
            <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-center font-medium text-[var(--color-fg-secondary)] min-w-[60px]">Overall</th>
            <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-center font-medium text-[var(--color-fg-secondary)]">Simple</th>
            <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-center font-medium text-[var(--color-fg-secondary)]">Parallel</th>
            <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-center font-medium text-[var(--color-fg-secondary)]">Multi-turn</th>
            <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-center font-medium text-[var(--color-fg-secondary)]">Agentic</th>
          </tr>
        </thead>
        <tbody>
          ${BFCL_MODEL_BREAKDOWN.map((m, i) => html`
            <tr key=${m.model} class="${i % 2 === 0 ? '' : 'bg-[var(--white-2)]'}">
              <td class="border-b border-[var(--color-border-default)] px-3 py-1 font-medium text-[var(--color-fg-primary)]">${m.model}</td>
              <td class="border-b border-[var(--color-border-default)] px-3 py-1 text-center font-mono font-bold text-[11px]">${m.overall}</td>
              ${([m.simple, m.parallel, m.multiTurn, m.agentic] as const).map((level, j) => html`
                <td key=${j} class="border-b border-[var(--color-border-default)] px-2 py-1 text-center">
                  <span class="inline-block w-full rounded px-1 py-0.5 text-[10px] font-mono font-bold ${categoryLevelClass(level)}">
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
    <div class="border border-[var(--color-border-default)] rounded overflow-hidden">
      <div class="flex items-center justify-between px-3 py-2 bg-[var(--white-4)] border-b border-[var(--color-border-default)]">
        <div class="flex items-center gap-2">
          <span class="text-xs font-semibold text-[var(--color-fg-primary)]">Function Calling Harness</span>
          <span class="text-[10px] text-[var(--color-fg-muted)]">Sam Chon / Wrtn Technologies</span>
        </div>
        <div class="flex items-center gap-2">
          <span class="text-[11px] font-mono text-[var(--bad-light)]">6.75%</span>
          <span class="text-[10px] text-[var(--color-fg-muted)]">→</span>
          <span class="text-[11px] font-mono font-bold text-[var(--color-status-ok)]">100%</span>
        </div>
      </div>
      <div class="px-3 py-2 bg-[var(--shell-rail-bg)]">
        <p class="text-[11px] text-[var(--color-fg-secondary)] mb-2">
          확률적 모델을 결정론적 검증 루프로 감싸는 패턴. Typia 컴파일러 기반 타입 스키마 제약 +
          컴파일러 피드백 + LLM self-healing 루프. P0 Verification Loop의 참조 사례.
        </p>
        <div class="overflow-x-auto rounded border border-[var(--color-border-default)]">
          <table class="w-full text-xs border-collapse">
            <thead>
              <tr class="bg-[var(--white-2)]">
                <th class="border-b border-[var(--color-border-default)] px-2 py-1 text-left font-medium text-[var(--color-fg-muted)]">모델</th>
                <th class="border-b border-[var(--color-border-default)] px-2 py-1 text-left font-medium text-[var(--color-fg-muted)]">파라미터</th>
                <th class="border-b border-[var(--color-border-default)] px-2 py-1 text-center font-medium text-[var(--color-fg-muted)]">컴파일 성공률</th>
              </tr>
            </thead>
            <tbody>
              ${HARNESS_MODELS.map((hm, i) => html`
                <tr key=${hm.id} class="${i % 2 === 0 ? '' : 'bg-[var(--white-2)]'}">
                  <td class="border-b border-[var(--color-border-default)] px-2 py-1 font-mono text-[11px] font-medium text-[var(--color-fg-primary)]">${hm.id}</td>
                  <td class="border-b border-[var(--color-border-default)] px-2 py-1 text-[10px] text-[var(--color-fg-secondary)]">${hm.params}</td>
                  <td class="border-b border-[var(--color-border-default)] px-2 py-1 text-center font-mono text-[11px] font-bold text-[var(--color-status-ok)]">${hm.compileRate}</td>
                </tr>
              `)}
            </tbody>
          </table>
        </div>
        <p class="mt-1.5 text-[10px] text-[var(--color-fg-muted)]">
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
      <div class="flex items-center gap-3 text-[10px] font-mono text-[var(--color-fg-muted)] px-1">
        <span>BFCL = 스키마 준수율 측정</span>
        <span class="text-[var(--color-border-default)]">|</span>
        <span>MCPMark = 작업 완료율 측정</span>
        <span class="text-[var(--color-border-default)]">|</span>
        <span>GPT-5: BFCL 7위(59.22%) vs MCPMark 1위(52.6%)</span>
      </div>

      <div class="overflow-x-auto rounded border border-[var(--color-border-default)]">
        <table class="w-full text-xs border-collapse">
          <thead>
            <tr class="bg-[var(--white-4)]">
              <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-center font-medium text-[var(--color-fg-secondary)] w-[40px]">#</th>
              <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-left font-medium text-[var(--color-fg-secondary)] min-w-[160px]">모델</th>
              <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-right font-medium text-[var(--color-fg-secondary)] min-w-[90px]">BFCL V3</th>
              <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-right font-medium text-[var(--color-fg-secondary)] min-w-[90px]">BFCL V4</th>
              <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-left font-medium text-[var(--color-fg-secondary)]">특징</th>
              <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-left font-medium text-[var(--color-fg-secondary)] w-[90px]">라이선스</th>
            </tr>
          </thead>
          <tbody>
            ${BFCL_RANKINGS.map((entry, i) => {
              const hasV3 = entry.bfclV3 !== '—' && entry.bfclV3 !== '경쟁력' && entry.bfclV3 !== '개선됨'
              const hasV4 = entry.bfclV4 !== '—' && entry.bfclV4 !== '경쟁력'
              return html`
                <tr key=${entry.model} class="${i % 2 === 0 ? '' : 'bg-[var(--white-2)]'}">
                  <td class="border-b border-[var(--color-border-default)] px-3 py-2 text-center font-mono text-[var(--color-fg-muted)]">${entry.rank}</td>
                  <td class="border-b border-[var(--color-border-default)] px-3 py-2 font-medium text-[var(--color-fg-primary)]">${entry.model}</td>
                  <td class="border-b border-[var(--color-border-default)] px-3 py-2 text-right font-mono ${
                    hasV3 ? 'text-[var(--color-fg-primary)]' : 'text-[var(--color-fg-muted)]'
                  }">
                    ${hasV3 ? html`<span class="font-bold">${entry.bfclV3}</span>` : entry.bfclV3}
                  </td>
                  <td class="border-b border-[var(--color-border-default)] px-3 py-2 text-right font-mono ${
                    hasV4 ? 'text-[var(--color-status-ok)] font-bold' : 'text-[var(--color-fg-muted)]'
                  }">
                    ${hasV4 ? html`<span class="font-bold">${entry.bfclV4}</span>` : entry.bfclV4}
                  </td>
                  <td class="border-b border-[var(--color-border-default)] px-3 py-2 text-[var(--color-fg-secondary)]">${entry.feature}</td>
                  <td class="border-b border-[var(--color-border-default)] px-3 py-2">
                    <span class="inline-block rounded px-1.5 py-0.5 text-[10px] font-mono ${
                      entry.license === '오픈웨이트' || entry.license === 'Apache 2.0' || entry.license === 'Modified MIT'
                        ? 'bg-[var(--ok-10)] text-[var(--color-status-ok)]'
                        : 'bg-[var(--white-4)] text-[var(--color-fg-muted)]'
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
        <h4 class="text-xs font-semibold text-[var(--color-fg-primary)] mb-2">BFCL V4 카테고리 구성</h4>
        <p class="text-[10px] text-[var(--color-fg-muted)] mb-2">
          Multi-turn(30%) + Agentic(40%) = 70%가 실제 에이전트 시나리오 평가. AST 기반 코드 수준 평가로 텍스트 매칭 한계 극복.
        </p>
        <${V4CategoryTable} />
      </div>

      <div>
        <h4 class="text-xs font-semibold text-[var(--color-fg-primary)] mb-2">모델별 카테고리 성능 분포</h4>
        <p class="text-[10px] text-[var(--color-fg-muted)] mb-2">
          상위 3개 모델(GLM-4.5, Claude Opus 4.1, Sonnet 4)은 모든 카테고리에서 '높음'.
          GPT-5는 Agentic에서만 '높음', Simple/Parallel은 '중간'.
        </p>
        <${ModelBreakdownTable} />
      </div>

      <div>
        <h4 class="text-xs font-semibold text-[var(--color-fg-primary)] mb-2">Harness 사례: 6.75% → 100%</h4>
        <p class="text-[10px] text-[var(--color-fg-muted)] mb-2">
          검증-피드백-수정 루프(Typia)로 소형 모델도 복잡 스키마 100% 달성. P0 Verification Loop의 참조 구현.
        </p>
        <${HarnessCaseStudy} />
      </div>

      <div class="text-[10px] text-[var(--color-fg-muted)] px-1">
        출처: BFCL V3/V4 (UC Berkeley), MCPMark pass@1 (Sam Chon), SWE-Bench Pro (K2.6).
        Harness: Sam Chon, Wrtn Technologies. CoT Compliance 9.91%→100% 후속 연구.
      </div>
    </div>
  `
}
