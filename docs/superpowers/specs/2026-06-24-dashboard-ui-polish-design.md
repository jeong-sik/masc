# Dashboard UI Polish: keeper roster ellipsis & agent detail recent activity

## Context

MASC 대시보드의 두 가지 시각적/UX 문제를 수정합니다.

1. **Keeper roster 호버 메뉴 버튼** (`dashboard/src/components/keeper-workspace/keeper-workspace-roster.ts`):
   마우스를 keeper 행 위에 올리면 우측에 `⋯`(U+22EF) 텍스트 버튼이 나타나는데, 폰트 기반 문자 + `line-height: 1` 조합 때문에 시각적으로 삐딱하게 보입니다.

2. **Agent detail “최근 활동”** (`dashboard/src/components/agent-detail.ts`):
   `namespaceActivity`가 비어 있을 때 `EmptyState`를 계속 노출해서 “아무것도 안 나온다”는 인상을 줍니다.

## Goals

- 키퍼 행의 호버 메뉴 버튼을 SVG 아이콘으로 교체하고 정중앙 정렬합니다.
- Agent detail 모달의 “최근 활동” 카드는 데이터가 없을 때 아예 보여주지 않습니다.
- 기존 동작(메뉴 열기, ESC/스크롤 닫기, 접근성 라벨 등)은 그대로 유지합니다.

## Non-goals

- agent-profile.ts의 “프로젝트 활동”은 수정하지 않습니다.
- 최근 활동의 데이터 소스(`namespaceActivity`, `fetchWorkspaceMessages`)는 변경하지 않습니다.
- 새로운 공통 IconButton 컴포넌트를 만들지 않습니다.

## Design

### 1. Keeper roster 호버 메뉴 버튼

**File:** `dashboard/src/components/keeper-workspace/keeper-workspace-roster.ts`

- Import `MoreVertical` from `lucide-preact`.
- Replace the existing text span:
  ```ts
  <span aria-hidden="true">${'\u22EF'}</span>
  ```
  with:
  ```ts
  <${MoreVertical} size=${16} focusable="false" aria-hidden="true" />
  ```
- Keep the surrounding `<button>` attributes: `type="button"`, `class="kp-more"`, `aria-label`, `title`, `onClick`, `data-testid`.

**File:** `dashboard/src/styles/keeper-v2/v2.css`

- Update `.kp-more`:
  ```css
  .kp-more {
    position: absolute;
    right: 8px;
    top: 50%;
    transform: translateY(-50%);
    width: 24px;
    height: 24px;
    border-radius: var(--radius-sm);
    border: 1px solid var(--border-main);
    background: var(--bg-panel);
    color: var(--text-mid);
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 0;
    opacity: 0;
    transition: 0.14s;
    z-index: 2;
  }
  ```
- Remove `font-size: 14px; line-height: 1;`.
- Keep `.kp-row:hover .kp-more` and `.kp-more:hover` rules.

### 2. Agent detail “최근 활동” 조걸 표시

**File:** `dashboard/src/components/agent-detail.ts`

- Wrap the existing `<${SectionCard} label="최근 활동">…<//>` block so it renders only when `lines.length > 0`:
  ```ts
  ${lines.length > 0
    ? html`
        <${SectionCard} label="최근 활동">
          <div role="log" aria-label="최근 활동 로그" class="max-h-60 overflow-y-auto flex flex-col gap-2 pr-1 custom-scrollbar">
            ${lines.map((line: string, idx: number) => html`
              <div key=${idx} class="v2-monitoring-row border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-2.5 font-mono text-xs text-[var(--color-fg-primary)] leading-relaxed rounded-[var(--r-1)] hover:bg-[var(--color-bg-hover)] hover:border-[var(--color-border-strong)] transition-colors">${line}</div>
            `)}
          </div>
        <//>
      `
    : null}
  ```
- Remove the `EmptyState` branch for this card.

## Verification

- `cd dashboard && pnpm test -- keeper-workspace-roster.test.ts` — roster tests pass.
- `cd dashboard && pnpm test` — full dashboard test suite passes.
- `cd dashboard && npx tsc --noEmit --pretty` — type check passes.

## Risks

- `lucide-preact` icon을 추가하면 일부 테스트 환경에서 아이콘 모듈 로딩 문제가 발생할 수 있습니다. `keeper-workspace-roster.test.ts`에 lucide mock이 없으면 필요 시 추가합니다.
- “최근 활동” 카드를 숨기면 두 칸짜리 그리드가 한 칸만 남아 시각적 균형이 달라질 수 있습니다. 이는 기존 grid의 자동 배치로 처리되며 별도 수정은 하지 않습니다.
