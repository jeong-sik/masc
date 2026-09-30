---
name: masc-pr-patrol
description: "MASC 스택 PR의 현재 head를 읽고 기능·논리·코드 청결도를 리뷰한다. 일반 PR은 source review, Release/Tag는 명시적 Full CI 증거로 판단한다."
---

# MASC PR 순찰

먼저 `docs/constitution.xml` 전체를 읽는다. 실행 규약과 운영자의 지시가 이 문서보다 우선한다.
일반 PR에는 CI green이나 run ID를 요구하지 않는다. 자동 CI dispatch·watch·대기·반복 조회를 하지 않는다.

## 현재 변경 읽기

```sh
gh pr list --repo jeong-sik/masc --state open --json number,title,headRefName,baseRefName,isDraft
gh pr view <N> --repo jeong-sik/masc --json headRefOid,baseRefName,isDraft,reviews,comments
gh pr diff <N> --repo jeong-sik/masc
```

현재 head와 base, 원래 작업 계약, 전체 diff를 직접 확인한다. 이전 리뷰·과거 녹색 CI·요약은 현재 변경의 증거가 아니다.
Draft는 작업 중이라는 뜻이다. CI가 없다는 이유로 일반 PR을 Draft로 되돌리거나 승인 대기시키지 않는다.

## 여러 관점에서 리뷰

기능과 사용자 흐름, 상태 전이·실패 처리 논리, 코드 청결도를 독립적으로 확인한다.
P0·P1·P2가 남으면 구체적인 위치·트리거·영향·수정 방향을 기록한다. 남은 문제가 없으면 승인한다.
P3는 모아서 후속 청소로 처리한다. 자기 변경은 자기가 승인하지 않는다.

일반 스택 판정 첫 줄:

```
verdict: PASS head: <40-hex SHA> by: <reviewer>
```

```sh
bash scripts/review/approve-guard.sh --check --repo jeong-sik/masc --pr <N> --head <SHA>
bash scripts/review/approve-guard.sh --repo jeong-sik/masc --pr <N> --head <SHA> --body <review-file>
```

`approve-guard.sh`는 현재 head와 신뢰할 수 있는 독립 승인, 최신 FAIL/HOLD와 미해결 변경 요청을 확인한다.
일반 head에는 Actions API를 읽지 않는다. GitHub 계정 제한 때문에 자기 PR에 공식 APPROVE를 쓸 수 없으면
독립 리뷰의 결과와 제약을 명시하며 자기 승인을 만들지 않는다.

## 스택과 병합

PR은 스택으로 작성한다. 가장 아래 PR은 main, 상위 PR은 직전 브랜치를 base로 삼는다.
상위 PR도 부모가 병합되기 전에 리뷰·승인할 수 있다. 실제 main 반영은 아래부터 진행한다.
부모 병합·base 변경 뒤에는 diff와 충돌, 중복 함수·되살아난 삭제 코드를 다시 확인한다.

```sh
bash scripts/review/queue-ledger.sh --repo jeong-sik/masc --format tsv
bash scripts/review/merge-guard.sh --check --repo jeong-sik/masc --pr <N> --head <SHA>
```

외부 코딩 에이전트의 실제 병합은 `gh pr merge --match-head-commit <SHA>`를 쓴다.
`--auto`·`--admin`을 쓰지 않는다. 병합 직전에 최신 리뷰와 head를 다시 읽는다.

## Release/Tag 검증

`release/vX.Y.Z`에서 명시적으로 `release-candidate.yml` Full CI Cycle을 실행한다.
현재 head의 전체 빌드·타입·기능·설치 검증이 완료되어 성공한 run을 판정에 기록한다.
필수 작업이 실패·대기·skip·미등록이면 릴리스 성공 증거가 아니다. 일반 스택에 이 조건을 확대하지 않는다.

```
verdict: PASS head: <40-hex SHA> run: <full CI run ID> by: <reviewer>
```

```sh
bash scripts/review/merge-guard.sh --check --repo jeong-sik/masc --pr <N> --head <SHA> --run <ID>
```

로그를 읽을 때 source review, 실행 결과, 병합, 배포, 실제 동작을 구분한다.
CI를 확인하는 동안 피처 개발을 멈추지 않는다. CI 자체 개선은 별도 스택에서 진행한다.
