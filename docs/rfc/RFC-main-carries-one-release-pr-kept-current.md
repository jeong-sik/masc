---
rfc: "main-carries-one-release-pr-kept-current"
title: "main 에는 늘 최신인 릴리즈 PR 하나가 있고, 그 PR 을 병합하면 릴리즈가 잘린다"
status: Draft
created: 2026-11-27
updated: 2026-11-27
author: claude
supersedes: []
superseded_by: null
related: []
---

# main 에는 늘 최신인 릴리즈 PR 하나가 있고, 그 PR 을 병합하면 릴리즈가 잘린다

## 0. 요약

릴리즈를 자를 때마다 main 이 멈춘다. 버전 올림 PR 이 만든 시점의 changelog 조각만 모으기 때문이다.
그 PR 이 들어가기 전에 다른 PR 이 하나라도 병합되면 조각이 빠진다. 그래서 리더가 `MASC_RELEASE_FREEZE=1` 로 main 을 세운다.

이 RFC 는 버전 올림 PR 을 워크플로가 늘 최신으로 유지하게 한다. main 에 push 가 있을 때마다 그 PR 을 다시 만든다.
PR 이 낡지 않으니 main 을 세울 일이 없다. 릴리즈를 자르는 일은 그 PR 을 병합하는 일 하나가 된다.

- D1: 워크플로가 main 의 최신 커밋에서 `scripts/bump-version.sh` 를 돌려, 릴리즈 PR 하나를 열거나 갱신한다.
- D2: 릴리즈 PR 의 병합 커밋에 태그를 달고 RC 를 돌린다. 태그 커밋은 main 에 있으니 `check_tag_ancestor` 를 그대로 통과한다.
- D3: 릴리즈 흐름은 `MASC_RELEASE_FREEZE` 를 읽지도 쓰지도 않는다. 이 변수는 운영자의 장애 브레이크로만 남는다.
- D4: 릴리즈 범위는 언제 병합하느냐와 feature flag 로 정한다.

## 1. 지금 일어나는 일

### 1.1 2026-11-27 v0.83.6 컷

| 시각(UTC) | 일 |
|---|---|
| 04:58 | 리더가 컷을 시작하며 `MASC_RELEASE_FREEZE=1` |
| 06:35 | 버전 올림 PR #55142 Ready(base `a8a00684`, 파일 32개: `changelog.d` 29, `CHANGELOG.md`, `dune-project`, `masc.opam`) |
| 07:20 | 운영자가 동결을 끔. 그때까지 #55142 리뷰 0건 |
| 07:24 | sweep 이 스택 #55045 를 병합. 조각 4개가 #55142 밖에 생김 |
| 07:43 | 리더가 동결을 다시 켬. 이유: "#55142 가 다시 낡지 않게" |
| 08:03 | 운영자가 다시 끔 |

- 동결된 약 2시간 20분 동안 병합 0건, 새 PR 50건이었다. 그 전 6시간은 34건 열리고 31건 병합됐다.
- 리더 세션 기록은 규칙(「`MASC_RELEASE_FREEZE` 는 운영자 비상 브레이크 전용」)을 읽고도 "지난 6번의 릴리즈가 모두 동결을 썼다"를 따랐다.
- 지시문이나 규칙을 고쳐도 같은 압력이 남는다. 버전 올림 PR 이 낡는 구조가 그대로이기 때문이다.

### 1.2 릴리즈 브랜치로 돌아가지 않는 이유

이 저장소는 릴리즈 브랜치를 이미 써 봤다.

- v0.49.0·v0.50.0: 릴리즈 브랜치가 main 에 squash 커밋으로 돌아왔다. 태그가 main 의 조상이 아니게 됐고, `git describe` 가 v0.48.0 을 골랐다(#42169, `scripts/bump-version.sh` 주석).
- v0.70.0: 릴리즈 브랜치에서 조각을 모았고, 그 모음이 main 에 닿은 건 PR 95개가 지난 뒤였다.
- v0.77.0: 태그를 단 bump 커밋이 main 에 닿지 않았다. 같은 bump 가 다른 커밋으로 들어왔다(#54183). 그래서 `check_tag_ancestor` 가 생겼다(#54262).

main 이 squash 병합만 받는 한, 브랜치에 단 태그는 main 에 같은 커밋으로 들어오지 않는다.

## 2. 결정

### D1. 릴리즈 PR 은 워크플로가 만든다

- 새 워크플로 `.github/workflows/release-pr.yml` 이 main push 와 `workflow_dispatch` 에서 돈다.
- 한 번 돌 때 하는 일
  1. main 최신 커밋을 받는다.
  2. 다음 버전 번호를 정한다(D1.1).
  3. `scripts/bump-version.sh <버전>` 을 돌린다. 지금 리더가 손으로 하는 것과 같은 스크립트다. 조각 검사(`check`, `missing`, `folded`)와 조각 모음(`assemble`)이 그 안에서 돈다. 이어서 `scripts/check-version-truth.sh` 를 돌린다.
  4. 결과를 고정 브랜치 `release/next` 에 force-push 한다.
  5. 열린 릴리즈 PR 이 없으면 연다. 있으면 제목(`chore(release): vX.Y.Z`)과 본문만 고친다.
- `concurrency` 그룹 하나로 한 번에 하나만 돌고, 기다리던 실행은 가장 새것만 남긴다.
- 스크립트가 실패하면(조각 형식 오류 등) PR 을 고치지 않고 실패로 끝난다. 실패한 이유는 run 로그와 PR 댓글에 남긴다.

#### D1.1 다음 버전 번호

- 기본값은 쌓인 조각의 분류로 정한다.
  - `Added`·`Changed`·`Deprecated`·`Removed` 조각이 하나라도 있으면 minor 를 올린다.
  - 그 밖(`Fixed`·`Performance`·`Documentation`·`Internal`·`Known issues`)만 있으면 patch 를 올린다.
- `workflow_dispatch` 의 `version` 입력으로 운영자나 리더가 번호를 직접 줄 수 있다. 다음 main push 까지는 그 번호를 쓴다.
- 이 규칙은 열린 질문 Q2 다.

#### D1.2 토큰

- `GITHUB_TOKEN` 으로 연 PR 에서는 필수 검사(`changes`·`type-check`)가 바로 돌지 않는다. GitHub 문서: "events triggered by the `GITHUB_TOKEN` will not create a new workflow run". `pull_request` 의 opened·synchronize 는 예외지만, 쓰기 권한자가 "Approve workflows to run" 을 눌러야 돈다.
- 그래서 GitHub App 설치 토큰이나 PAT 로 push 하고 PR 을 연다. 어느 계정을 쓸지는 운영자가 정한다(Q1).

### D2. 병합이 곧 컷이다

- 릴리즈 PR 이 병합되면 main 에 squash 커밋이 하나 생긴다. 이 커밋이 `dune-project` 의 버전을 바꾸고, 같은 번호의 태그는 아직 없다.
- `release-pr.yml` 의 다른 job 이 이 상태를 보고 두 가지를 한다.
  1. 그 커밋에 `vX.Y.Z` 태그를 단다.
  2. 그 태그로 `release-candidate.yml` 을 dispatch 한다.
- 발행(`release.yml`)은 지금처럼 운영자 승인 뒤에 돌린다. RC run id 를 넘기는 방식도 그대로다.
- 태그 커밋은 main 의 조상이라 `check_tag_ancestor` 를 바꾸지 않는다.
- RC 가 실패하면 지금처럼 앞으로 간다. main 에서 고치고, 릴리즈 PR 이 다음 patch 로 다시 만들어지고, 그걸 병합한다.

### D3. 릴리즈 흐름에는 동결이 없다

- `release-pr.yml`·`release-candidate.yml`·`release.yml` 은 `MASC_RELEASE_FREEZE` 를 읽지도 쓰지도 않는다.
- 이 변수와 `freeze-exempt` 라벨은 운영자가 장애 때 자동 병합을 세우는 브레이크로만 남는다. 지금 코드(`scripts/review/release-freeze.py`)는 바뀌지 않는다.
- 릴리즈 PR 을 기다리는 동안에도 main 은 병합을 받는다. 그 사이 들어온 PR 은 다음 갱신에서 릴리즈 PR 에 같이 모인다.

### D4. 범위는 시점과 flag 로 정한다

- 릴리즈에 무엇이 들어가는지는 "언제 릴리즈 PR 을 병합하느냐"로 정한다. 병합 시점의 main 전체가 들어간다.
- 아직 내보낼 수 없는 기능은 feature flag 나 opt-in 설정 뒤에 둔다. 지금 `docs/guides/RELEASE-FREEZE.md` 에 이미 있는 방침이다.
- 리더는 릴리즈 시점을 정한다. PO(`masc-productor-owner`)는 기능 단위나 마일스톤 단위로 무엇이 다음 릴리즈 전에 main 에 닿아야 하는지 나눈다.

## 3. 바뀌지 않는 것

- main 은 squash 병합만 받는다. 태그는 main 의 조상 커밋에만 단다(`check_tag_ancestor`).
- 조각 형식(`changelog.d/<PR>.md`)과 `scripts/changelog-fragments.py` 의 검사는 그대로다.
- RC 세 축(compile·behavior·installation)과 발행 절차, 운영자의 발행 승인은 그대로다.
- 릴리즈 PR 도 다른 PR 처럼 작성자 외 1계정 승인 뒤 병합된다.

## 4. 위험과 대응

| 위험 | 일어나는 일 | 대응 |
|---|---|---|
| 갱신이 승인을 지운다 | `dismiss_stale_reviews_on_push` 라서 main 이 움직이면 승인이 사라진다 | 승인 뒤 자동 병합은 약 30초 안에 일어난다. 그 사이 갱신되면 다시 승인한다. 릴리즈 PR 의 내용은 스크립트 출력이라 다시 보는 데 오래 걸리지 않는다 |
| 리뷰어가 볼 게 많다 | 파일 30개 남짓, 대부분 조각 삭제 | 새 검사 `release-pr` 가 "이 PR 의 diff 는 base 에서 `bump-version.sh` 를 돌린 결과와 같다"를 확인한다. 리뷰어는 버전 번호와 `CHANGELOG.md` 문장만 본다 |
| 병합 직전 갱신과 병합이 겹친다 | 병합기가 옛 head 로 병합을 낸다 | 병합기는 `gh pr merge --squash --match-head-commit <head>` 로 병합한다(`scripts/review/approval-auto-merge.py`). head 가 다르면 병합되지 않고 다음 승인을 기다린다 |
| 토큰이 새면 | 그 계정으로 push·PR 이 가능하다 | 토큰 권한을 `contents`·`pull-requests` 두 가지로 좁히고, `release/next` 브랜치 하나만 쓴다 |

## 5. 확인 방법

- 구현 PR 의 시험
  - 버전 번호 규칙: 조각 분류 조합별 기대 번호.
  - 같은 main 커밋에서 두 번 돌면 브랜치 내용이 같다.
  - 조각 형식 오류면 PR 을 고치지 않고 실패한다.
- 배포 뒤 실측(다음 릴리즈 두 번)
  - Keeper 가 `MASC_RELEASE_FREEZE` 를 켠 횟수: 0 이 목표다(기준선: v0.83.6 컷에서 리더가 2번).
  - 릴리즈 기간(릴리즈 PR 병합 결정 → 발행) 중 main 병합 수: 0 보다 크다(기준선: 동결된 약 2시간 20분 동안 0건).
  - 릴리즈 PR 을 손으로 rebase·재생성한 횟수: 0 이 목표다.

## 6. 다른 방법

| 방법 | main 동결 | 릴리즈마다 손이 가는 일 | 저장소 규칙 변경 | 판단 |
|---|---|---|---|---|
| 지금(손으로 만든 버전 올림 PR) | 리더가 건다 | 컷, rebase, 재생성, 동결 관리 | 없음 | 동결 압력이 남는다 |
| 이 RFC(늘 최신인 릴리즈 PR) | 없음 | 병합 하나 | 워크플로 추가, 토큰 | 채택 제안 |
| 릴리즈 브랜치 + 백포트 | 없음 | 브랜치 자르기, 백포트, main 으로 되돌리기 | `check_tag_ancestor` 완화, 노트 범위 계산 변경 | 1.2 의 문제가 돌아온다. LTS 가 필요해지면 다시 본다 |

참고한 제품: release-please 는 "Rather than continuously releasing what's landed to your default branch, release-please maintains Release PRs"이고 "These Release PRs are kept up-to-date as additional work is merged" 다. 병합하면 changelog 를 고치고, 커밋에 태그를 달고, GitHub Release 를 만든다(https://github.com/googleapis/release-please). 이 RFC 는 태그·RC 까지만 자동으로 하고 발행은 운영자 승인으로 남긴다.

## 7. 열린 질문

- Q1. 릴리즈 PR 을 여는 계정: GitHub App 을 새로 둘지, 기존 Keeper 계정의 PAT 를 쓸지.
- Q2. 다음 버전 번호 규칙(D1.1)이 지금 리더의 판단(v0.83.0 → v0.83.5 는 patch, v0.82.0 → v0.83.0 은 minor)과 맞는지.
- Q3. 릴리즈 PR 승인을 누가 하는지: 코드 리뷰 Keeper 가 할지, 운영자가 할지.
- Q4. 태그와 RC dispatch 를 워크플로가 할지, 지금처럼 리더가 할지.

## 8. 이 RFC 가 채택되면 같이 고칠 것

- `docs/guides/RELEASE-FREEZE.md`: 절차를 D1~D4 로 바꾼다. 비상 브레이크 절은 남긴다.
- 리더(`e-masc-the-leader`) 지시문: 릴리즈를 자르는 일이 릴리즈 PR 병합이라는 사실을 덧붙인다.
- `pr-updater` 지시문: 동결 해제를 사건으로 보고하지 않도록 같은 사실을 덧붙인다.
