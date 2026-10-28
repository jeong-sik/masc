---
name: masc-pr-patrol
description: "MASC 스택 PR의 현재 head를 읽고 기능·논리·코드 청결도를 리뷰한다. 일반 PR은 source review, Release/Tag는 명시적 Full CI 증거로 판단한다."
---

# MASC PR 순찰

먼저 `docs/constitution.xml` 전체를 읽는다. 실행 규약과 운영자의 지시가 이 문서보다 우선한다.
일반 PR에는 CI green이나 run ID를 요구하지 않는다. 자동 CI dispatch·watch·대기·반복 조회를 하지 않는다.

## 현재 변경 읽기

작업 선택은 `config/prompts/pr-review-routing.md`를 따른다. 닫힌 PR의 오래된 메시지에서 계속 머물지 않는다.
GitHub 사용자·팀의 기존 리뷰 요청을 보존하고, 요청·실행·리뷰·승인을 별개로 기록한다.
전체 미리뷰 PR 배분은 `python3 scripts/review/review-worklist.py --repo OWNER/REPO --reviewer LOGIN`으로 계획한다.
`--reviewer`를 반복해 독립 계정 풀을 지정하며, 누락된 요청 게시에는 `--request`를 명시한다.

```sh
gh api --paginate 'repos/jeong-sik/masc/pulls?state=open&per_page=100' \
  --jq '.[] | {number,title,headRefName:.head.ref,baseRefName:.base.ref,isDraft:.draft,stack}'
gh pr view <N> --repo jeong-sik/masc --json headRefOid,baseRefName,isDraft,reviews,comments
gh pr diff <N> --repo jeong-sik/masc
```

목록 명령은 모든 페이지의 PR 을 JSON 객체 스트림으로 출력한다. 조회가 실패하면 전체 목록을 확인한 것으로 판단하지 않는다.

현재 head와 base, 원래 작업 계약, 전체 diff를 직접 확인한다. 이전 리뷰·과거 녹색 CI·요약은 현재 변경의 증거가 아니다.
Draft는 작업 중이라는 뜻이다. CI가 없다는 이유로 일반 PR을 Draft로 되돌리거나 승인 대기시키지 않는다.

## 여러 관점에서 리뷰

기능과 사용자 흐름, 상태 전이·실패 처리 논리, 코드 청결도를 독립적으로 확인한다.
P0·P1·P2가 남으면 구체적인 위치·트리거·영향·수정 방향을 기록한다. 최종 판정을 맡은 리뷰어는 필요한 범위·계정 독립성·게시 권한을 확인한 뒤 자신의 판단에 따라 변경 요청이나 승인을 낸다. COMMENT 전담자는 자신의 렌즈 근거를 COMMENT로 남기며 승인이나 변경 요청을 대신하지 않는다.
P3는 모아서 후속 청소로 처리한다. 자기 변경은 자기가 승인하지 않는다.

일반 스택의 공식 최종 판정 첫 줄(COMMENT 전용 서명과는 별개):

```
verdict: PASS head: <40-hex SHA> by: <reviewer>
```

아래 승인 예제는 독립성과 게시 권한을 확인한 최종 판정자 전용이다. COMMENT 전담자는 이 승인 명령을 실행하지 않고 자신의 서명과 근거를 담은 COMMENT 리뷰를 게시한다.

최종 판정자는 리뷰 시작 전에 저장소 checkout 에서 인증된 `gh`, Git, Python 3, `jq` 로 head·base·전체 diff 식별자를 캡처한다.

```sh
# repo 와 pr 을 리뷰할 저장소와 PR 번호로 지정한다.
snapshot=$(gh api "repos/$repo/pulls/$pr")
head=$(printf '%s' "$snapshot" | jq -r '.head.sha')
review_base=$(printf '%s' "$snapshot" | jq -r '.base.sha')
review_diff=$(python3 scripts/review/review-diff.py \
  --repo "$repo" --base "$review_base" --head "$head")
# 전체 diff 와 소스 문맥을 읽고 review-body.md 에 판정과 증거를 기록한다.
bash scripts/review/approve-guard.sh --check --repo "$repo" --pr "$pr" --head "$head"
bash scripts/review/approve-guard.sh --repo "$repo" --pr "$pr" --head "$head" \
  --review-base "$review_base" --review-diff "$review_diff" --body review-body.md
```

게시에는 `--body`, `--review-base`, `--review-diff` 가 모두 필요하다. 변경 범위가 달라지면 다시 리뷰하고
증거를 캡처한다. 읽지 않은 변경을 승인하려고 diff 식별자만 갱신하지 않는다.
가드는 `review-scope:`와 `approve-guard:` 줄을 자동으로 붙인다. `--body`에 이 줄이나
`--print-footer` 출력을 넣지 않는다. 게시 뒤 결과가 불명확하면 리뷰를 조회한 뒤에만 후속 처리한다.

`approve-guard.sh`의 게시 경로는 본인의 독립성·검토한 head/base/diff·본문을 검사한다.
기존 CR이나 FAIL/HOLD는 새 판정 게시를 막지 않으며, 본인 CR은 `--replace-own-cr ID`로 명시한다(여러 ID는 옵션 반복).
병합·source receipt 경로는 계정별 미해결 FAIL/HOLD와 변경 요청을 검사한다. 다른 계정의 PASS 댓글로 해제하지 않는다.
Keeper `by` 이름은 표시 정보이며 같은 GitHub 로그인을 공유하면 독립된 정식 리뷰어로 세지 않는다.
일반 head에는 Actions API를 읽지 않는다. GitHub 계정 제한 때문에 자기 PR에 공식 APPROVE를 쓸 수 없으면
독립 리뷰의 결과와 제약을 명시하며 자기 승인을 만들지 않는다.

## 스택과 병합

먼저 `docs/guides/NATIVE-GITHUB-STACKS.md`를 읽고 REST PR의 `stack`과 Stacks API를 조회한다.
Native Stack은 맨 위 PR 하나로 스택 전체를 한 번에 병합한다. 개별 PR 리뷰와 스택 전체
병합 판정을 구분하고 포함된 모든 PR의 현재 head·독립 승인·FAIL/HOLD·변경 요청을 확인한다.
non-main base만으로 부모 선행 병합이나 수동 retarget을 요구하지 않는다. stack 없는 일반
브랜치 체인은 부모부터 처리한다. API 오류는 미확인이다. 구성·base·head 변경 뒤에는 다시 검토한다.

```sh
bash scripts/review/queue-ledger.sh --repo jeong-sik/masc --format tsv
bash scripts/review/merge-guard.sh --check --repo jeong-sik/masc --pr <N> --head <SHA>
```

외부 코딩 에이전트는 guard를 `--check`로 쓴다. **Native Stack은 맨 위 PR 하나로 스택 전체를 한 번에
병합한다. 아래부터 한 층씩 병합하지 않는다.** 스택 전체가 승인된 경우
`PUT repos/{owner}/{repo}/pulls/{맨 위 PR 번호}/merge-async`에 맨 위 PR의 head를 `sha`로 전달한다.
스택이 main과 충돌하면 `gh stack rebase`로 스택 전체를 다시 올려 한 번에 push하고, 아래층만 고쳐 push하지 않는다.
일반 PR은 `gh pr merge --match-head-commit <SHA>`를 쓴다. `--auto`·`--admin`을 쓰지 않는다.
병합 직전에 구성과 모든 head·리뷰를 다시 읽고 비동기 접수를 완료로 보고하지 않는다.

## Release/Tag 검증

`release/vX.Y.Z`에서 명시적으로 `release-candidate.yml` Full CI Cycle을 실행한다.
현재 head·branch의 최신 `release-candidate.yml` run이 완료·성공하고 필수 빌드·타입·기능·설치 검증도 성공해야 PASS할 수 있다. Release 판정에는 현재 head의 완료된 Full CI run을 기록한다. 완료된 run이 아직 없더라도 발견한 결함은 `verdict:` 줄 없이 head와 근거를 담은 변경 요청으로 남기고 run을 지어내지 않는다.
필수 작업이 실패·대기·skip·미등록이면 릴리스 성공 증거가 아니다. 일반 스택에 이 조건을 확대하지 않는다.

```
verdict: PASS head: <40-hex SHA> run: <full CI run ID> by: <reviewer>
```

```sh
bash scripts/review/merge-guard.sh --check --repo jeong-sik/masc --pr <N> --head <SHA> --run <ID>
```

로그를 읽을 때 source review, 실행 결과, 병합, 배포, 실제 동작을 구분한다.
CI를 확인하는 동안 피처 개발을 멈추지 않는다. CI 자체 개선은 별도 스택에서 진행한다.
