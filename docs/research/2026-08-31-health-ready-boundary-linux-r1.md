# Full-health owner-readiness boundary Linux R1

## 결과

active full-health timeout 중 server restart는 3.37초, exit 0으로 안전했지만 기존 r61은 새 process가
ready가 된 뒤에도 full-health loop가 shell prewarm 뒤에 직렬화돼 first current snapshot까지
62.882초 걸렸다.

첫 PoC r62는 full-health loop를 shell prewarm 바로 앞으로만 옮겼다. loop 시작은 약 31초 빨라졌지만
shell compute와 경쟁해 20초 timeout이 발생했고 first current는 62.619초였다. r61 대비 0.4%만
줄었으므로 이 배치를 폐기했다.

최종 r63은 loop를 owner readiness 게시 직후, post-ready lanes와 auxiliary setup보다 앞으로 옮겼다.
같은 0.5 CPU와 복제 volume에서 process start 1.823초 뒤 current-ready가 됐다. r61 대비 97.1%
단축됐고 worker submission 1, join 0, timeout 0이었다.

## 외부 근거와 적용

- [Eio 공식 문서](https://github.com/ocaml-multicore/eio)는 switch 기반 structured concurrency와
  executor pool job/caller cancellation 경계를 설명한다. readiness 이후 별도 worker loop의 lifecycle을
  shell prewarm 반환값에 묶을 이유는 없다.
- [The Tail at Scale](https://www.cse.ust.hk/~weiwa/teaching/Fall15-COMP6611B/reading_list/TheTailAtScale.pdf)는
  straggler를 duplicate work로 완화할 수 있지만 비용과 동시성 경계를 함께 다룬다.
- [Straggler Mitigation at Scale](https://arxiv.org/abs/1906.10664)은 delayed redundancy의 latency/cost
  tradeoff가 service-time tail에 따라 달라짐을 보인다.

0.01–0.5 CPU에서 이미 전체 compute가 느린 MASC 조건에서는 hedge를 추가하지 않았다. 현재성 계산에
먼저 짧은 단독 head start를 주고 shell work를 기존 순서대로 시작하는 쪽을 선택했다.

## source cause와 변경

기존 `server_runtime_bootstrap.ml`은 owner state를 ready로 게시한 뒤 post-ready lanes, auxiliary
transports, dashboard loops, shell prewarm을 거쳐서야 full-health loop를 시작했다. 특히 full-health
호출은 shell prewarm fiber 안에서 prewarm 반환/outer timeout 뒤에 있었다.

변경은 `start_full_health_snapshot_refresh_loop`를 `mark_owner_state_ready` 직후로 이동한다.

- owner state와 request authority는 이미 확정됐다.
- compute는 #31993의 process-wide singleflight worker로 main domain 밖에서 실행된다.
- 후속 lane/lifecycle mutation은 generation invalidation으로 초기 결과를 폐기하거나 refresh한다.
- shell prewarm timeout/budget/실행 자체는 바꾸지 않는다.

## exact identity

### stacked product

- issue: `#31994`
- stacked base: `163d6466879ac46ee998c4abb0a5a0113b15db80` (`#31993` head)
- product change: `9f73f1c8bc5027010683742b367277462099c53e`

### r61 baseline/restart

- source: `ac8e5d44264cfa5d1f80e946b38abfbd67c57952`
- image: `sha256:870546f09fe7596523475ac485440a8e65f86a7db901d1614db1c2c85df9f38c`
- binary: `0dd6883dbebb12c4b32f45188f77d43cddb6f6a29554cf5983effdbed5b3243a`
- before runtime: `01a053bc-d7e6-7000-8206-06623dd99d9b`
- after runtime: `01a053bf-f00b-7000-b6e4-923d239a0c6f`

### r62 rejected placement

- source: `fcc017294ee7d04de74b835679b19ff29eef39c0`
- image: `sha256:16972d428c426d396f780ead74ab098cff15ad35bda0a1236949d8acecbe5754`
- binary: `dcb58b4a9c121a54202b18e1ce4721bf424e1e635f14d7acee2b78df5202b007`
- runtime: `01a053c8-8aa9-7000-83b3-07d9df5bf4c3`

### r63 fixed

- measurement source: `79a3254a81cf857f69d3888e3c87e13017d48c50`
- image: `sha256:111b409d8764b1d9f28318a1e7824a75e967f986883a07a66924ea24de7f883f`
- binary: `feff50c3ef1d1ae6b5e2b8b5a315efe5b69063c469099525548f3db8d0e2057d`
- runtime: `01a053cc-acc2-7000-b709-23f72c33a68e`

## r61 active-timeout restart

0.01 CPU에서 worker submissions 2, joins 3, active/in-flight true인 20초 timeout snapshot을 잡았다.
그 상태에서 `docker stop --time 30`은 3.37초 만에 exit 0/OOM false로 끝났다. preserved volume을
0.5 CPU로 재시작하자 runtime ID가 바뀌었고 overdue schedule 4개가 durable queue/ledger에 반영됐다.

- receipt: 4/4 accepted
- ledger: 4 rows, 4 unique schedule/stimulus IDs
- queue: 248 → 252
- final latest stimulus: `4a66d7507f297cb51911780c928f8c69e386520afaad673cfcd7b662e1edd91e`
- final health latest: 위 ID와 일치
- first current: process start 뒤 62.882초

restart는 hung/slow worker의 bounded escape가 됐지만 health current-state 재형성 지연은 별도 문제였다.

## r62 폐기된 PoC

full-health call을 shell prewarm 바로 앞으로 옮기자 loop는 process start 약 31.3초 뒤 시작했다. 그러나
shell prewarm과 겹친 initial worker가 timeout됐고 후속 waiter가 join했다. first current는 62.619초로
r61과 사실상 같았다.

“loop log가 빨라졌다”는 “current snapshot이 빨라졌다”가 아니므로 이 source placement를 fix로
채택하지 않았다.

## r63 owner-readiness 배치

- process start: `2026-08-30T17:51:57.533161342Z`
- 첫 HTTP full probe: `17:51:57.976323Z` (blocking/warming)
- owner ready 관측: `17:51:59.033304Z`
- first current computed: `1788112319.356038` (`17:51:59.356038Z`)
- first current 관측: `17:51:59.365892Z`
- process-start-to-current: 1.823초
- compute duration: 19ms
- submissions 1, joins 0, timeout 0
- queue 252, latest stimulus 일치
- app exit 0, OOM false

r61 62.882초 → r63 1.823초로 97.1% 감소했다. source identity가 다른 r62 negative run도 함께 보존해
단순한 loop-start log를 성공 증거로 오인하지 않게 했다.

## 검증과 경계

- focused build: `bin/main_eio.exe`, `test_server_runtime_bootstrap.exe` pass
- main_eio cases 73–74: 2/2 pass
- `ocamlformat --check`, `git diff --check`: pass
- full suite와 CI는 실행/주장하지 않는다.
- 한 Linux/arm64 process와 복제 volume의 restart pair다. cold empty volume, multi-server, PG-backed
  dashboard 환경은 아직 측정하지 않았다.

## 근거

- [근거] r61/r62/r63 committed source, Linux image/binary/runtime identity, canonical receipt/ledger,
  sub-second startup timeseries, shutdown inspect, 2026-08-31T02:52:54+09:00 확인, 신뢰도 High.
- [근거] Eio 공식 문서와 위 straggler 1차 논문, 2026-08-31 확인, 신뢰도 High.
