# Full-health worker singleflight Linux R1

## 결과

`Proactive_refresh`의 20초 timeout은 기다리는 Eio fiber만 취소하고 이미 executor pool에 제출된
full-health scan은 중단하지 않는다. mutation wake가 다음 refresh를 깨우면 기존 worker가 살아 있는
동안 새 scan을 제출할 수 있었다.

변경은 process-wide active worker promise를 둔다. 첫 waiter만 worker를 제출하고 후속 waiter는 같은
promise를 join한다. 원래 waiter가 timeout되어도 worker는 server switch 아래에서 계속 실행하며,
성공 결과를 직접 게시한다. compute 중 invalidation generation이 바뀐 결과는 current임을 증명할 수
없으므로 폐기하고 bounded follow-up wake를 추가한다.

r60 Linux fault run에서 20초 timeout 2회가 실제 발생했다. 첫 timeout 뒤 34초 시점까지
`refresh_worker_active=true`, `refresh_in_flight=true`, submissions=62가 유지됐다. 다음 wake는
submissions를 늘리지 않고 joins만 0→1로 바꿨고 log도 `joined active worker 62`를 남겼다. 두 번째
timeout 뒤 worker 63은 새 submission 없이 late ready snapshot을 게시했다. dirty generation 결과는
두 번 폐기됐고, 61개 durable stimulus가 모두 처리된 뒤 current-ready로 수렴했다.

## 외부 근거와 적용

- [Lemmalog 원문](https://pwning.systems/posts/llm-memory-program-analysis/)은 검색된 과거 사실과
  현재 프로그램 상태를 분리하고 입력 변경 시 의존 결론을 철회해야 한다고 설명한다.
- [STALE](https://arxiv.org/abs/2605.06527)은 updated evidence를 검색하는 것과 downstream 행동에
  반영하는 것 사이의 gap을 측정한다.
- [Supersede](https://arxiv.org/abs/2606.27472)는 superseded value를 명시적으로 폐기하는 것이 더
  큰 memory와 별도 문제임을 보인다.
- [CUP query coalescing](https://www.usenix.org/legacy/publications/library/proceedings/usenix03/tech/full_papers/roussopoulos/roussopoulos_html/node7.html)은
  진행 중인 fresh query에 sibling을 합치고 timer로 지연을 제한한다.

MASC 적용은 “진행 중인 사실 계산은 공유하고, mutation 이후 어느 generation을 읽었는지 증명할 수
없는 계산 결과는 게시하지 않는다”이다.

## exact identity

- issue: `#31992`
- stacked base: `67a6654914ecef8cf10105bafc2d3125c7ca220c` (`#31991` head)
- product change: `c1f6a013ad04570d49ed2aaafcbddb02f500fb9f`
- measurement composition: `ac8e5d44264cfa5d1f80e946b38abfbd67c57952`
- Linux/arm64 image: `sha256:870546f09fe7596523475ac485440a8e65f86a7db901d1614db1c2c85df9f38c`
- binary SHA-256: `0dd6883dbebb12c4b32f45188f77d43cddb6f6a29554cf5983effdbed5b3243a`
- runtime instance: `01a053ae-16a4-7000-a0d6-b2bb618107ae`

measurement composition은 product change, 앞선 health observer/coalescing stack, old-source Docker
build 보완만 포함한다. committed source, image digest, in-process binary hash, runtime instance를 함께
고정했다.

## setup

중지된 r59 volume을 새 r60 volume으로 read-only 복제해 durable 부하 조건을 유지했다. 새 image로
server를 재부팅하고 ready를 확인한 뒤 같은 due time의 `qa` one-shot schedule 61개를 생성했다.
61개 모두 HTTP 200/MCP accepted였고, due 전에 container CPU quota를 0.05 CPU로 낮췄다. 5초 간격
full-health probe 65개는 HTTP 오류 없이 수집됐다. deployed 8935와
`/Users/dancer/me/.masc`는 건드리지 않았다.

## timeout singleflight timeline

- `17:26:00Z`: worker 62 waiter가 20.0초 timeout. 첫 timeout sample은 submissions 62, joins 0,
  active/in-flight true, generation 115였다.
- `17:26:34Z`: 후속 wake가 worker 62를 join. submissions 62 유지, joins 1, active/in-flight true.
- `17:26:43Z`: joined waiter가 8.7초 뒤 같은 worker 결과를 받았다. 새 worker submit은 없었다.
- `17:27:06Z`: worker 63 waiter가 다시 20.0초 timeout. submissions 63, active/in-flight true.
- `17:27:19.088Z`: submissions 63인 채 ready snapshot이 게시됐다. 원래 waiter timeout 뒤 살아 있던
  worker가 결과를 게시했음을 보여 준다.
- worker 52와 64의 결과는 compute 중 generation이 바뀌어 각각 폐기됐다.

timeout metadata가 표시되는 동안 `refresh_in_flight`와 `refresh_worker_active`가 true로 유지됐다.
따라서 caller timeout을 worker 종료로 오인하지 않는다. 동일 active worker에 대한 timeout failure는
한 번만 snapshot failure로 기록한다.

## durable convergence

- schedule receipt: 61 attempts, 61 accepted, HTTP error 0
- durable ledger: 61 rows, 61 unique schedule IDs, 61 unique stimulus IDs
- row 범위: `1788110468.288173..1788110859.790674` (391.503초)
- durable event queue: 187 → 248
- final qa stimulus: `e7148c81aaf61164f53064a290403132d889114b861d9191cfbff354ffea796c`
- final health의 qa latest stimulus: 위 ID와 일치
- final snapshot: ready, active=false, in-flight=false, requested=false, stale/error 없음
- final generation: 127

첫 timeseries generation 3에서 final 127까지 124회 증가했다. schedule 61건의 queue/ledger mutation
122회 외에 같은 process의 observer signal 2회가 섞였으므로 124 전부를 schedule에 귀속하지 않는다.

## 검증과 경계

- focused build: `test_server_runtime_bootstrap.exe` pass
- health cases 51–56: 6/6 pass
- 새 결정론적 회귀: canceled waiter 뒤 worker 생존/join, dirty generation 폐기/후속 성공
- `ocamlformat --check`, `git diff --check`: pass
- r60 app exit 0, OOM false
- full suite와 CI는 실행/주장하지 않는다.
- 한 process, Linux/arm64, 0.05 CPU fault의 결과다. multi-server coordination과 worker가 영구적으로
  끝나지 않는 경우는 아직 측정하지 않았다.

## 근거

- [근거] committed source `ac8e5d4`, Linux image/binary/runtime identity, canonical MCP receipt,
  durable ledger, 65-sample health timeseries, complete selected logs, 2026-08-31T02:30:04+09:00 확인,
  신뢰도 High.
- [근거] local Eio 5.5 executor source의 caller-side promise wait와 worker-owned function execution,
  같은 시각 확인, 신뢰도 High.
- [근거] 위 논문/USENIX 1차 출처, 2026-08-31 확인, 신뢰도 High.
