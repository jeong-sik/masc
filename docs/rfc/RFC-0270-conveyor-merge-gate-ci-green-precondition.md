---
rfc: "0270"
title: "Conveyor merge gate: require CI Gate success on admin merges to main"
status: Draft
created: 2026-06-20
updated: 2026-06-20
author: vincent
supersedes: []
superseded_by: null
related: ["0235"]
implementation_prs: []
---

# RFC-0270: Conveyor merge gate — require CI Gate success on admin merges to main

Status: Draft · main으로의 모든 머지는 그 head commit의 required check
`CI Gate` 가 `success` 로 종료된 뒤에만 허용되어야 한다. 현재는 관리자
권한 머저(컨베이어)가 이 조건을 우회한다.

Drafted by: Claude (Opus 4.8), 2026-06-20 세션 관측 (컨베이어발 main-RED
3연쇄, `~/.claude/.../memory/reference-masc-conveyor-admin-merge-red-ci-main-build-breaks.md`).

> Branch protection 은 2026-06-20 에 `gh api repos/jeong-sik/masc/branches/main/protection`
> 로 읽었다. Incident CI Gate 상태는 각 PR head commit 의
> `check-runs` 로 측정했다 (§6.1). ci.yml anchors 는 origin/main 의
> `.github/workflows/ci.yml` (`ci-gate` job, line 1159-1237) 기준.

---

## §1 문제 (Problem)

컨베이어(autonomous auto-merge)는 PR 의 CI 가 끝나기 전에 main 으로
머지한다. 그 결과 main 의 green 상태는 한 커밋 동안만 유효하고, 컴파일
불가 상태가 main 에 반복적으로 안착한다. main 이 RED 이면
`start-masc.sh` 의 서버 바이너리 rebuild 가 실패하므로 키퍼 재시작과
모든 후속 rebuild 가 막힌다.

### §1.1 측정된 증거 — 2026-06-20 3연쇄

같은 날 컨베이어가 머지한 PR 들의 head commit 에서 required check
`CI Gate` 의 종료 상태:

| Incident | breaking PR | main 에서의 에러 | merge 시 `CI Gate` | fix PR |
|---|---|---|---|---|
| 1a | #21714 | `lib/gate_keeper_backend.ml:135` unerasable-optional (warning 16) | `completed/cancelled` | #21739 |
| 1b | #21721 | `lib/server/server_discord_in_process_gateway.ml:425` syntax (`)` 누락) | `completed/failure` | #21739 |
| 2 | #21706 계보 | `lib/fusion/fusion_oas.ml:49` Unbound record field `stream_idle_timeout_s` | (계보) | #21753 |
| 3 | #21722 | `lib/server/server_dashboard_http_delete_actions.ml:394` Unbound module `Task.Goal_assignment` (facade `.ml`/`.mli` desync) | `completed/cancelled` | #21758 |

fix PR 조차 같은 경로로 머지됐다: #21753 (incident 2 의 fix) 의 merge 시
`CI Gate` = `completed/cancelled`. 즉 fix 도 green CI Gate 없이 안착했다.

**핵심 관측**: 위 머지들에서 `CI Gate` 가 `success` 인 경우는 0건이다
(전부 `cancelled` 또는 `failure`). `cancelled` 는 컨베이어가 CI 진행
중에 머지해 run 이 취소된 결과다. 측정:

```
$ for pr in 21714 21721 21722 21753; do
    head=$(gh pr view $pr --json headRefOid -q .headRefOid)
    gh api repos/jeong-sik/masc/commits/$head/check-runs \
      -q '.check_runs[]|select(.name=="CI Gate")|.conclusion'
  done
cancelled   # #21714
failure     # #21721
cancelled   # #21722
cancelled   # #21753 (fix)
```

### §1.2 새로운 문제 아님 — 이미 측정된 패턴

`ci.yml` 의 `ci-gate` job 주석(line 1198)이 기록한다:
"22/80 admin-bypass merges over 2026-04-18..04-20 were Eio quick-suite
flakes". 즉 admin-bypass 머지는 2026-04 시점에 이미 측정된 현상이며,
당시 대응은 flaky test 를 advisory 로 강등하는 것이었다(증상 완화). 본
RFC 는 그 우회 경로 자체(관리자 우회)를 닫는다.

---

## §2 근본 원인 (Root cause)

### §2.1 현재 gate

`gh api .../branches/main/protection` (2026-06-20):

```
required_status_checks: { strict: false, contexts: ["CI Gate"] }
required_pull_request_reviews: { required_approving_review_count: 0 }
enforce_admins: { enabled: false }
```

`ci-gate` job (`.github/workflows/ci.yml:1159`) 은
`needs: [pr-sync-check, pr-live-gate, changes, meta, build, lint,
dashboard, health, structure-ratchet, shell-ir-ratchet, tla-specs]` 를
집계하여, `build`(compile) 또는 `lint` 등 required job 이 하나라도
`failure` 면 exit 1 → check `CI Gate` = failure. 즉 **compile break 를
잡도록 설계된 단일 required check 는 이미 존재한다** (line 1190-1201,
"dune build (compile-only) is HARD REQUIRED").

### §2.2 구멍은 enforcement 다 — 세 갈래

- **H1 `enforce_admins: false` (지배적)**: GitHub 의 이 설정은 "위 규칙을
  관리자에게 강제하지 않음" 을 의미한다. 컨베이어가 owner(admin) 토큰으로
  머지하면 `--admin` 플래그 없이도 required `CI Gate` 를 **항상 우회**한다.
  설계상 `CI Gate` 가 compile break 에 대해 정확히 `failure` 를 내도
  머지는 그 결과를 보지 않는다.
- **H3 mid-CI cancel + `if: always() && !cancelled()`**: 컨베이어가 CI
  진행 중에 머지하면 concurrency 그룹이 run 을 취소한다. `ci-gate` 는
  `!cancelled()` 가드 때문에 취소 시 보고 자체를 하지 않는다 → `CI Gate`
  가 `success` 에 도달할 기회가 없다. §1.1 의 다수 `cancelled` 가 이것이다.
- **H2 `strict: false`**: 머지 전 base 를 최신 main 으로 올릴 것을 요구하지
  않는다. PR 의 `CI Gate` 가 옛 base 기준으로 green 이어도 현재 main 위에
  올리면 깨질 수 있다 (split-merge: producer 없이 consumer 만, 혹은 stale
  base 가 sibling 작업을 revert). 이 결은 RFC-0235 가 별도로 다룬다(§5).

H1·H3 는 §1.1 의 3연쇄를 직접 설명한다 (모든 머지가 cancelled/failure
상태에서 admin 우회). H2 는 각 PR 이 자기 base 에서 green 이어도 발생하는
잔여 위험으로, H1 을 닫은 뒤에도 남는다.

---

## §3 제안 (Proposed gate)

### §3.1 불변식 (Invariant)

> **main 의 어떤 커밋도, 그 머지 대상 head commit 의 required check
> `CI Gate` 가 `success` 로 종료되기 전에는 main 에 도달하지 않는다.**

`pending` / `cancelled` / `failure` 는 전부 머지를 차단한다.
이는 결정론적이고 server-side 에서 측정 가능한 술어다.

### §3.2 메커니즘 — server-side enforcement

머저(컨베이어)는 in-repo GitHub Action 이 아니다. 저장소 내 머지 코드는
`lib/ide/ide_bridge.ml` 의 `gh_pr_merge` / `gh_api_pr_merge` 이벤트
핸들러뿐이며, 실제 트리거는 operator/keeper-side 다. 따라서 게이트를
워크플로 조건으로 강제할 수 없다 — **branch protection (server-side)** 이
유일하게 모든 머저(owner 토큰 포함)에 적용되는 지점이다.

1. **`enforce_admins: true`** (H1, H3 폐쇄, 핵심):
   ```
   gh api -X PATCH repos/jeong-sik/masc/branches/main/protection/enforce_admins
   ```
   관리자 토큰도 required `CI Gate` 에 묶인다. 컨베이어는 `CI Gate` 가
   `success` 가 될 때까지 머지할 수 없으므로, CI 를 취소하며 머지하던
   행동(H3)이 사라지고 완료를 기다린다.

2. **H2 (stale base) 처리** — 두 선택지, §7 에서 trade-off:
   - `strict: true` (머지 전 up-to-date 강제). 단순하지만 컨베이어 cadence
     에서 rebuild 비용이 크다 (RFC-0235 §80 이 "operationally heavy under
     admin-merge cadence" 로 기각한 그 비용).
   - GitHub **merge queue**: 큐가 각 후보를 최신 base 로 speculatively
     합쳐 CI 를 돌리고 통과분만 순차 머지. throughput 과 정합성을 함께
     얻지만, operator-side 머저가 큐를 경유하도록 바꿔야 한다.

### §3.3 결정론 / 휴리스틱 경계

- **결정론(이 RFC)**: "`CI Gate` = success" 술어, enforce_admins 설정,
  머지 차단. GitHub 가 강제한다.
- **휴리스틱(범위 밖)**: 어떤 PR 을 먼저 머지할지(우선순위), flaky test
  재시도 정책. 본 RFC 는 "green 이 아니면 머지 안 함" 만 강제하고, 무엇을
  머지할지는 정하지 않는다.

---

## §4 구현 범위 (Scope)

In scope:
- `repos/jeong-sik/masc/branches/main/protection` 의 `enforce_admins`
  를 `true` 로 (단일 API PATCH).
- (선택) `strict: true` 또는 merge queue 활성화 (§7 결정 후).
- operator/keeper-side 머저(`gh_pr_merge` 호출 경로)가 `--admin` 우회
  대신 `CI Gate` success 를 확인하고 머지하도록 정렬. server-side
  enforcement 가 있으면 머저는 실패하는 머지를 시도만 하고 거부당하므로,
  이 변경은 "조용한 실패 누적" 을 피하기 위한 정합성 작업이다.

Out of scope:
- 개별 incident 의 코드 fix (#21739/#21753/#21758, 이미 머지/진행).
- RFC-0235 의 content-revert 가드 (§5, 별도·상호보완).
- CI 속도 최적화 자체 (단, throughput 영향은 §7 에서 다룬다).

---

## §5 의존성 / 선례 (Dependencies)

- **RFC-0235 (stale-base revert guard, Draft, 미구현)**: stale base 가
  sibling PR 의 라인을 **무충돌로 revert** 하는 결을 content diff 로 잡는다.
  본 RFC 와 직교한다 — 0235 는 "머지가 기존 작업을 지움" 을, 0270 은
  "머지가 RED/미완 상태를 들임" 을 막는다. 0235 §80 은 `strict: true`(rebase
  always)를 admin-merge cadence 상 과도하다고 기각했는데, 0270 의
  `enforce_admins: true` 는 0235 가 택하지 않은 직교·고레버리지 지점이다.
  둘을 함께 적용하면 content-revert(0235) + red/incomplete-merge(0270) 가
  닫힌다.
- **RFC-0108 (pr-worktree-operation-safety-gates)**, **RFC-0260
  (provider-health-gate)**: "행동 전 결정론적 gate" 패턴의 선례.

---

## §6 검증 (Verification)

### §6.1 Replay — 3연쇄가 차단되는가

각 incident PR 의 head commit `CI Gate` 종료 상태 (측정값):

| PR | merge 시 `CI Gate` | enforce_admins:true 시 |
|---|---|---|
| #21714 | `cancelled` | 차단 (success 아님) |
| #21721 | `failure` | 차단 |
| #21722 | `cancelled` | 차단 |
| #21753 (fix) | `cancelled` | 차단 |

4/4 가 차단된다. 이는 H1(`enforce_admins:false`)이 지배적 근본 원인이고,
`enforce_admins:true` 단독으로 본 세션의 모든 안착을 막았을 것임을 보인다.
(H2 stale-base 는 이 4건에는 해당하지 않았다 — 전부 자기 CI Gate 가 이미
green 이 아니었다.)

### §6.2 TLA+ bug model (선택, software-development.md §TLA+ 패턴)

- `MainState`: `Green | Red`. `MergeCandidate`: `ci_gate ∈ {Success,
  Failure, Cancelled, Pending}`.
- `AdmitMerge`: `ci_gate = Success` 일 때만 main 에 후보 반영.
- `BugAction` `AdmitWhileNotGreen`: `ci_gate ≠ Success` 인데 머지.
- `SafetyInvariant` `MainCompilesAfterMerge`: 머지된 후보의 ci_gate 는
  Success 였다.
- clean `Spec` (AdmitMerge 만): invariant 만족.
- `SpecBuggy` (`Next \/ AdmitWhileNotGreen`): invariant 위반 →
  3연쇄와 동형.

양쪽 cfg 가 모두 통과(clean=no error, buggy=invariant violated)해야 spec
유효.

### §6.3 운영 측정 (acceptance)

- enforce_admins 활성 후, admin-bypass 머지 수가 0 으로 떨어지는지
  (§1.2 의 "22/80" baseline 대비).
- main HEAD 의 `CI Gate=success` 지속 비율(time-at-green)이 상승하는지.

---

## §7 대안과 trade-off (Alternatives)

핵심 긴장: `enforce_admins:true` 는 컨베이어가 `CI Gate`(Build ~27분 포함)
완료를 기다리게 하므로 머지 cadence 가 급감한다. 이것이 유일한 실질
비용이며, RFC-0235 §80 의 우려와 같은 축이다.

| 대안 | H1 | H2 | throughput | 비고 |
|---|---|---|---|---|
| (a) `enforce_admins:true`, `strict:false` (제안 코어) | 닫음 | 잔존(→0235) | 중간(각 PR 자기 CI만) | 3연쇄 전부 차단(§6.1). 가장 적은 변경 |
| (b) (a) + merge queue | 닫음 | 닫음 | 높음(speculative batch) | operator-side 머저를 큐 경유로 변경 필요 |
| (c) `strict:true` (rebase-always) | 닫음 | 닫음 | 낮음 | 0235 §80 이 과도하다고 기각 |
| (d) `--admin` 유지 + 컨베이어 self-check | (소프트) | (소프트) | 높음 | server 강제 아님 → regress 가능, 누적 위험 |

권고: **(a) 를 즉시 적용**(단일 PATCH, 3연쇄를 막는 검증된 최소 변경) 후,
throughput 이 문제가 되면 **(b) merge queue** 를 후속. (d) 는 거부 — server
강제가 없으면 "컨베이어가 봐주는" 우회가 다시 학습된다(CLAUDE.md 워크어라운드
누적 메커니즘).

trade-off 의 비대칭성: 느린 cadence 는 PR 들을 대기시킬 뿐이지만, RED main
은 **모든** 키퍼 rebuild·재시작을 막는다(이번 세션의 차단이 그 예). 따라서
correctness 를 cadence 보다 우선한다.

---

## §8 롤백 (Rollback)

```
gh api -X PATCH repos/jeong-sik/masc/branches/main/protection/enforce_admins -X DELETE
```
단일 API 호출로 이전 상태(`enforce_admins:false`)로 복귀. merge queue 를
켰다면 repo settings 에서 비활성.

---

## §9 열린 질문 (Open questions)

1. **컨베이어 머저의 정확한 경로**: in-repo 코드는 `lib/ide/ide_bridge.ml`
   `gh_pr_merge` 핸들러뿐이고 실제 트리거(operator/keeper-side)는 본
   조사에서 코드로 확정하지 못했다. server-side enforcement 는 경로와
   무관하게 적용되므로 제안은 유효하나, §4 의 머저 정렬 작업은 경로 확정이
   선행되어야 한다.
2. **`CI Gate` 의 `if: !cancelled()`**: enforce_admins:true 면 취소가
   사라질 것으로 예상되나, 별도 원인의 취소가 `CI Gate` 를 "보고 없음"
   으로 남길 수 있다. required check 가 "보고 없음=pending=차단" 으로
   동작하는지(GitHub 는 그렇게 동작) 운영 확인 필요.
3. **throughput 정량**: Build ~27분 기준 enforce_admins:true 하에서 실효
   머지율을 측정해 merge queue 필요성(§7b) 을 판단.
4. **flaky 처리**: §1.2 의 advisory 강등 정책과의 상호작용 — required job
   이 flaky 면 false-block 가능. advisory/required 분리(현 ci.yml 정책)가
   유지되는지 확인.
