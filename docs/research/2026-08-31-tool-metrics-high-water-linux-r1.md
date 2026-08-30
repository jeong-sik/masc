# Tool metrics high-water wake Linux R1

## 결과

고정 timer만 기다리던 `Tool_metrics_persist` writer를 queue 2,048/4,096에서 조기 기상시킨다.
completion 경로는 기존 bounded enqueue 뒤 condition broadcast만 수행하며 파일 I/O는 하지 않는다.
timer는 최대 flush 지연으로 그대로 남는다.

r98의 반례와 같은 `MASC_METRICS_FLUSH_SEC=300` 조건에서 5,000 accepted call을 다시 실행했다.
이전 구현은 clean replacement에서 904건을 잃었지만 r104는 high-watermark batch 두 번과 shutdown
batch 한 번으로 5,000건을 모두 보존했다.

## 설계

- queue capacity 4,096, high watermark 2,048. writer가 scheduling되고 drain을 시작하는 동안
  producer가 쓸 2,048 slot을 남긴다.
- enqueue lock 안에서는 queue 추가와 threshold transition만 계산한다. `Eio.Condition.broadcast`는
  lock 밖에서 threshold 도달 때 한 번만 호출한다.
- writer는 `Eio.Time.with_timeout`과 condition predicate를 함께 기다린다. high watermark면 일찍,
  그렇지 않으면 기존 interval에 깨어난다.
- exact dependency는 Eio/Eio_main 1.3이다. 해당 버전의
  [Condition](https://github.com/ocaml-multicore/eio/blob/v1.3/lib_eio/condition.mli)과
  [Broadcast](https://github.com/ocaml-multicore/eio/blob/v1.3/lib_eio/core/broadcast.mli) 계약을
  확인했다. broadcast core는 lock-free이며 다른 context에서 wake callback을 실행할 수 있으므로,
  queue predicate는 기존 `Stdlib.Mutex`로 계속 보호한다.

## r104 Linux/arm64, timer 격리

- base head: `2e6467d78de224f191a69fdc89d584adb2cce1aa`
- product head: `8092300769217f9e2a4cfc02efe34010aae7e117`
- image: `sha256:469bc09079e9f01d3dd7269548800cf7e1a796bbbfcb2497b52c91f3763b024b`
- binary: `8f89d339...f7963`, preflight helper: `7e0232a4...29fe`
- 시작 로그 `interval=300s`; 27.823828초 측정 중 timer는 동작할 수 없다.
- 실제 `masc_goal_list` 5,000/5,000 HTTP 200 및 body-level `isError=false`.
- live API 5,000, 평균 179.702 calls/s, drop 로그 0.
- `trigger=high_watermark`로 2,048행씩 두 번 썼다.
- stop 직전 disk 4,096행/463,651 bytes, SHA-256 `6e272bd9...e11d`.
- clean shutdown이 남은 904행을 기록했다. 최종 5,000행/565,909 bytes,
  SHA-256 `311208b2...f12`.
- replacement runtime은 `hydrated 5000`, API 5,000. 두 runtime 모두 exit 0/OOM false.

## r105 기본 timer 회귀

같은 5,000행 volume을 override 없이 다시 열어 `hydrated 5000`을 확인했다. high watermark보다 작은
실제 call 한 건은 `trigger=timer`로 기록됐다. API와 disk 모두 5,001, exit 0/OOM false였다.
따라서 high-water wake가 기본 0.5초 maximum delay를 대체하지 않는다.

## 검증과 경계

- Tool_metrics_persist 7/7, focused `main_eio` build, `ocamlformat --check`, `git diff --check` 통과.
- r104는 local named volume, 단일 session, 순차 accepted load다. 300초 override로 timer를 격리했다.
- 2,048 slot은 scheduling headroom이지 durable guarantee가 아니다. writer가 실행되기 전에 4,096건이
  완료되거나 storage drain보다 admitted producer가 계속 빠르면 drop은 다시 가능하다.
- 전체 테스트, GitHub CI, 강제 지연/network filesystem, Kubernetes/PVC는 확인 범위 밖이다.
- `/Users/dancer/me/.masc`와 현재 8935 서버는 변경하거나 재시작하지 않았다.

## 근거

- [근거] exact Eio 1.3 source 계약과 product/image/binary/helper identity, 5,000 body-level accepted
  responses, high-watermark batch logs, live/disk/SHA, shutdown batch, replacement hydration/API,
  세 runtime exit/OOM을 2026-08-31T07:12:50+09:00 확인, 신뢰도 High.
