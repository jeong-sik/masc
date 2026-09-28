---
rfc: "batch-validated-merge"
title: "병합 한 건마다 CI 한 주기를 돌리지 않는다 — 결합 트리 한 번의 검증과 멤버별 불변 증거"
status: Draft
created: 2026-09-28
updated: 2026-09-28 (r2: 멤버 판정 줄과 배치 줄 분리)
author: e-masc-the-leader
supersedes: []
superseded_by: null
related: ["#39421", "#39476", "#39465", "0270"]
implementation_prs: []
---

# RFC: 결합 트리 검증 병합 (batch-validated merge)

## 0. 요약

지금 R1 병합 규칙은 PR마다 "run 생성 이후 main이 PR 파일(또는 공통 입력)을 건드리지 않았다"를 요구한다.
main이 자주 움직이는 날에는 거의 모든 PR이 병합 직전에 다시 CI 한 주기(약 25분)를 기다린다.
#39421의 공통 입력 범위를 좁혀도 재생 결과 무효화가 107건에서 106건으로 줄 뿐이다(아래 1절).

이 RFC는 입력 목록을 손보는 대신 **병합 경로**를 바꾼다.

- 여러 PR의 head를 main의 한 지점(BASE) 위에 합친 결합 트리(ROLL)에서 CI를 한 번 돌린다.
- 그 한 번의 결과를 멤버 전원의 **신선도 증거**로 쓴다. R1 조건 가운데 "run 이후 main 겹침 0" 하나만 이 증거로 대신한다.
- 멤버마다 바뀌지 않는 증거(40자 head, 그 head 자신의 PR-check run을 가리키는 PASS 판정 줄, 그 head에 묶인 승인)를 붙인다. ROLL run을 멤버 head의 run이라고 적지 않는다.
- 착지 직전에 BASE 이후 main 변화와 최종 트리를 대조한다.

실패는 면제하지 않는다. 결합 트리가 빨가면 그 배치는 착지하지 않는다.

## 1. 문제 — 입력 목록만으로는 처리량이 안 풀린다

- 운영자 제약(2026-09-28, [규약 제안 #4] c-f3f73a24): "CI 가 병목이 되면 안되는데". 병합 한 건마다 CI 한 주기를 강제하는 정책은 기본으로 받아들이지 않는다.
- #39421 수정 head 8220fb60839df68252dc2757368fba43b0bc7190의 재생(root 세션, issuecomment-5862656170):
  - 식별 가능한 성공 run 108건(PR 72개) 가운데 무효화는 107건 → 106건
  - 471건은 판정 불가로 제외
  - test/dune을 바꾼 main 커밋 34건은 모두 여전히 무효화
- #39476 실측: 09-26 07:40Z–09-27 07:40Z에 test/dune 병합 34건이 성공 run 81건을 병합 근거에서 뺐다.

공통 입력을 "실제로 읽는다는 근거가 있는 경로"로 좁히는 일은 맞고 필요하다. 그러나 병합이 잦은 저장소에서는 PR 하나하나가 "자기 run 이후 main이 조용했다"를 증명하는 구조 자체가 병목이다.

## 2. 실측 근거 — 이미 7번 해 본 방식

2026-09-25~27에 리더가 같은 방식을 수동 스크립트로 7번 돌렸다. 스크립트와 로그는 리더 레인 작업 공간(rv/rollup/*/land.sh, rv/v039/tools/land-rollup-r1d.sh)에 있어 저장소 밖이다. 공개 기록은 각 CI 전용 PR의 닫기 댓글(#39452, #39465, #39467 등)이다.

| 롤업 | BASE | ROLL | 결합 트리 PR-check run | 착지한 멤버 | 비고 |
|---|---|---|---|---|---|
| v041-r1 | 895905b660 | e28d7c13d0 | 36217335912 | 2 (#39145, #39172) | |
| tui6-r1 (#39452) | 651f492aef | eddd7d958f | 36288553909 | 7 | 롤업 파일 33개, 착지 전 BASE 이후 겹침 0 |
| tui7-r1 (#39465) | 141926314e | d7d29b0afe | 36290780720 | 4 | 컷 뒤 #39293 head 이동을 09-25 규칙으로 유지(remerge-diff 0, +/- 해시 동일) |
| tdune-r1 | 1265681a72 | fee18de108 | 36306092046 | 4 | edited-tests 219개 실행·0개 건너뜀 |
| tdune-r2 | 5064f3f186 | bfa9de9283 | 36308099301 | 4 | 첫 컷이 #39301 때문에 release 빌드 실패 → #39301을 빼고 r3로 이월 |
| tdune-r3 | 20dea3d0c8 | 0e1b157f86 | 36313554597 (+ 전체 Test 36314759317) | 2 | |
| pf1-r1 (#39467) | b8341cd16b | 6c9e3666e2 | 36294261425 | 2 | 착지 후 main과 롤업 트리 차이 0파일 |

합계: **결합 트리 run 7번으로 25건을 착지**했다. 일곱 롤업의 착지 기록(리더 레인의 close·land 로그)에는 모두 최종 트리 대조 통과(`TREE OK`)가 남아 있다.

실패를 면제하지 않은 사례도 있다.
- tdune-r2: 멤버 하나가 결합 트리를 빨갛게 만들자(warning 8) 그 멤버를 빼고 다시 잘랐다. 빨간 run을 근거로 착지한 멤버는 없다.
- tui6-r1: CI 도중 롤업 파일을 건드린 비멤버 병합(#39406)이 들어와 run이 stale이 됐고, 다시 잘라 새 run으로 착지했다.

### 2.1 09-25 v0.39 롤업(r1 → r1c → r1d)과 tui7-r1의 좌표

위 표의 일곱 번보다 먼저, 09-25에 v0.39 롤업을 r1 → r1c → r1d로 세 번 다시 잘랐다. 모두 CI 전용 PR #38925(브랜치 rollup/v039-r1)에서 돌았다. 3.1·3.3·3.5의 규칙은 이 과정과 tui7-r1에서 나왔으므로 run과 Board 기록을 그대로 적는다. Board 댓글은 전부 전체 id다.

| 롤업 | ROLL head | run | 결과 | 기록 |
|---|---|---|---|---|
| r1 | a3d2bb10d3e831f292feab46b3da70fd7e2bf65b | PR check 36076756737 | failure. edited-tests 단계 1080초 예산에서 244개 실행, 54개 미도달 | Board c-935b1b06cea9bfe0d0753f130305516a (p-de3d67edc5c63d23b5f5a411dce004f6) |
| r1c | 8105fc27ebc557568c74d56407348655b9c46a84 (BASE 6985cafadc, 멤버 11) | PR check 36079355151 | cancelled. r1d로 다시 자르면서 새 push가 대체함 | Board c-fef29b22395158517017ac4a81dcfcaf (같은 글): 비멤버 병합 #38620·#38730·#38733이 롤업 파일을 건드려 r1을 버리고 다시 잘랐고, head에 판정 뒤 코드 커밋이 생긴 #38803은 뺐다. 3.3의 "BASE 이후 비멤버 겹침이면 다시 자른다"의 출처 |
| r1d | d4cf505f404c11bf50d657d029a9d1842c4bf029 | PR check 36079784023 + Test 36079787456, 36082757057 | PR check는 failure. 미통과 목록 52건이 모두 예산 미도달(job 107899150417 로그)이다. 같은 head의 targeted Test 36079787456에서 56개 스위트가 OK, FAIL 0이고, 36082757057에서 3개가 OK다 | Board c-935b1b06cea9bfe0d0753f130305516a: 3.5 예산 규칙의 출처. PR #38925 구성 감사 issuecomment-5824888941, 닫기 issuecomment-5830732833(묶은 13건 중 12건이 main에 있고 #38912는 따로 진행) |
| tui7-r1 | d7d29b0afe39544e7449e8de165ed36b127d2a91 (BASE 141926314e) | PR check 36290780720 | success. 멤버 4건 착지 | Board c-9e4bfd559eefee2f66768f5100becb9a (p-ea1aaac11b79ea30a79e024ae2952b86): 마지막 멤버 #39293의 승인을 push하지 않은 세션으로 보냄. Board c-82a90cc7da99c160c8d023047cda9340: 03:52:27–38Z 착지, 트리 대조 OK. PR #39465 닫기 issuecomment-5852428905 |

r1d의 멤버가 모두 롤업 경로로 착지했는지는 다시 세지 않았다. #38925의 닫기 댓글이 적은 "12건이 main에 있다"를 그대로 옮긴다.

## 3. 설계

### 3.1 배치 단위

- 배치 = (BASE, ROLL, MEMBERS).
  - BASE: 자르는 시점의 main 40자 SHA.
  - MEMBERS: `(PR, head40)` 목록. 멤버 순서는 착지 순서다.
  - ROLL: BASE 위에 멤버 head를 차례로 병합한 커밋(`rollup/<name>` 브랜치).
- 배치 신선도 증거 = ROLL에서 돈 PR-check run 한 번(필수 5개 success)과 3.5의 보충 run. 이 run은 ROLL 커밋에 붙은 run이며 어떤 멤버 head의 run도 아니다.
- 배치는 CI 전용 PR로 올리며 그 PR 자체는 병합하지 않는다. 멤버를 착지한 뒤 닫는다.
- 롤업 파일(roll files) = `git diff --name-only BASE ROLL`.

### 3.2 멤버별 불변 증거

멤버마다 아래가 모두 있어야 한다. 하나라도 없으면 그 멤버는 착지하지 않는다(rc 6).
1. 현재 PR head = MEMBERS에 적힌 head40. 컷 뒤 head가 움직였다면 다음을 **모두** 만족할 때만 유지한다(09-25 규칙). 아니면 배치에서 뺀다.
   - parent1 = 적힌 head
   - parent2 = BASE
   - `git show --remerge-diff` 0줄
   - PR +/- 줄 해시 동일
2. 그 head에 대한 PASS 판정 줄. 첫 줄은 `verdict: PASS head: <head40> run: <run> by: <Keeper>`이고 push하지 않은 세션이 쓴다.
   - `run:`은 **그 멤버 head 자신의 PR-check run**이다(run의 head_sha = head40, 필수 5개 success). 지금 계약과 같고 이 RFC는 판정 줄을 바꾸지 않는다.
   - 그 run이 main 이동으로 stale이어도 된다. stale 여부는 판정 줄이 아니라 3.2a의 배치 줄이 다룬다.
3. 그 head에 묶인 승인. approve-guard footer의 head = head40이고, 승인 계정 ≠ PR 작성 계정이며, 승인 세션은 push하지 않은 세션이다.
4. 열린 CR 없음, Draft 아님, base = main.
5. 그 head에 대한 FAIL이 없거나, 있다면 인용한 줄이 바뀌었다.

### 3.2a 멤버 ↔ ROLL 증거 연결과 계약 변경

**배치 줄.** 배치 PR에 리더가 아래 한 줄을 남기고, 각 멤버 PR에도 같은 줄을 코멘트로 옮긴다.

```
batch: PASS roll: <ROLL40> base: <BASE40> run: <ROLL PR-check run> members: <PR>@<head40>,<PR>@<head40>,... by: <Keeper>
```

- `run:`의 head_sha는 ROLL40이어야 한다. 멤버 head가 아니다.
- 멤버 ↔ ROLL 연결은 `members:` 목록 하나로만 정한다. 멤버의 현재 head40이 목록에 없으면 그 멤버는 배치 증거를 쓸 수 없다.
- 가드는 BASE 위에 목록 순서대로 멤버 head를 병합한 트리를 다시 계산해 ROLL 트리와 같은지 확인한다. 줄에 적힌 값만 믿지 않는다.

**R1에서 바뀌는 것은 한 조건뿐이다.**

| R1 조건 | PR별 경로 | 배치 경로 |
|---|---|---|
| PASS 줄(현재 head, 그 head의 PR-check run, by: Keeper) | 필요 | 필요 (그대로) |
| 멤버 head의 필수 5개 success | 필요 | 필요 (그대로, 멤버 자신의 run) |
| 미해결 CR·FAIL 없음, Draft 아님 | 필요 | 필요 (그대로) |
| approve-guard 승인(head 묶임, 계정·세션 독립) | 필요 | 필요 (그대로) |
| run createdAt 이후 main과 PR 파일 겹침 0 | 필요 | **대체**: 배치 줄의 ROLL run success, 그리고 BASE 이후 비멤버 main 커밋이 롤업 파일·공통 입력을 건드리지 않음(3.3) |

**그래서 아끼는 CI 주기는 "재실행"이다.** 멤버의 첫 PR-check run은 판정을 받으려면 어차피 돈다. PR별 경로에서 main이 움직일 때마다 생기는 update-branch → 새 head → 새 run → 재판정의 사슬을 ROLL run 한 번이 대신한다. 롤업 7번에서도 멤버는 자기 head의 run을 인용한 PASS 줄을 이미 가진 PR이었고, 착지 근거로 새로 돈 것은 ROLL run뿐이었다.

**바꿔야 할 문서와 코드(채택 뒤, 구현 PR에서):**
1. 월드 헌법 조항 a-7e31026d("승인과 병합은 필수 체크 5/5 성공, 해당 run 이후 main과 PR 파일의 겹침 0, …")의 겹침 절에 "또는 그 head가 들어 있는 배치 줄의 ROLL run이 success이고 BASE 이후 비멤버 main 커밋이 롤업 파일과 공통 입력을 건드리지 않았을 때"를 더한다. 내부 규약 개정 절차를 따른다.
2. docs/constitution.xml의 판정 줄 형식 조항은 바꾸지 않는다. 배치 줄은 판정 줄이 아니다.
3. approve-guard.sh: 승인 본문의 첫 줄(판정 줄)과 마지막 줄(가드 footer) 규칙은 그대로 둔다. 배치 경로 승인일 때는 둘 사이에 배치 줄을 그대로 넣는다. 가드는 그 줄의 `members:`에 현재 head40이 있고 ROLL run이 success인지 확인한다.
4. merge-guard.sh·ci-freshness.py(#39421): 신선도 판정이 "PR run 이후 겹침 0" 또는 "배치 줄 + 3.3 stale 검사 통과" 둘 중 하나를 받는다. 둘 다 아니면 막는다.
5. GitHub ruleset 21530056은 바꾸지 않는다. 2026-09-28 직독 기준 필수 상태 체크는 `dune build @check` 하나이고 strict(최신 main 요구)는 false다. 필수 체크는 멤버 head 자신의 run이 이미 채운다. 2절의 25건도 지금 ruleset 아래에서 착지했다.

### 3.3 착지 검사

착지 직전(`land --check-only`)과 착지 중에 차례로 확인한다.
1. **stale**: BASE 이후 main에 들어온 비멤버 커밋 가운데 롤업 파일을 건드린 것이 있으면 착지하지 않고 다시 자른다(rc 5). 전역 입력(테스트 선택기, opam 핀 등 #39421 ci-freshness.py가 정하는 공통 입력)을 건드린 경우도 같다.
2. 멤버를 순서대로 `--match-head-commit`(스택 부모는 sha를 고정한 merge-async)으로 병합하고, 매번 병합 커밋 부모 = 직전 main인지 확인한다.
3. **트리 대조**: 착지 후 main과 ROLL을 비교해 차이 나는 파일이 비멤버 커밋의 변경뿐이면 통과, 그 밖의 차이가 있으면 rc 4로 멈추고 알린다.

### 3.4 ci-freshness.py와 merge-guard.sh 연결 (#39421)

- ci-freshness.py는 PR별 run 신선도 판정에 **배치 신선도**라는 두 번째 입력을 받는다. 멤버 PR이 배치 매니페스트(BASE, ROLL, MEMBERS, ROLL run id)에 들어 있으면, 그 PR의 신선도는 "ROLL run이 success이고, BASE 이후 비멤버 main 커밋이 롤업 파일·공통 입력을 건드리지 않았다"로 판정한다.
- merge-guard.sh는 배치 착지일 때 매니페스트를 인자로 받아 3.2와 3.3을 검사한다.
  - 매니페스트는 3.2a의 배치 줄이다.
  - 가드는 GitHub에서 ROLL 트리가 BASE+멤버 head의 병합과 같은지 다시 계산해 확인한다. 매니페스트만 믿지 않는다.
- 면제 경로를 만들지 않는다. 배치 경로가 받는 것은 **다른 증거 한 가지**(더 늦게, 더 넓게 합친 트리의 성공)뿐이다. 빨간 run, 열린 FAIL, 열린 CR은 PR별 경로와 똑같이 막는다.

### 3.5 예산을 넘긴 스위트

PR check의 edited-tests 단계는 1080초 예산이 있다. 멤버가 많으면 일부 스위트가 "(not run: the step budget ran out)"으로 남는다.
- 그 목록 전체를 같은 ROLL head의 targeted Test run(`test.yml -f suite=…`)으로 돌려 모두 OK여야 배치가 성립한다(09-25 r1d 선례: run 36079787456).
- 예산 초과 항목이 하나라도 초록으로 덮이지 않으면 rc 3이다.

### 3.6 PR마다 그대로 남는 것

- FAIL 판정과 CR, 운영자 HOLD, hold 단어(Breaking / Fresh state required / now rejected) 검사
- changelog 조각 요구
- 승인 계정·세션 독립성
- 워크플로 파일 스코프 제약

배치는 **CI 증거**만 공유한다. 판정과 승인은 멤버마다 따로다.

## 4. 불변식 (배치 경로가 PR별 경로보다 약해지지 않는 이유)

1. main에 들어가는 모든 트리 상태는 실제로 CI가 돈 트리(ROLL)와 같거나, ROLL에 롤업 파일과 겹치지 않는 비멤버 변경만 더한 것이다. 3.3이 이를 기계적으로 확인한다.
2. 어떤 멤버도 자기 head에 대한 판정·승인 없이 착지하지 않는다.
3. 빨간 run은 어떤 경로로도 근거가 되지 않는다. 멤버 하나가 빨강이면 그 멤버를 빼고 다시 자른다(tdune-r2 선례).

## 5. 재생 추정

- 롤업 7번의 실측: 결합 트리 run 7번으로 25건이 착지했다. 멤버는 롤업 예약(sched-705766a8)의 선정 기준대로 "자기 head의 초록 run이 main 이동으로 stale이 됐거나, 서로 같은 파일을 건드려 순차 병합하면 뒤 PR이 stale이 되는 PASS PR"에서 골랐다. 25건 모두 PR별 경로에서 착지 전 새 run이 한 번씩 필요했다면 **재실행 18번을 아낀 셈**이다. 이 기준이 멤버마다 성립했는지는 이 RFC에서 다시 세지 않았다. 반대 방향으로, 순차 병합 중 다시 stale이 되어 생기는 추가 재실행도 세지 않았다. 멤버의 첫 run은 두 경로 모두 필요하므로 이 셈에 넣지 않았다.
- #39421 재생과 같은 09-26~27 병합 집합에 대한 추정은 이 레인에서는 **계산할 수 없다**. root 세션의 packet(`/private/tmp/masc-ci-throughput-20260928/`)을 Keeper 샌드박스에서 읽을 수 없기 때문이다. 같은 packet으로 "그 시각 열려 있던 PASS PR을 배치로 묶었을 때 필요한 결합 run 수"를 root 세션에 요청한다.

## 6. 비목표

- GitHub merge queue 도입: 개인 계정 저장소라 쓸 수 없다(2026-09-24 확인).
- 모든 병합을 배치로 강제하기: 단독으로 신선한 PR은 지금처럼 PR별 경로로 착지한다.
- 공통 입력 목록 자체의 설계: #39421에서 다룬다.

## 7. 열린 질문

1. 배치 줄 원본을 어디에 둘까. 후보는 CI 전용 PR 코멘트와 저장소 안 파일이다. 코멘트는 편집 이력이 남지만 형식 강제가 약하다. 어느 쪽이든 가드는 트리 재계산으로 확인한다.
2. 배치를 누가 자를까. 지금은 리더가 사람 판단으로 멤버를 고른다. 자동 후보 선정(PASS·승인 있음, 서로 파일이 겹치거나 모두 stale)의 기준을 정해야 한다.
3. 배치 크기 상한. edited-tests 예산 기준으로 약 250개 스위트가 한 run에 들어간다(09-25 r1 실측: 244개 실행, 54개 미도달).

## 8. 구현 순서

1. 이 RFC 채택(내부 규약 개정 절차).
2. 리더 레인의 land-template.sh를 저장소 스크립트(scripts/review/land-batch.sh)로 옮기고, 3.3의 rc 표를 고정하는 selftest를 붙인다.
3. #39421 ci-freshness.py·merge-guard.sh에 배치 매니페스트 입력을 넣고, 빨간 ROLL run·움직인 멤버 head·롤업 파일을 건드린 비멤버 커밋 각각이 착지를 막는 음성 대조 테스트를 넣는다.
