# HITL Approval 빠른 반응 + 처리 이력 노출 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** MASC Dashboard HITL approval 승인/거부 버튼을 눌렀을 때 캐시 때문에 화면이 갱신되지 않는 문제를 고치고, SSE 기반 실시간 반응을 강화하며, 처리 완료된 approval 이력을 dashboard에 노출한다.

**Architecture:**
- Backend: `/api/v1/dashboard/governance`에 `?force=1` 쿼리 파라미터를 추가해 120초 캐시를 우회할 수 있게 한다. (이미 `/api/v1/dashboard/execution`에 동일한 패턴이 있음)
- Frontend: `fetchDashboardGovernance()`에 `force` 옵션을 추가하고, 승인 action 완료 후와 SSE `approval:pending`/`approval:resolved` 수신 시 `force: true`로 갱신한다.
- History: backend governance JSON 응답에 최근 resolved approvals(최근 N개)를 포함하고, frontend approvals surface 하단에 "최근 처리" 리스트를 렌더링한다.

**Tech Stack:** OCaml (Dune), TypeScript/Preact (dashboard), JSONL audit log.

---

## Task 1: Backend — `/api/v1/dashboard/governance`에 `force` 파라미터 추가

**Files:**
- Modify: `lib/server/server_dashboard_http.ml:177-189`
- Modify: `lib/dashboard/dashboard_governance.ml` (핸들러가 `force`를 받아 `Dashboard_cache` 우회)
- Test: `test/test_keeper_approval_queue_rules.ml` (필요시) / `dashboard/src/api/dashboard.test.ts`

- [ ] **Step 1: 핸들러 시그니처 변경**

```ocaml
let dashboard_governance_http_json request ~base_path : Yojson.Safe.t =
  let limit = int_query_param request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
  let offset = int_query_param request "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
  let status_filter = None in
  let force = bool_query_param request "force" ~default:false in
  let cache_key = Printf.sprintf "governance:%s;%d;%d" base_path limit offset in
  if force
  then
    Dashboard_cache.get_or_compute cache_key ~ttl:0.0 (fun () ->
      Domain_pool_ref.submit_io_or_inline (fun () ->
        Dashboard_governance.dashboard_json ~base_path ~limit ~offset ~status_filter))
  else
    Dashboard_cache.get_or_compute cache_key ~ttl:board_governance_cache_ttl_s (fun () ->
      Domain_pool_ref.submit_io_or_inline (fun () ->
        Dashboard_governance.dashboard_json ~base_path ~limit ~offset ~status_filter))
```

> Note: `Dashboard_cache.get_or_compute`에 `~ttl:0.0`을 주면 즉시 만료되어 캐시가 재계산된다. 이미 `Dashboard_cache`가 이를 지원하는지 확인 후, 지원하지 않으면 `force`일 때 캐시 래퍼를 생략하고 직접 compute한다.

- [ ] **Step 2: `bool_query_param` 사용 확인**

`server_dashboard_http.ml` 상단의 `open Server_utils` 또는 `Server_utils.bool_query_param` 참조가 이미 존재함 (execution handler 참조).

- [ ] **Step 3: OCaml 타입체크**

```bash
cd <repo>
scripts/dune-local.sh build lib/server/server_dashboard_http.cma
```

Expected: `Done: ...` with no errors.

- [ ] **Step 4: Commit**

```bash
git add lib/server/server_dashboard_http.ml
git commit -m "feat(server): allow ?force=1 on /api/v1/dashboard/governance"
```

---

## Task 2: Frontend — `fetchDashboardGovernance`에 `force` 옵션 추가

**Files:**
- Modify: `dashboard/src/api/dashboard-governance.ts:63-131`
- Modify: `dashboard/src/api/dashboard.ts` (re-export unchanged)
- Test: `dashboard/src/api/dashboard.test.ts`

- [ ] **Step 1: 함수 시그니처 변경**

```typescript
export interface FetchDashboardGovernanceOptions {
  force?: boolean
  signal?: AbortSignal
}

export function fetchDashboardGovernance(
  opts?: FetchDashboardGovernanceOptions,
): Promise<DashboardGovernanceResponse> {
  const query = opts?.force ? '?force=1' : ''
  return withRetries('fetchDashboardGovernance', async () => {
    const raw = await get<Record<string, unknown>>(`/api/v1/dashboard/governance${query}`, {
      signal: opts?.signal,
    })
    // ... existing normalization unchanged ...
  })
}
```

- [ ] **Step 2: 기존 호출자 타입 호환 확인**

`fetchDashboardGovernance()` 인자 없이 호출하는 곳은 그대로 동작해야 함.

- [ ] **Step 3: Frontend 타입/테스트**

```bash
cd <repo>/dashboard
npx tsc --noEmit
npx vitest run src/api/dashboard.test.ts
```

Expected: tests pass.

- [ ] **Step 4: Commit**

```bash
git add dashboard/src/api/dashboard-governance.ts
git commit -m "feat(dashboard): add force option to fetchDashboardGovernance"
```

---

## Task 3: Frontend — 승인 action 및 SSE handler에서 force refresh 사용

**Files:**
- Modify: `dashboard/src/components/governance-actions.ts:50-67,126-148`
- Modify: `dashboard/src/sse-store.ts:495-509`

- [ ] **Step 1: `refreshGovernance`가 force 옵션 전달**

```typescript
export async function refreshGovernance(opts?: { force?: boolean }) {
  governanceError.value = ''
  await governanceResource.load(async (signal) => {
    const data = await fetchDashboardGovernance({ force: opts?.force, signal })
    // ... rest unchanged ...
  })
  // ... rest unchanged ...
}
```

- [ ] **Step 2: 승인 action 완료 후 force refresh**

```typescript
export async function respondToKeeperApproval(
  id: string,
  decision: 'approve' | 'reject',
  rememberRule = false,
) {
  if (!id) return
  governanceApprovalActing.value = id
  try {
    await resolveGovernanceApproval(id, decision, rememberRule)
    const message =
      decision === 'approve'
        ? (rememberRule ? 'keeper 승인 요청을 승인하고 Always 규칙을 저장했습니다' : 'keeper 승인 요청을 승인했습니다')
        : 'keeper 승인 요청을 거부했습니다'
    showToast(message, 'success')
    await refreshGovernance({ force: true })
  } catch (err) {
    // ... unchanged ...
  } finally {
    governanceApprovalActing.value = null
  }
}
```

- [ ] **Step 3: SSE approval 이벤트에서 force refresh**

```typescript
if (
  event.type.startsWith('decision_')
  || event.type === 'governance_param_changed'
  || event.type === 'approval:pending'
  || event.type === 'approval:resolved'
) {
  if (route.value.tab === 'command') {
    scheduleRefresh('command_route', () => {
      void refreshActiveRoute()
    })
  }
  if (_refreshGovernanceFn) {
    scheduleRefresh('governance', () => void handleGovernance({ force: true }))
  }
}
```

- [ ] **Step 4: `handleGovernance` 함수 수정**

```typescript
function handleGovernance(opts?: { force?: boolean }): void {
  _refreshGovernanceFn?.(opts)
}
```

- [ ] **Step 5: 타입/테스트**

```bash
cd <repo>/dashboard
npx tsc --noEmit
npx vitest run src/components/governance.test.ts src/sse-store.test.ts src/components/approvals/approvals-surface.test.ts
```

- [ ] **Step 6: Commit**

```bash
git add dashboard/src/components/governance-actions.ts dashboard/src/sse-store.ts
git commit -m "feat(dashboard): force-refresh governance on approval decision and SSE approval events"
```

---

## Task 4: Backend — governance response에 최근 resolved approvals 포함

**Files:**
- Modify: `lib/keeper/keeper_approval_queue.ml` (add `list_recent_resolved_json` helper)
- Modify: `lib/dashboard/dashboard_governance.ml` (include `recent_resolved` in response)
- Modify: `dashboard/src/types/core.ts` (add `recent_resolved` field)
- Modify: `dashboard/src/api/dashboard-governance.ts` (normalize field)

- [ ] **Step 1: Audit log에서 최근 resolved 항목 읽기**

`Keeper_approval_queue.read_recent_audit`는 이미 존재. 이 중 `event = "resolved"`인 항목만 최근 N개 반환하는 helper 추가:

```ocaml
let list_recent_resolved_json ~base_path ?(n = 20) () : Yojson.Safe.t list =
  read_recent_audit ~base_path ()
  |> List.filter (fun json ->
       String.equal "resolved" (Safe_ops.json_string ~default:"" "event" json))
  |> List.take n
```

> `List.take`가 없다면 `Base.List.take` 또는 직접 `List.filteri` 사용.

- [ ] **Step 2: Dashboard_governance.dashboard_json 응답에 추가**

```ocaml
let dashboard_json ~base_path ~limit ~offset ~status_filter =
  let approval_queue = Keeper_approval_queue.list_pending_dashboard_json () in
  let recent_resolved = Keeper_approval_queue.list_recent_resolved_json ~base_path ~n:20 () in
  `Assoc [
    ("approval_queue", approval_queue);
    ("recent_resolved", `List recent_resolved);
    (* ... other fields unchanged ... *)
  ]
```

- [ ] **Step 3: Frontend 타입/정규화**

`dashboard/src/types/core.ts`의 `DashboardGovernanceResponse`에:

```typescript
recent_resolved?: KeeperApprovalQueueItem[]
```

`dashboard/src/api/dashboard-governance.ts`의 `fetchDashboardGovernance` 정규화 부분에:

```typescript
const recentResolved = Array.isArray(raw.recent_resolved)
  ? raw.recent_resolved
      .map(item => normalizeKeeperApprovalQueueItem(item))
      .filter((item): item is KeeperApprovalQueueItem => item !== null)
  : []
```

반환 객체에 `recent_resolved: recentResolved` 추가.

- [ ] **Step 4: OCaml/TypeScript 타입체크**

```bash
cd <repo>
scripts/dune-local.sh build lib/dashboard/dashboard_governance.cma
cd dashboard
npx tsc --noEmit
```

- [ ] **Step 5: Commit**

```bash
git add lib/keeper/keeper_approval_queue.ml lib/dashboard/dashboard_governance.ml dashboard/src/types/core.ts dashboard/src/api/dashboard-governance.ts
git commit -m "feat(server,dashboard): include recent resolved approvals in governance response"
```

---

## Task 5: Frontend — approvals surface에 처리 이력 영역 추가

**Files:**
- Modify: `dashboard/src/components/approvals/approvals-surface.ts:273-378`
- Modify: `dashboard/src/styles/approvals-v2.css` (history section styling)

- [ ] **Step 1: 데이터 흐름 연결**

`ApprovalsSurface` 컴포넌트에서:

```typescript
const resolvedItems = governanceData.value?.recent_resolved ?? []
```

- [ ] **Step 2: 처리 이력 렌더링**

메인 리스트 아래에 별도 섹션 추가:

```typescript
${resolvedItems.length > 0
  ? html`
      <section class="ap-history" data-testid="approvals-history">
        <h2 class="ap-history-title">최근 처리 (${resolvedItems.length})</h2>
        <ul class="ap-history-list">
          ${resolvedItems.map(item => html`
            <li key=${item.id} class="ap-history-item">
              <span class="ap-history-id mono">${item.id}</span>
              <span class="ap-history-tool">${item.tool_name}</span>
              <span class="ap-history-decision">${item.disposition ?? '처리됨'}</span>
            </li>
          `)}
        </ul>
      </section>
    `
  : null}
```

> `disposition` 필드에 resolved 시 decision(approve/reject)이 들어가는지 확인. 만약 아니라면 backend `audit_approval_event`에 `decision` 필드를 추가하거나, frontend에서 별도 매핑 필요. 현재 `pending_entry_json_fields`에는 `disposition`만 있고 `decision`은 audit event에만 있음.

- [ ] **Step 3: Backend에 decision 노출 보정 (필요시)**

`pending_entry_json_fields` 또는 `list_recent_resolved_json`에서 `decision` 필드를 포함하도록 수정:

```ocaml
("decision", Json_util.string_opt_to_json (Option.map approval_audit_decision_to_string decision))
```

- [ ] **Step 4: CSS 추가**

`dashboard/src/styles/approvals-v2.css`에 `.ap-history*` 클래스 추가 (최소한의 구분선, 폰트 크기 등).

- [ ] **Step 5: 테스트**

```bash
cd <repo>/dashboard
npx tsc --noEmit
npx vitest run src/components/approvals/approvals-surface.test.ts
```

- [ ] **Step 6: Commit**

```bash
git add dashboard/src/components/approvals/approvals-surface.ts dashboard/src/styles/approvals-v2.css
git commit -m "feat(dashboard): render recent resolved approvals on approvals surface"
```

---

## Task 6: 검증

- [ ] **Step 1: OCaml 타입체크 (touched targets)**

```bash
cd <repo>
scripts/dune-local.sh build lib/server/server_dashboard_http.cma lib/dashboard/dashboard_governance.cma
```

- [ ] **Step 2: Frontend 타입/테스트**

```bash
cd dashboard
npx tsc --noEmit
npx vitest run src/components/approvals/approvals-surface.test.ts src/api/dashboard.test.ts src/sse-store.test.ts src/components/governance.test.ts
```

- [ ] **Step 3: 수동 검증 가이드**

로컬 서버를 띄운 뒤:
1. keeper가 승인이 필요한 tool call을 생성
2. dashboard approvals surface에서 승인/거부 버튼 클릭
3. 카드가 즉시 사라지는지 확인
4. "최근 처리" 섹션에 해당 항목이 나타나는지 확인
5. 다른 탭에서 SSE `approval:resolved` 수신 시 badge/queue가 갱신되는지 확인

- [ ] **Step 4: Final commit / push**

```bash
git push -u origin feature/hitl-approval-refresh-and-history
```

---

## Self-Review

**Spec coverage:**
- A (즉각 반응 개선): Task 1-3 (force param, force refresh on action/SSE)
- B (승인 내역 남기기): Task 4-5 (recent_resolved in response + UI)

**Placeholder scan:**
- 모든 task는 실제 파일 경로, 코드 스니펫, 명령 포함. "TBD"/"TODO" 없음.

**Type consistency:**
- `fetchDashboardGovernance(opts?: FetchDashboardGovernanceOptions)`
- `refreshGovernance(opts?: { force?: boolean })`
- `DashboardGovernanceResponse.recent_resolved?: KeeperApprovalQueueItem[]`
