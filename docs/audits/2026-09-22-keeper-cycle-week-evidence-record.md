# Keeper 순환 변경 감사 — 2026-09-22

확인 기준은 `main a90400b25f`와 2026-09-22 KST 운영 관측이다. 소스, CI,
병합, 배포, 실제 요청, 작업 결과를 따로 판정한다. 전체 완료율은 산정하지 않았다.

## 공통 헤더

- 날짜(ISO8601): 2026-09-22T01:41:55+09:00
- 작성자: Codex
- 결정 ID: keeper-cycle-week-20260922
- 적용 대상: MASC main a90400b25f 및 보존된 운영 기록
- 결정 상태: 추적 필요

## 기간과 증거 범위

요청된 `2026-09-12~19`는 양 끝 날짜를 포함하면 8개 달력 날짜다. 이 문서는
KST `09-12 00:00` 이상 `09-20 00:00` 미만을 사용한다. 로그 파일 이름은 UTC
날짜이므로 각 행의 `ts`를 KST로 변환했다.

`main`의 first-parent에서 `lib/keeper`, `lib/skill`, `lib/skill_reference`,
`lib/runtime`, `lib/tui`, `config/prompts/librarian.md` 경로를 대상으로 모은 변경은
317건이다. 이는 탐색 목록이며 전체 저장소의 변경 수나 317건의 상세 리뷰 완료를
뜻하지 않는다. `bin/masc_tui*` 등의 추가 경로는 발견한 문제에 따라 별도로 읽었다.

```sh
git log main --first-parent \
  --since='2026-09-12T00:00:00+09:00' --until='2026-09-20T00:00:00+09:00' \
  --format='%H %cI %s' -- lib/keeper lib/skill lib/skill_reference lib/runtime lib/tui config/prompts/librarian.md
git show <commit> -- <changed-path>
```

현재 남은 system log의 범위는 [집계 파일](../evidence/keeper-cycle-week-20260922/retained-log-coverage.json)에
기록했다. 원문·사용자 발화·도구 인자는 포함하지 않았다. 파일 SHA는 읽은 증거의
식별자이며, 그날 실행된 바이너리의 SHA가 아니다.

| KST 날짜 | 확인한 주요 소스 변화 | 남은 system log |
|---|---|---|
| 09-12 | package Skills 카탈로그 #35482; TUI chat 모듈 분리 #35334; 없는 Schedule owner 거절 #35361 | 해당 날짜 행 없음 |
| 09-13 | workspace Memory curator #35688와 Keeper recall #35693; composition 읽기 실패 후 재개 #35703 | 해당 날짜 행 없음 |
| 09-14 | 입력 대기열을 working context로 구성 #36142; Schedule 소비에 맞춘 다음 발생 #36249 | 09:00:01부터, 78,842행 |
| 09-15 | Memory write가 턴을 계속하도록 #36479; 저장 실패의 효과 설명 #36510/#36521/#36532; journal 읽기 분리 #36686/#36697 | 134,534행 |
| 09-16 | Memory commit 직렬화/파싱을 pool에서 실행 #36780; Librarian 출력 계약 RFC #36829; Schedule 종료 후 보존 정책 #36779/#36832 | 136,403행 |
| 09-17 | 반복 주제 Memory 합성 안내 #36855; 사용 불가능한 노드의 composition 제외 #36930; 새 workspace Librarian lane #36885/#36899 | 137,547행 |
| 09-18 | 흡수된 기억 원문 보존 #36937 및 검색 #36948 | 103,668행 |
| 09-19 | Librarian atom 범위 #37031 및 progress #37028; API 거절 후 CLI 후보 #37070; 같은 Schedule 발생 재시도 #37100 | 135,062행 |

행 수는 로그 보존량이다. 가동 시간이나 성공한 작업 수가 아니다. 과거 `completion
repair remains pending`가 같은 task/verification에 반복된 사례도 있으므로 ERROR
행 수를 서로 다른 결함 수로 사용하지 않는다. 12~13일의 system log 부재는 다른
저장소에도 증거가 없다는 뜻이 아니다. 날짜별 배포 commit은 이 집계로 확정하지 못했다.

## 현재 수정과 검증

| 문제 | 수정/추적 | 확인한 증거 | 남은 증거 |
|---|---|---|---|
| Memory 저장 직후 취소하면 Context 재개가 같은 기억을 다시 적용할 위험 | #37628 | 실제 저장·취소·재개 통합 테스트와 CI 통과 | 새 배포에서 중단/재시작 관측 |
| 배포 검사에서 journal/lock 파일을 저장소 디렉터리로 오인 | #37629 | 동일 fixture 기존 exit124, 수정 후 실제 CLI 테스트 3건 통과 | 실제 old-schema 오류는 별도 #37622 |
| JEV 판정 실패에도 미확인 흡수를 적용 | #37630 | 미확인 원본 보존, 완전히 승인된 묶음만 적용하는 테스트와 CI 통과 | 새 배포에서 실패 시 Memory 보존; 미설정 JEV의 Skipped 정책은 별개 |
| msx 입력 거절 후 다음 후보를 시도하지 않고 종료 | #37631 | 실제 400 형태를 이용한 후보 순회·효과 경계 회귀, CI 통과 | 재배포 후 실제 provider 전환 |
| Small에서 실패 호출의 긴 인자/오류를 fresh Context에 다시 삽입 | #37632 | 실제 원문 조회 복원 및 Keeper hook→Codex 요청 연결 테스트, CI 통과 | 배포 후 전송 bytes·내용 연속성 |
| 분석기가 현재 로그의 lifecycle_event에서 전체 중단 | #37634 | 같은 18,107행에서 exit2→exit0; 21개 Python 테스트·Pyright·Ruff·PR CI 통과 | main 반영 |
| TUI GitHub 카드가 본문보다 넓어 테두리와 배너가 줄바꿈 | #37635 | 실제 body 폭 사용; cache/frame 일관성 회귀 추가; 독립 리뷰 | native CI와 새 TUI의 실제 표시 |
| Memory에서 재사용 Skill을 생성·검증·발행하는 전체 연결 | #37633 | parser·관리자 editor·catalog는 존재; 자동 생산 경로는 미구현 확인 | 후보 증거→실행 검증→승인/발행→후속 사용 |

이 표 작성 시 #37628~#37632는 CI 통과 후 자동 병합을 등록했지만 GitHub 필수
리뷰 대기 상태였다. 병합과 배포를 완료한 것으로 읽지 않는다. 이후 상태는 해당
PR에서 다시 확인한다. #37630은 다른 작업의 JEV destinations #37620/#37623과
파일이 겹치므로 통합 시 두 동작을 모두 보존해야 한다.

## 운영에서 확인한 범위

- 관측 바이너리: `/health?full=1`의 embedded commit `a90400b25f`, 시작 시각
  `2026-09-21T15:34:56Z`. 위 신규 PR의 배포 효과가 아니다.
- msx의 검증된 요약 지점은 `9006 → 9465 → 9725`로 전진했다. 서로 다른 후속
  준비 요청은 약 `4.25MB → 3.90MB → 2.80MB`였다. 각 요청이 같은 atom 집합은
  아니므로 압축률 비교로 사용하지 않는다. 준비 기록은 provider 수락이나 과제
  성공의 증거가 아니다. 낮은 Context에서 크기가 안정되는 반복 순환은 미입증이다.
- 09-21 UTC tool log의 고정 표본은 18,107행이다. 해당 고정 표본의 write→retract 인접
  쌍은 180건이지만, 위 재시작 후 표본에는 명시적 write 8건과 retract 0건이 있었다.
  이를 과거 반복의 지속이나 영구 해결로 확대하지 않는다.
- Schedule #36249→#37100은 같은 발생을 재시도하고 다른 미소비 발생만 보류한다.
  `test_schedule_consumer_dispatch`의 enqueue/activation 실패, acceptance 실패,
  완료·취소 후 재처리와 `test_schedule_store`의 재시작 복구가 그 계약을 다룬다.
  이번 검토는 소스 검토이며 이 테스트들을 새로 실행한 것은 아니다. `deferred`는
  Keeper 작업 실패나 새 실행을 뜻하지 않는다.

## 전체 완료 판정에 아직 필요한 것

Board/Task/Goal/HITL/Access Control/Multi Lane/Schedule은 이 문서의 좁은
Context 수정 테스트만으로 완료 판정하지 않는다. 각 도메인의 실제 전이, 권한 거절,
취소·재시작, TUI/API 표시를 연결한 증거가 필요하다. 특히 다음을 분리해 남긴다.

1. 배포된 정확한 바이너리에서 Context→Memory→다음 요청이 여러 번 이어지는 관측.
2. 429·입력 거절·중단 뒤 원문과 외부 효과를 보존하며 진전하는 실제 실행.
3. 반복 해결법의 Skill 생산과 후속 사용. #37304의 sequence miner는 이미 있으므로
   재사용하되 빈도 자체를 유용성/성공 판정으로 삼지 않는다.
4. 사용자 화면의 실제 표시와 작업 결과. 소스나 문자열 테스트만으로 화면 검증을
   대신하지 않는다.
5. 벤치마크별 공식 요구, 실행 환경, exact source/config, 결과 artifact. 현재
   acceptance catalog 구조 검사는 23 missions/49 assertions를 확인했을 뿐이다.
   전체 mission 실행이나 Terminal-Bench 통과가 아니며 GPU 실행은 별도 단계다.

## 근거

- 항목: 소스·검사·운영 관측을 구분한 변경 감사
- 제한조건: 보존되지 않은 로그와 신규 배포 결과는 추정하지 않음
- 출처: 위 commit/PR, `gh pr checks`, 실제 CI 테스트 로그, `/health?full=1`,
  Keeper Memory health API, 고정 tool log 표본, retained system log 집계.
- 확인일시: 2026-09-22 KST. PR·배포 상태는 이후 변경될 수 있다.
- 신뢰도: High(명시한 소스·검사·표본), 미확인 항목은 완료로 판정하지 않음.

## 검증

- 1차: 날짜별 git 이력과 관련 producer/store/consumer 코드를 대조했다.
- 2차: PR CI와 실행 중인 바이너리의 embedded commit을 각각 확인했다.
- 3차: 취소 복구·후보 전환·실제 요청 연결 테스트와 고정 로그 분석 재현을 확인했다.
- 재현 결과: 수정별 확인 범위는 위 표에 명시했다. 전체 순환은 미완료다.

## 불확실성

- 미확인 항목: 날짜별 배포 신원, 신규 수정의 운영 효과, 전체 도메인 장기 실행.
- 영향: 소스 또는 좁은 테스트 결과를 제품 완성으로 오인할 수 있다.
- 추가 확인 필요: 병합·배포 후 같은 경로를 재측정하고 각 도메인 증거를 보완한다.

## 적용범위

- 영향 받는 영역: Keeper Context, Librarian, Memory, Skills, Schedule, TUI 관측.
- 제약/배제: 실제 원문 로그·비밀 정보는 게시하지 않으며 벤치마크 통과를 주장하지 않는다.
- 롤백 조건: 기록과 실제 증거가 다르면 해당 결론을 철회하고 원자료로 다시 검증한다.
