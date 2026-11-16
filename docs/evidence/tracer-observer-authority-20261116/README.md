# Tracer 실패와 실행 결과의 분리

이 묶음은 built-in Fmt tracer의 실제 출력 채널 실패 세 가지와 후보 수리의 결과를
보존한다. 프로세스 stderr는 유지하고, `Unix.dup Unix.stderr`로 만든 전용 채널만 닫았다.

## 관측한 결과

| 같은 채널 고장 | baseline 본문 횟수·결과 | 후보 본문 횟수·결과 |
| --- | --- | --- |
| span 시작 전에 닫음 | 0회, `Sys_error("Bad file descriptor")` | 1회, `42` 반환 |
| 본문이 `42`를 반환하기 전에 닫음 | 1회, 성공값 대신 `Sys_error` | 1회, `42` 반환 |
| 본문이 원래 예외를 던지기 전에 닫음 | 1회, 원래 예외 대신 `Sys_error` | 1회, 같은 원래 예외 객체 전파 |

세 프로세스는 baseline과 후보 모두 exit 0이다. 이는 probe가 결과·예외를 잡아 출력한
뒤 formatter를 복원하고 정상 종료했다는 뜻이다. baseline 동작이 올바르다는 뜻이 아니다.
후보의 예외 판정은 메시지 비교가 아니라 `exn == original`이다.

원문은 [baseline](baseline/manifest.json)과 [candidate](candidate/manifest.json)의
`start_closed`, `finish_closed_success`, `finish_closed_exception`별 `stdin.ml`,
`stdout.txt`, `stderr.txt`에 있다. 각 stdout의 `PROBE` 줄이 위 관측을 기록한다.

## 실행한 소스와 환경

- baseline: commit `607419c653251c46470eabee1b71f0ac8bd61b48`의 변경하지 않은
  `packages/agent_core/lib/tracing.ml` 전체를 OCaml toplevel에서 로드했다.
  source SHA-256은 `73997ec2bdc9369977e8b23de459622b9c1e92ff1e5d9b1141eae7e5c4afa093`이다.
- 후보: 같은 base 위의 **미커밋 working-tree 소스**를 실행했다. base SHA만으로 후보를
  식별하지 않는다. `Tracing` source SHA-256은
  `f388381921a4c604334c5fe7868547ac085417b76e207c78e52216d086007d8b`,
  `Reserved_exn` source SHA-256은
  `3b7c4146e99148e568f1c56cfbc89318b061528433073809581cf9e744e4eb87`이다.
  두 인터페이스의 hash와 각 Git blob도 원래 candidate manifest에 남아 있다.
- OCaml 5.5.1을 사용했다. 후보는 `#require "eio"`로 실제 설치 Eio를 로드하고,
  실제 `Reserved_exn.ml`과 `tracing.ml`을 `#mod_use`했다. `Llm_provider`는 로드한
  `Reserved_exn` 모듈에 namespace만 연결한다. Eio·예외 정책의 대역은 없다.
  설치 Eio의 위치는 manifest에 있고, findlib의 버전 응답은 `[unspecified]`였다.

원래 실행 명령은 다음과 같다. `stdin.ml`에는 당시의 절대 source snapshot 경로가
그대로 있으므로, 다른 checkout에서 경로를 바꾸지 않고 재실행할 수 있는 입력은 아니다.
다시 실행하려면 기록한 hash와 일치하는 source와 실제 Eio를 먼저 준비하고, 새 출력은
`artifacts/`에 기록한다.

```sh
ocaml -noinit -noprompt -I +unix unix.cma < MODE.stdin.ml
```

## 보존과 검증 범위

원래 `artifacts/continuity-native-20261116/tracer-{baseline,candidate}/capture-1`의
manifest와 각 입력·출력 20파일, 총 33,901 bytes를 바이트 그대로 복사했다. host 경로도
수정하지 않았다. 전체 source snapshot은 이 묶음에 복사하지 않았다.

보존 전에 baseline source를 해당 Git object와 대조했고, 후보 source 네 파일을
원래 snapshot·readback hash·작업트리와 대조했다. [retained-digests.json](retained-digests.json)은
선택한 원본 캡처와 source의 SHA-256 목록이며,
[current-locations.json](current-locations.json)은 원래 artifact 좌표와 보존 위치를 연결한다.
검사 대상은 보존 캡처 20개, baseline의 역사 Git blob 1개, 후보의 현재 source 위치 4개다.
마지막 네 항목은 위치 조회이며, 기록 당시 hash가 이후 편집된 source 바이트를 인증하지는
않는다. 원래 manifest의 경로·hash는 고치지 않았다.

```sh
python3 scripts/check-evidence-locations.py docs/evidence/tracer-observer-authority-20261116/current-locations.json
```

이 실행은 **실제 두 모듈과 Fmt 채널 경계**를 검증한다. `Agent.run`·provider·tool 통합,
OTel lock/metric 실패, 실제 취소, `Fun.Finally_raised`·`Eio.Exn.Multiple`의 reserved 전파,
raw backtrace 비교, SDK 인터페이스 적용·전체 타입 검사·시험 suite·CI·설치 runtime을
실행한 증거는 아니다. 관련 통합 회귀 소스는
[test_pipeline.ml](../../../packages/agent_core/test/test_pipeline.ml), tracer·wrapped reserved
회귀 소스는 [test_tracing.ml](../../../packages/agent_core/test/test_tracing.ml)에 있으며,
그 실행 결과는 별도로 확인해야 한다.

## Alcotest 출력과 고장 주입의 분리

첫 실제 SDK 실행에서 Fmt 고장 시험들이 실패해, 별도로 실제 설치 Alcotest의 verbose
출력을 조사했다. [재현 입력](alcotest-reporter/input.ml)은 항상 `42`를 반환하는 연산에
같은 닫힌 전용 formatter를 적용한다. 단언을 formatter 복원 안쪽에서 출력하면
`Alcotest_engine__Test.check`가 `Sys_error("Bad file descriptor")`를 내고, 복원한 뒤
같은 값을 단언하면 통과한다. 실제 interpreter는 앞 시험 하나의 실패로 exit 1이다.
[선택한 관측과 원문 digest](alcotest-reporter/observations.json)는 파생 기록이다.

이 결과에 따라 SDK 시험은 고장 중 실행 결과·예외·backtrace를 수집하고, formatter를
복원한 뒤 단언한다. 실제 Fmt 고장과 실행 횟수·정본 저장·원래 예외 검사는 유지한다.
아래 재현은 reporter 경계만 검사하며 수정한 SDK 시험의 통과를 대신하지 않는다.
새 결과는 보존 기록을 덮지 않도록 별도 `artifacts/` 폴더에 쓴다.

```sh
repo_src="$PWD"
probe_out=$(mktemp -d "$PWD/artifacts/alcotest-reporter.XXXXXX")
cd "$probe_out"
ocaml -noinit -noprompt -I +unix < "$repo_src/docs/evidence/tracer-observer-authority-20261116/alcotest-reporter/input.ml" > stdout.txt 2> stderr.txt
```
