---
name: masc-pr-patrol
description: "MASC 스택 PR의 현재 head를 읽고 기능·논리·코드 청결도를 리뷰한다. 일반 PR은 source review, Release/Tag는 명시적 Full CI 증거로 판단한다."
---

# MASC PR 순찰

먼저 `docs/constitution.xml` 전체를 읽는다. 실행 규약과 운영자의 지시가 이 문서보다 우선한다.
일반 PR에는 CI green이나 run ID를 요구하지 않는다. 자동 CI dispatch·watch·대기·반복 조회를 하지 않는다.

## 현재 변경 읽기

직접 요청과 맡은 Task의 PR을 먼저 보고, 그다음 인증된 계정이 `requested_reviewers`에 있는 열린 Ready PR,
그다음 나머지 열린 PR을 오래된 순으로 본다. 병합되거나 닫힌 PR은 끝난 것으로 두고 다음 PR로 간다.
GitHub 사용자·팀의 기존 리뷰 요청을 보존하고, 요청·실행·리뷰·승인을 별개로 기록한다.
전체 미리뷰 PR 배분은 `python3 scripts/review/review-worklist.py --repo OWNER/REPO --reviewer LOGIN`으로 계획한다.
`--reviewer`를 반복해 독립 계정 풀을 지정하며, 누락된 요청 게시에는 `--request`를 명시한다.
출력의 `current_head_submissions`는 같은 head에 실제 제출된 리뷰다. COMMENTED도 보존하므로
APPROVE가 없다는 이유만으로 미착수라 적지 않는다. 제출 기록만으로 전체 소스 검토 완료를
판정하지 말고 본문과 읽은 범위를 확인한다. 승인·변경 요청은 기존 정식 판정으로 따로 읽는다.

```sh
gh api --paginate 'repos/jeong-sik/masc/pulls?state=open&per_page=100' \
  --jq '.[] | {number,title,headRefName:.head.ref,baseRefName:.base.ref,isDraft:.draft,stack}'
gh pr view <N> --repo jeong-sik/masc --json headRefOid,baseRefName,isDraft,reviews,comments
gh pr diff <N> --repo jeong-sik/masc
```

목록 명령은 모든 페이지의 PR 을 JSON 객체 스트림으로 출력한다. 조회가 실패하면 전체 목록을 확인한 것으로 판단하지 않는다.

현재 head와 base, 원래 작업 계약, 전체 diff를 직접 확인한다. 이전 리뷰·과거 녹색 CI·요약은 현재 변경의 증거가 아니다.
수정이 필요하다고 적기 전에 그 주장을 반박하는 경로도 같은 head에서 읽는다. fallback이
없다는 지적은 해당 분기의 호출과 후속 처리를, alias·open·include 지적은 실제 대상 구현과
인터페이스를 확인한다. 검색 결과나 이름만으로 대상의 내용을 대신하지 않는다.
확인하지 않은 외부 구현·동시 실행 전제가 필요한 우려는 조건부 관찰로 남기고 확정 결함으로 쓰지 않는다.
부분 복제 저장소에서 옛 head에 넓은 `git grep`을 돌리면 빠진 blob을 하나씩 내려받느라 오래 걸린다.
경로를 먼저 좁히고, 나머지는 그 head의 GitHub 원문으로 읽는다. 검색 실패나 시간 초과는 일치 항목이 없다는 뜻이 아니다.
읽기가 거절되거나 출력이 잘렸으면 그 범위는 미확인이다. 실제로 받은 원문으로 범위를 보완한
뒤 판정하고, 명령을 보냈다는 사실을 전체 파일 판독으로 쓰지 않는다. 실행·조회 여부는 실제
호출과 반환에 맞춰 적는다. PR 조회에 `statusCheckRollup`을 넣었으면 체크를 조회한 것이다.
Draft는 작업 중이라는 뜻이다. CI가 없다는 이유로 일반 PR을 Draft로 되돌리거나 승인 대기시키지 않는다.

## 여러 관점에서 리뷰

기능과 사용자 흐름, 상태 전이·실패 처리 논리, 코드 청결도를 독립적으로 확인한다.
P0·P1·P2가 남으면 구체적인 위치·트리거·영향·수정 방향을 기록한다. 리뷰 내용과 수정 사항이 맞으면 GitHub에 바로 승인한다.
P3는 모아서 후속 청소로 처리한다. 자기 변경은 자기가 승인하지 않는다.

리뷰어는 현재 head·base와 전체 diff를 확인한 뒤 아래처럼 승인할 수 있다.

```sh
# repo 와 pr 을 리뷰할 저장소와 PR 번호로 지정한다.
snapshot=$(gh api "repos/$repo/pulls/$pr")
head=$(printf '%s' "$snapshot" | jq -r '.head.sha')
gh pr diff "$pr" --repo "$repo"
# 전체 diff 와 소스 문맥을 읽고 검토한 head 를 지정한다.
gh api --method POST "repos/$repo/pulls/$pr/reviews" \
  -f event=APPROVE -f commit_id="$head"
```

변경 범위가 달라지면 다시 리뷰한다. 소스 검토가 끝나면
CI를 기다리지 않고 승인한다. 게시 뒤 리뷰 ID·상태·commit_id를
재조회하고 결과가 불명확하면 기존 효과를 확인한 뒤에만 후속 처리한다.

커밋 author·committer 계정은 여러 Keeper 세션이 공유할 수 있다. GitHub 리뷰의 계정·commit_id는
실제 작성·push 세션과 리뷰 세션의 독립성, 검토한 base·전체 diff를 증명하지 않는다.
같은 계정의 이후 정식 승인은 그 계정의 이전 변경 요청을 대체하며 다른 계정의 요청은 남는다.
같은 GitHub 계정의 Keeper는 별도 공식 계정으로 세지 않는다. 원래 지적이 실제 해결됐는지도 확인한다.
일반 head에는 Actions API를 읽지 않는다. GitHub 계정 제한 때문에 자기 PR에 공식 APPROVE를 쓸 수 없으면
독립 리뷰의 결과와 제약을 명시하며 자기 승인을 만들지 않는다.

## 스택과 병합

먼저 `docs/guides/NATIVE-GITHUB-STACKS.md`를 읽고 REST PR의 `stack`과 Stacks API를 조회한다.
Native Stack은 맨 위 PR 하나로 스택 전체를 한 번에 병합한다. 개별 PR 리뷰와 스택 전체
병합 판정을 구분하고 포함된 모든 PR의 현재 head·독립 승인·FAIL/HOLD·변경 요청을 확인한다.
non-main base만으로 부모 선행 병합이나 수동 retarget을 요구하지 않는다. stack 없는 일반
브랜치 체인은 부모부터 처리한다. API 오류는 미확인이다. 구성·base·head 변경 뒤에는 다시 검토한다.

```sh
gh api repos/OWNER/REPO/pulls/TOP_PR_NUMBER
gh api repos/OWNER/REPO/stacks/STACK_NUMBER
```

**Native Stack은 맨 위 PR 하나로 스택 전체를 한 번에
병합한다. 아래부터 한 층씩 병합하지 않는다.** 스택 전체가 승인된 경우
`PUT repos/{owner}/{repo}/pulls/{맨 위 PR 번호}/merge-async`에 맨 위 PR의 head를 `sha`로 전달한다.
스택이 main과 충돌하면 `gh stack rebase`로 스택 전체를 다시 올려 한 번에 push하고, 아래층만 고쳐 push하지 않는다.
일반 PR은 `gh pr merge --match-head-commit <SHA>`를 쓴다. `--auto`·`--admin`을 쓰지 않는다.
병합 직전에 구성과 모든 head·리뷰를 다시 읽고 비동기 접수를 완료로 보고하지 않는다.

## Release/Tag 검증

`release/vX.Y.Z`에서 명시적으로 `release-candidate.yml` Full CI Cycle을 실행한다.
소스 리뷰 승인은 CI가 끝나기 전에 낼 수 있다. Release 병합·게시 판정에는 현재 head·branch의 최신 `release-candidate.yml` run이 완료·성공하고 필수 빌드·타입·기능·설치 검증도 성공해야 한다. 완료된 Full CI run은 별도로 기록한다. 발견한 결함은 head와 근거를 담아 남기고 run을 지어내지 않는다.
필수 작업이 실패·대기·skip·미등록이면 릴리스 성공 증거가 아니다. 일반 스택에 이 조건을 확대하지 않는다.

로그를 읽을 때 source review, 실행 결과, 병합, 배포, 실제 동작을 구분한다.
CI를 확인하는 동안 피처 개발을 멈추지 않는다. CI 자체 개선은 별도 스택에서 진행한다.
