# Trace 시작 실패와 실행 증거 귀속

기준: `dd34bc2515c2782d644b5be53e2c602ee0729b9f`.
이슈: [#52494](https://github.com/jeong-sik/masc/issues/52494).

## 원인과 수리

#45995는 trace 종료 실패, #51935는 중간 기록 실패를 격리했다.
시작 기록 실패는 여전히 `of_core_error`로 실행 오류가 됐다.
trace 없음 분기에는 실행 예외 후 lifecycle 정산도 없었다.

`Agent_trace`에서 시작 실패는 명시적으로 보고한 뒤 untraced 실행을 계속한다.
성공·실패·yield·예외는 trace 가용성과 관계없이 하나의 정산 경로를 사용한다.
진단 오류를 실행 오류로 끌어올리는 `of_core_error` 인자는 인터페이스와 소비자 3곳에서 제거했다.

독립 리뷰에서 같은 sink의 이전 `last_run`이 현재 실행에 붙을 수 있음을 추가로 찾았다.
`Agent.last_raw_trace_run`은 현재 lifecycle의 run ID와 완료 trace의 run ID가 일치할 때만 반환한다.
역사 trace는 sink와 query API에서 계속 읽을 수 있다.

## 실행한 재생

```sh
python3 docs/evidence/trace-start-authority-20261116/replay_source.py \
  --out artifacts/trace-start-authority-20261116/new-run
```

`replay_source.py`는 baseline의 git object와 후보 파일에서 **변경하지 않은 production 함수**를
추출해 컴파일·실행한다. Eio, lifecycle 저장, Raw_trace, logging은 명시된 경계 대역이다.
실제 Agent.run이나 파일 쓰기·provider·도구·스케줄러를 실행한 시험이 아니다.

보존한 [source-replay.json](source-replay.json):

- trace 없음/정상/start 거절, 원래 Error/예외/취소, yield, 진단 sink 및 callback 예외,
  finish 거절의 23사례. baseline은 기대 계약과 10곳 불일치, 후보는 0곳 불일치.
- 현재 run ID와 완료 ref의 일치, 시작·종료 기록 거절 뒤 이전 ref, 실행 전, trace 없음의
  5사례. baseline의 이전 ref 대체를 재현하고 후보는 모든 기대 귀속과 일치.
- 추출한 두 production 파일의 SHA-256, compiler 버전, 각 사례 실제 값과 기대 값을 보존한다.

이 replay는 함수의 정산과 귀속 결정을 검증한다. 전체 모듈의 타입 검사나 실제 runtime 통합을 증명하지 않는다.

## 실제 경로의 회귀 소스

`packages/agent_core/test/test_pipeline.ml`의 `Trace_fails_before_dispatch`는 같은 Agent/sink로
정상 완료를 만든 뒤 trace 파일을 디렉터리로 교체한다. 실제 `Agent.run` 경로가 다음 provider
응답·도구 1회·transcript·usage·정본 terminal·completion callback·lifecycle을 유지하고,
sink의 이전 완료 trace를 현재 실행 증거로 반환하지 않는지 확인한다.

`test_agent_advanced.ml`은 실제 `Agent.Advanced.run_blocks`의 cooperative yield와
실행 중 `on_yield` 예외를 trace 없음·정상·start 거절의 세 모드로 확인한다.
yield는 `Ready`와 완료 callback 미호출, 예외는 원래 객체 전파와 `Failed`, 도구 미실행을 확인한다.

소스 문법 검사와 `git diff --check`를 실행했다. Dune 빌드, 전체 타입 검사, 해당 통합 시험,
CI와 설치 runtime은 이 증거 묶음에서 실행 완료로 주장하지 않는다.
