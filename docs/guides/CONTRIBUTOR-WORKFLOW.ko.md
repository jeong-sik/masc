# 저장소 전략과 기여 절차

[English](CONTRIBUTOR-WORKFLOW.md) · [기여 안내](../../CONTRIBUTING.md)

MASC의 변경을 문제 제기부터 검증된 결과까지 이어가는 절차입니다. 사람, 외부 AI
코딩 세션, 개발 작업을 하는 Keeper가 함께 사용할 수 있습니다. 저장소 개발 계약의
기준은 [헌법](../constitution.xml), 특히 `execution_protocol`입니다. 이 문서는 그
계약을 적용하는 방법을 설명하고, 실제 검사 동작은 workflow와 스크립트에서 확인합니다.

## 기본 저장소 전략

- `main`은 통합 브랜치입니다. 독립적인 변경은 최신 main에서 시작합니다.
- PR 하나에는 구체적인 결과 하나를 담습니다. 실제 의존성이 있는 변경은 stacked PR로,
  독립적인 변경은 main 기반의 별도 브랜치로 나눕니다.
- 동시 작업은 별도 worktree로 격리합니다. Task claim은 담당을 조율하며 파일을 잠그거나
  다른 체크아웃을 수정할 권한을 주지는 않습니다.
- README는 제품 소개, CONTRIBUTING은 개발 시작, 매뉴얼은 사용법, 명세는 인터페이스,
  RFC는 설계 제안을 담습니다. 사실 주장은 소스와 측정한 동작으로 뒷받침합니다.
- 지침은 기준이 되는 곳에 둡니다. `AGENTS.md`는 진입 안내, 헌법은 코딩 에이전트 규칙을
  맡습니다. 런타임 프롬프트는 별도 파일입니다.
- 변경 범위, 실제 효과, 증거와 남은 한계를 함께 제출합니다. 컴파일 성공, 설치된 바이너리,
  실제 동작 관측은 각각 다른 것을 증명합니다.

## 1. 처음 기여하기

[CONTRIBUTING](../../CONTRIBUTING.md)에서 시작합니다. 문서 수정에는 OCaml 개발 환경이
필요하지 않습니다. 사실을 설명하는 문장을 바꾸기 전에 관련 소스와 매뉴얼을 읽으세요.
코드를 변경한다면 [README 소스 설치](../../README.md#from-source)의 준비물을 확인합니다.

기존 이슈를 고르거나 문제, 기대 결과, 확인 방법을 적습니다. 같은 작업이 진행 중인지
이슈와 열린 PR부터 검색하세요. 쓰기 권한이 없는 기여자는 GitHub fork를 사용합니다.
내 fork는 `origin`, `jeong-sik/masc`는 `upstream`으로 연결하고 upstream main을 기준으로
시작합니다. 쓰기 권한이 있으면 origin main을 사용합니다. PR 대상은 `jeong-sik/masc:main`입니다.

```bash
git fetch origin main
git worktree add -b docs/your-topic ../masc-your-topic origin/main
cd ../masc-your-topic
```

Fork에서는 위 두 명령의 `origin`을 `upstream`으로 바꿉니다. 아직 사용하지 않은 경로를
고르세요. 실행 테스트는 별도 base path와 빈 포트를 사용합니다. 소스 체크아웃과 `.masc`가
들어 있는 작업 공간은 다릅니다.

## 2. AI 개발 세션 시작하기

계획하거나 수정하기 전에 [AGENTS.md](../../AGENTS.md)와 [헌법](../constitution.xml)
전체를 읽습니다. 그다음 다음 순서로 진행합니다.

1. 체크아웃, 브랜치, 기존 변경, 최신 main을 확인합니다. 사용 중인 공유 체크아웃에는
   별도 worktree를 사용하고 기존 작업을 보존합니다.
2. 요청한 결과, 범위와 증거 조건을 적습니다. 실제 소스, 현재 리뷰와 실패 로그를 읽습니다.
3. 범위를 정한 변경을 구현합니다. 외부 코딩 세션은 로컬 Dune 빌드를 하지 않고 마무리
   경계에서 CI를 요청합니다. 확인할 바이너리가 필요하면
   [linux-x64-probe](../../.github/workflows/linux-x64-probe.yml)를 사용합니다. Release dispatch는 태그·RC 작업에 씁니다.
4. 다음 작업 단위로 넘어갈 때 이전 작업에 적대적 리뷰 에이전트를 붙입니다. 발견한 내용을
   직접 판단하고 대응합니다. 서브에이전트 리뷰가 곧 다른 모델의 리뷰나 GitHub 승인은 아닙니다.
5. 인계할 때는 다음 행동과 그 근거를 남깁니다.

Keeper 레인은 도구 체인이 있으면 로컬에서 빌드·테스트할 수 있습니다. 해당 결과가 현재
PR head의 검사나 `test.yml` targeted run을 대신하지는 않습니다. 세션 권한, MCP 인증의
에이전트 이름, Keeper 이름은 별개입니다. 공용 Task 소유자 이름으로 다른 세션의 작업을 해제하지 마세요.

## 3. 작업 조율하기

GitHub Issue·PR은 공개 변경을 추적합니다. MASC는 공유 목표와 실행 기록을 더합니다.

| 기록 | 용도 |
|---|---|
| Issue | 문제, 기대 결과, 재현 증거와 논의 |
| Goal | 측정 지표, 읽을 수 있는 측정 출처와 목표값을 가진 공동 목표 |
| Task | 범위가 정해진 구현·리뷰 작업, 담당과 완료 조건 |
| Board | 팀이 볼 결정, 질문, 의존성과 진행 상황 |
| PR | 실제 diff, 검증, 리뷰와 main 통합 |

외부 기여자에게 MASC 참여는 선택 사항입니다. 공개 이슈와 PR은 운영자의 비공개 작업
공간에 접근하지 않아도 이해할 수 있어야 합니다. Goal에 속하는 작업은 Goal을 먼저
만들고 Task 생성 시 `goal_id`로 연결합니다. 독립 Task도 정상이며 나중에 Goal에 연결할 수 있습니다. 시작 전에 claim하고 다른 사람이 맡았다면 논의하거나 다른 작업을
고릅니다. 실패하거나 인계할 때는 요약, 증거와 다음 행동을 적어 release합니다.

현재 세션이 제공하는 `masc_goal_upsert`, `masc_add_task`, `masc_transition`,
`masc_board_post` 스키마를 사용하세요. 이 문서는 변하는 도구 payload를 다시 정의하지
않습니다. 공개·비공개 진행 글에 관련 ID를 남기세요. Board 계획은 증거가 있을 때까지 계획입니다.

## 4. 검증하고 CI 요청하기

변경한 동작과 위험에 맞는 검사를 고릅니다. 문서는 OCaml 빌드 없이
`bash scripts/check-doc-truth.sh`, `git diff --check`와 새 링크·앵커 검사를 실행할 수
있습니다. 사람은 로컬 focused 검사를 사용할 수 있고 외부 코딩 세션은 2절을 따릅니다.

[scripts/pr-open.sh](../../scripts/pr-open.sh) 또는 GitHub fork PR 흐름으로 초안을 엽니다.
[PR 템플릿](../../.github/pull_request_template.md)을 채우고 이슈를 연결합니다.
초안 PR은 필수 PR-check job을 건너뜁니다. diff와 증거가 준비되면 ready for review로
바꾸어 검사를 시작합니다.

[pr-check.yml](../../.github/workflows/pr-check.yml)의 필수 검사는 다음과 같습니다.

- dashboard typecheck;
- `dune build @check`와 선택된 테스트;
- `dune build --profile release @check`;
- lint suite;
- TLA model check.

`PR required success`는 종합 결과입니다. 선택된 테스트가 전체 동작 테스트는 아니므로
실제로 무엇을 실행했는지 로그에서 확인하세요. [test.yml](../../.github/workflows/test.yml)은
정기·전체 실행과 `suite` 입력을 받는 targeted dispatch를 제공합니다.

```bash
gh workflow run test.yml --repo jeong-sik/masc --ref your-branch \
  -f suite=test_keeper_meta_json_config_toml_only
```

Dispatch에는 저장소 권한이 필요합니다. Fork 기여자는 maintainer에게 필요한 실행을
요청할 수 있습니다. 외부 에이전트는 CI를 watch하거나 기다리며 반복 조회하지 않습니다.
다음 맥락의 작업을 진행하고 경계에서 결과를 확인합니다. 실패하면 원문에서 내 diff,
base, 시간 초과, 환경 준비 중 무엇이 원인인지 가려 같은 PR에 무관한 수정을 섞지 않습니다.

## 5. 리뷰하고 통합하기

리뷰어는 계약과 diff, 동작 증거, 현재 head의 완료된 PR-check run을 읽습니다. 지적마다
수정하거나 소스로 설명하고, 문제가 해결된 스레드만 닫습니다. Push하면 head가 바뀌므로
이전 PASS가 새 변경을 증명하지 않습니다. REQUEST_CHANGES를 남긴 리뷰어는 수정된
head의 필수 검사가 통과하면 자신의 변경 요청을 직접 해제합니다.

MASC의 구조화된 판정 줄은 실제 값을 적습니다.

```text
verdict: PASS|FAIL head: <40-character-current-SHA> run: <PR-check-run-id> by: <Keeper-name>
```

위는 형식이며 판정이 아닙니다. Placeholder를 PASS로 게시하지 마세요.
APPROVE에는 [approve-guard.sh](../../scripts/review/approve-guard.sh)를 사용합니다.
작성하거나 push한 세션은 그 PR을 독립 승인할 수 없습니다. 최신 main이 PR 파일이나 공용
검사 입력을 바꿨으면 main을 반영하고 새 run을 받습니다. 병합 전에 현재 리뷰와 이슈 댓글을
다시 읽고 이전 PASS 뒤의 판단까지 확인합니다.

병합은 Keeper가 담당합니다. 헌법은 운영자가 띄운 외부 세션 중 `jeong-sik` 계정을 사용하는
경우에만 제한된 예외를 둡니다. 현재 head의 필수 검사 5개가 모두 완료·성공하고, 같은 head와
run을 지정한 [merge-guard](../../scripts/review/merge-guard.sh)의 읽기 전용 검사가
`WOULD MERGE`를 내야 합니다. 그때만 `gh pr merge --match-head-commit`을 사용할 수 있습니다.
외부 코딩 세션은 `--auto`, `--admin`, guard의 병합 모드를 사용하지 않습니다.
Fork 기여자는 maintainer에게 통합을 맡기며 같은 증거 기준이 적용됩니다.

정리 전에 병합된 커밋과 PR 상태를 확인합니다. 제출하지 않은 작업이 없는지 확인한 뒤
끝난 worktree와 브랜치만 정리합니다. 병합된 PR 브랜치에는 다시 push하지 않고 새 PR을 엽니다.

## 6. 증거 제출과 재개

MASC Task는 요약과 증거를 담아 `submit_for_verification`으로 제출합니다. `done`은
스스로 완료하는 방법이 아닙니다. 현재 도구 스키마와
[증거 캡처 계약](../../lib/workspace/workspace_verification_store.mli)을 따르세요.
문장에 적은 경로·커밋·PR이 곧 파일 snapshot은 아닙니다. 변하는 테스트 출력은 크기가
정해진 artifact로 저장하고, 검증자가 읽어야 하는 공개 URL이나 고정된 Board/Fusion 참조를 제공합니다.

Goal의 측정 출처는 완료 판정자가 읽을 수 있어야 하며 목표값은 측정값과 비교할 수 있어야
합니다. 끝난 Task나 완료를 알리는 글만으로 Goal을 증명하지 않습니다. 증거와 함께 완료를
요청하고 검증과 사람의 최종 확인을 별도 단계로 둡니다.

인계에는 Goal·Task·Issue·PR ID, 브랜치와 worktree, 현재 SHA, 실행한 검사, 미해결 리뷰,
막힌 조건과 다음 행동을 적습니다. 재개하면 변경을 반복하기 전에 현재 상태부터 읽으세요.
중단된 명령이 이미 적용됐을 수 있습니다. 저장된 기록에서 이어가고 런타임 소유 파일을 직접 바꾸지 않습니다.

## 절차 문서 유지하기

Workflow, 스크립트, 도구 계약이나 실행 경계가 바뀌면 관련 절차도 같은 변경에서 고칩니다.
명령 예시는 실행 가능하게 쓰고 준비물을 표시합니다. 번역 문서도 함께 검토하세요.
정책 충돌은 헌법, 구현 주장은 소스를 기준으로 판단합니다. 빠진 구현은 빠졌다고 기록합니다.
