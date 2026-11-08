# 최근 7일 코드 점검과 OCaml 5.5.2 적용 · 2026-11-09

## 조사 범위와 판단

집계 창은 **2026-11-02 08:17부터 2026-11-09 08:17까지, 한국 시각**이다.
`origin/main`의 `419f2a843ed7`을 고정해 committer 시각으로 집계했다.
이 창에 들어오는 non-merge 커밋은 2,087개였다. PR 수나 새 기능 수와는 다르다.
변경 이력을 훑은 뒤 Keeper 도구 실행·원격 작업 폴더 정리·HTTP/2 진입 경로·공용 실행 풀·컴파일러 설정을 골라 소스와 호출자를 읽었다.
2,087개 diff 전부를 정밀 검토한 결과나 저장소 전체의 정상 판정은 아니다.
중복 수리를 피하려고 구현 전 공개된 open PR 81개와 REST Native Stack 목록도 읽었다.

## 일주일 동안 바뀐 흐름

| 흐름 | 이력에서 확인한 변화 | 코드 점검의 초점 |
| --- | --- | --- |
| Keeper 실행과 복구 | 도구 실행 계획, Librarian/Memory 입력, 원격 SSH 작업과 정리 주기를 확장했다. `refactor(keeper)` 171개, `fix(keeper)` 88개였다. | 이미 시작한 효과의 정리와 아직 대기하는 효과의 취소를 구분하는가. 원격 정리가 커밋의 유일한 사본을 보존하는가. |
| UI와 관측 | `fix(tui)` 165개, `feat(tui)` 71개. 파일 보기·키 안내·관측 갱신이 많이 바뀌었다. | 이번에는 UI 전체 검증을 주장하지 않는다. 변경량과 빈도가 높은 영역으로 식별했다. |
| 서버 전송과 인증 | HTTP/2가 HTTP/1.1과 공용 경로 표를 사용하고 TLS·흐름 제어가 확장됐다. 다계정 인증 레코드도 계속 추가됐다. | 새 전송 진입점과 기존 권한·정리 경계의 연결을 읽었다. 해당 범위에서 별도의 확정 결함은 확보하지 못했다. |
| 미사용 코드 정리 | 별칭·미사용 타입·환경 변수·테스트 의존성·실행되지 않는 CI 스크립트 제거가 이어졌다. | 이미 열린 정리 PR과 겹치는 삭제를 추가하지 않았다. 이번 수리는 동작 실패를 재현할 수 있는 경계를 우선했다. |

위 숫자는 커밋 제목의 정확한 접두어를 센 값이며 서로 다른 기능 규모를 비교하는 지표는 아니다.
재집계 명령:

```sh
git log 419f2a843ed7 --no-merges \
  --since=2026-11-02T08:17:00+09:00 --until=2026-11-09T08:17:00+09:00 \
  --format='%H%x09%cI%x09%s'
```

## 재현한 결함과 수정

### 원격 정리가 bare 저장소를 삭제함

[원격 정리 payload](../../config/scripts/keeper-remote-workspace-cleanup.py)의 `tree_facts`는
`.git` 자식이 있는 작업 폴더만 저장소로 셌다. bare 저장소와 별도 Git 관리 디렉터리는
검사 목록에서 빠졌다. 그 결과 remote에 없는 커밋이나 바깥 worktree를 소유해도
자동 정리의 `--apply` 경로에서 삭제됐다.

도입은 [#49999](https://github.com/jeong-sik/masc/pull/49999), 자동 주기 연결은
[#50013](https://github.com/jeong-sik/masc/pull/50013)이다.
수리는 bare/별도 관리 디렉터리를 찾아 보존한다. 일반 clone의 `.git`은 기존 소유 작업 폴더를 통해 검사한다.
디렉터리마다 Git 프로세스를 실행하지 않고, 발견한 저장소 후보에만 확인을 추가한다.
공간 회수량보다 소유권과 커밋 보존을 우선하므로 이런 관리 디렉터리는 모든 커밋을 push했더라도 남긴다.

추가한 두 회귀 시나리오는 기존 코드에서 실제 삭제로 실패했고 수정 뒤 통과했다.
루트·중첩 bare 저장소의 local-only commit과 바깥 worktree의 별도 Git 디렉터리를 검사한다.
[기존 Python 동작 시험](../../test/test_keeper_remote_workspace_cleanup.py)은 **14/14 통과**했고,
독립 리뷰 세션도 같은 14개를 실행했다. 실제 원격 endpoint에서 정리를 실행한 결과는 아니다.

### 도구 실행기의 대기 중 취소

[Keeper 도구 계획 실행기](../../lib/keeper/keeper_tool_plan_executor.ml)의 `Exclusive_gate`는
`Eio.Mutex.use_rw ~protect:true` 안에서 condition을 기다렸다.
Eio의 `Cancel.protect`는 반환 시 부모 취소를 다시 검사하지 않는다.
활성 도구가 보호된 정리를 마치고 돌아오면, 이미 취소된 Serial 대기자가 뒤늦게 실행될 수 있었다.

정확한 gate 모듈과 획득·반환 wrapper를 추출해 설치된 OCaml 5.5.1/Eio로 실행한 결과:

| 후보 | 취소 뒤 대기 도구 dispatch 수 | 취소 예외 전파 |
| --- | ---: | --- |
| 기존 코드 | 1 | false |
| 수정 코드 | 0 | true |

수리는 `Fiber.all`의 같은 도메인 안에서만 쓰는 gate의 상태 변경이 yield하지 않는 점을 이용한다.
`Condition.await_no_mutex`로 취소 가능한 대기를 하고, 획득 전후 취소를 확인하며,
실제로 획득한 뒤에만 release를 등록한다. writer 대기가 취소되면 대기 수를 되돌리고 reader를 깨운다.
불필요한 mutex와 취소 보호를 함께 제거한다.
실제 executor를 통하는 회귀 시험도 추가하지만, 이 조사에서 실행한 전후 비교는 추출된 gate 범위다.
전체 executor 테스트·Keeper 세션 동작의 통과로 해석하지 않는다.

## OCaml 5.5 활용 판단

**검토 표본에서는 5.x의 병렬 실행 기반과 5.5 표준 라이브러리를 이미 사용한다.**
버전만 올리고 모든 곳에서 예전 방식만 쓰는 상태는 아니다.

- [실행 풀 참조](../../lib/core/domain_pool_ref.ml)는 도메인 간 참조에 `Atomic.t`를 쓰고,
  실행 문맥과 worker 진입 여부를 판정해 중복 재실행을 피한다.
- [공용 실행 제출](../../lib/core/executor_pool_submission.ml)은 worker 취소와 정리를 구분한다.
  효과를 실행한 worker의 실패를 caller에서 다시 실행하는 방식으로 숨기지 않는다.
- [Librarian 입력](../../lib/keeper/keeper_librarian_input_sources.ml)은 5.5의 `Lazy.Mutexed`로
  순수한 overlap-key 계산을 공유한다. thunk 안에 fiber를 넘기는 I/O를 넣지 않는 용도다.
- [소유 작업 inventory](../../lib/keeper/keeper_owned_job_backend.ml)는 I/O를 하는 공유 초기화에
  ``Eio.Lazy.from_fun ~cancel:`Restart``를 사용한다. `Lazy.Mutexed`로 무조건 바꾸면 안 된다.
- `List.take`, 닫힌 variant, 불변 Map/Set도 현재 도구 실행기에서 사용한다.

[공식 Lazy.Mutexed API](https://ocaml.org/manual/5.5/api/Lazy.Mutexed.html)는 mutex로 대기하므로
thunk가 fiber를 넘기면 같은 스레드의 중복 force가 실패할 수 있다고 설명한다.
기능 개수를 늘리기 위한 API 치환보다 실행 문맥에 맞게 선택하는 것이 중요하다.
현재 표본에서 `Iarray`, `Pqueue`나 모듈 의존 함수 도입이 성능·정확성을 개선한다는 측정은 확보하지 못했다.
그 사용 여부만으로 미활용 결함을 선언하지 않는다.

## OCaml 5.5.2 적용과 검증 경계

[공식 5.5.2 릴리스](https://ocaml.org/releases/5.5.2)는 2026-10-23 공개됐다.
Atomic load 제거 최적화, 일부 패턴 매칭 컴파일 오류, macOS 함수 가용성 탐지와
Marshal·map_file·Str·runtime events의 수정이 포함된다.
이 변경은 동시성·macOS·표준 라이브러리를 쓰는 이 저장소에서 적용할 근거가 있다.
MASC의 특정 코드가 각각의 오류를 실제로 밟았다는 뜻은 아니다.

[#50176](https://github.com/jeong-sik/masc/pull/50176)은 `dune-project`, 생성된 opam 메타데이터,
lock의 compiler 3종, 공용 CI action·cache identity, sandbox/oneclick 이미지,
Linux 릴리스 builder와 설치 안내를 5.5.2로 맞춘다. 과거 측정 기록과 고정 fixture는 보존한다.

버전 일치 검사, opam lint, YAML 파싱, Bash 구문과 CI 입력 검증은 통과했다.
전체 dependency solve, Dune 빌드, 이미지 재빌드, CI, 설치된 컴파일러 교체와 배포는 실행하지 않았다.
이는 ordinary PR의 독립 소스 리뷰와 전체 빌드·릴리스 증거를 구분하는 저장소 실행 프로토콜을 따른다.
