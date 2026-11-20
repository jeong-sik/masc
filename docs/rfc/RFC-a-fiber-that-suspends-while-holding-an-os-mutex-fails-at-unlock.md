---
rfc: "a-fiber-that-suspends-while-holding-an-os-mutex-fails-at-unlock"
title: "OS mutex 를 쥔 채 멈춘 fiber 는 잠금을 놓을 때 실패한다"
status: Draft
created: 2026-11-16
updated: 2026-11-16
author: claude
supersedes: []
superseded_by: null
related: ["main-domain-scheduler-latency", "http-transport-runs-on-its-own-domain-and-each-route-names-where-it-runs"]
---

# RFC: OS mutex 를 쥔 채 멈춘 fiber 는 잠금을 놓을 때 실패한다

- 상태: 초안.
- 이슈: #52363. 마지막 사례는 #52360 이고, #52362 가 그 자리를 고쳤다.
- 코드 좌표와 자리 수는 `origin/main` `706704b625a5` 에서 읽었다.
- Eio 는 1.3 이다. eio, eio.unix, eio_posix 는 설치된 소스에서 읽었다. eio_linux 는 opam 이 남긴 eio 1.3 소스 묶음에서 읽었다. eio_linux 는 설치돼 있지 않아 돌려 보지 못했다.
- D2 는 시험 프로그램으로 골랐다. 「기록 7b」는 그 시험 결과 표의 경우 번호다.
- 이 RFC 는 masc 코드를 바꾸지 않는다.

## 0. 요약

2026-11-16 에 Dashboard 「이번 달 효율」 패널이 자격을 바꿀 때마다 「읽지 못함」을 보였다.
서버는 겹친 효율 읽기 가운데 하나에 503 `Mutex.lock: Resource deadlock avoided` 로 답했다(#52360).

`Keeper_efficiency.read_month` 는 `Stdlib.Mutex` 를 쥔 채 캐시 파일을 썼다.
fiber 에서 부른 캐시 쓰기는 시스템 스레드 작업으로 돈다. 그동안 fiber 는 멈춘다.
같은 스레드의 다음 fiber 가 같은 mutex 를 잡으려 했고, OS 가 거절했다.

같은 결함을 고친 일이 2026-04 부터 열다섯 번이다. 이슈로 남은 것이 일곱, 이슈 없이 PR 로만 고친 것이 여덟이다.
열다섯 번 모두 한 자리씩 고쳤다. 같은 모양을 막는 검사는 남지 않았다.
2026-10-27 에는 여섯 자리를 한나절에 고쳤다. 나흘 뒤 #46989 가 같은 모양을 새로 들였고, 그 자리가 #52360 이 됐다.
lib·bin·`packages/agent_core/lib` 에는 `Stdlib.Mutex` 를 잡는 자리가 767곳 있다. 그 가운데 몇 곳이 쥔 채 멈추는지는 모른다.

이 RFC 는 여섯 가지를 정한다.

1. OS mutex 는 새 모듈 `Os_mutex` 로만 잡는다.
2. Eio fiber 에서 잡으면 잠금 구역을 effect handler 안에서 돌린다. 구역 안에서 fiber 가 바뀌면 그 자리를 바로 stderr 에 적는다. 구역이 끝나면 mutex 를 풀고 예외로 끝난다. 요청이 겹치지 않아도 한 번 지나면 드러난다.
3. 시험과 운영이 같은 규칙을 쓴다. 모드나 환경 변수를 두지 않는다.
4. 다 옮긴 뒤에는 CI 가 두 모듈(`Os_mutex`, `Cross_context_mutex`) 밖의 `Stdlib.Mutex` 를 막는다. 허용 목록은 없다.
5. 옮기는 일은 층으로 나눈다. 층마다 CI 를 통과한다.
6. masc 는 Eio 백엔드로 posix 하나를 쓴다. 그래야 D2 의 effect 표가 빠짐없이 맞는다.

## 1. 결정

### D1. OS mutex 는 `Os_mutex` 로만 잡는다

- 새 라이브러리 `packages/agent_core/lib/os_mutex` 에 둔다. `eio`, `eio.unix` 에만 기댄다.
  - `packages/agent_core/lib` 의 30곳도 이 모듈을 써야 한다.
  - lib 의 가장 아래 라이브러리 `fs_compat` 은 이미 `masc.agent_core.digest` 에 기댄다. 그래서 `agent_core` 아래에 두면 양쪽이 다 쓸 수 있다.
- 함수는 넷이다.
  - `create : name:string -> unit -> t` — 이름은 기록과 예외에 실린다.
  - `protect : t -> (unit -> 'a) -> 'a`
  - `try_protect : t -> (unit -> 'a) -> 'a option` — 지금 비어 있을 때만 돈다. `None` 은 잠금을 잡지 못했다는 뜻이다. 잡은 뒤에는 `protect` 와 같아서, 본문이 멈추면 `Held_across_suspension` 을 던진다.
  - `wait : Condition.t -> t -> unit` — `protect` 안에서만 부른다. fiber 가 아니라 시스템 스레드를 막고 effect 를 내지 않으므로 D2 가 잡지 못한다.
- `lock`·`unlock` 은 두지 않는다. `Mutex.lock` 을 쓰는 89곳은 `protect` 로 바꾼다. 잠그는 함수와 푸는 함수가 다른 자리는 그 자리의 설계를 다시 본다.
- `t` 는 추상 타입이다. `Mutex.create` 를 `Os_mutex.create` 로 바꾸면, 그 mutex 를 아직 `Mutex.protect` 로 잡는 자리는 타입 검사에서 실패한다. 빠진 자리를 컴파일러가 찾는다.
- 예외를 다시 던질 때 backtrace 를 지킨다. `Stdlib.Mutex.protect` 는 `%reraise` 로 그렇게 한다(`mutex.ml:23-34`).
- 쥔 채 멈춰야 하는 잠금은 `Cross_context_mutex` 를 쓴다(#24657 이 만들었다). 고른 모듈 이름이 그 선택을 코드에 남긴다.

### D2. 잠금 구역 안에서 fiber 가 바뀌면, 구역이 끝날 때 예외로 끝난다

- Eio 에서 fiber 가 멈추거나 차례를 넘기는 일은 모두 effect 로 일어난다.
- `Os_mutex.protect` 는 Eio fiber 에서 불리면 본문을 `Effect.Deep` handler 안에서 돌린다. 본문이 몇 모듈을 건너든, closure 로 넘어갔든, 본문이 낸 effect 는 이 handler 를 먼저 지난다.
- handler 는 effect 를 모두 Eio 로 넘긴다. 구역에 표시가 생길 때까지, fiber 를 바꾸는 effect 를 만날 때마다 두 가지를 한다.
  - 넘기기 전에 기록 하나를 stderr 에 한 번에 쓰고 바로 비운다(flush). OCaml 의 `stderr` 는 버퍼를 쓴다. 기록에는 mutex 이름, effect 종류, 호출 스택 둘이 들어간다. 하나는 effect 를 낸 쪽이고, 하나는 `protect` 를 부른 쪽이다.
  - 넘긴 effect 가 값으로 돌아오거나 `Effect.Unhandled` 가 아닌 예외로 돌아오면, 구역에 「멈췄음」을 표시한다.
- 표시가 생긴 뒤의 effect 는 기록 없이 넘긴다.
- 본문이 끝나면 `protect` 가 표시를 본다. 표시가 있으면 mutex 를 풀고 이렇게 끝맺는다.
  - 본문이 값을 돌려줬거나 예외로 끝났으면 `Os_mutex.Held_across_suspension` 을 던진다. 예외는 mutex 이름, 표시를 남긴 effect 의 기록, 본문이 낸 예외를 싣는다. `body_raised = None` 이면 본문은 정상 종료했다는 뜻이다. 예외로 끝난 본문도 그 전에 부작용을 남겼을 수 있다.
  - 본문이 취소(`Eio.Cancel.Cancelled`)로 끝났으면 그 예외를 바꾸지 않고 다시 던진다. Eio 문서는 취소를 보통 알릴 필요가 없는 일로 본다(`eio__core.mli:559-563`). 기록은 이미 stderr 에 있다.
  - 예외는 본문이 끝난 뒤에 난다. 그래서 본문은 이 예외를 잡을 수 없다(기록 4).
- `Held_across_suspension` 을 받아 본문을 자동으로 재시도하지 않는다. 파일 쓰기 같은 부작용은 이미 적용됐을 수 있다. 실패한 잠금 구역을 고친다.
- 호출 스택을 둘 남기는 까닭: effect 를 낸 쪽 스택은 꼬리 호출 때문에 자주 비거나 Eio 함수만 남는다. 시험의 기록 12개 가운데 넷은 비었고, 다섯은 Eio 함수만 담았다.
  - handler 는 `protect` 를 부른 쪽 스택 위에서 돈다. 그 스택에서는 `protect` 와 그 위 호출 줄이 잡힌다(시험 기록의 「다시 돌린 결과」).
  - `protect` 가 꼬리 호출이면 한 단계 위 호출 줄이 잡힌다. 어느 잠금인지는 mutex 이름이 알려 준다.

fiber 를 바꾸는지는 effect 마다 정한다. eio 1.3 과 eio_posix 1.3 이 선언한 effect 는 열넷이다. eio_linux 는 셋을 더 선언한다.

| effect | 선언한 곳 | 백엔드가 하는 일 | 이 RFC |
|---|---|---|---|
| `Get_context` | `eio/core/cancel.ml:32` | 지금 fiber 의 문맥을 바로 돌려준다 (`eio_posix/sched.ml:361`) | 바꾸지 않음 |
| `Get_monotonic_clock`, `Pipe` | `eio/unix/private.ml:9-10` | 그 자리에서 값을 돌려준다 (`eio_posix/domain_mgr.ml:45`, `:69`) | 바꾸지 않음 |
| `Import_socket_stream`·`_listening`·`_datagram`, `Socketpair_stream`·`_datagram` | `eio/unix/net.ml:63-68` | 그 자리에서 값을 돌려준다 (`domain_mgr.ml:46-68`) | 바꾸지 않음 |
| `Suspend` | `eio/core/suspend.ml:2` | fiber 를 멈춘다 (`sched.ml:362`) | 바꿈 |
| `Fork` | `eio/core/fiber.ml:3` | 부모를 run queue 맨 앞에 넣고 자식을 먼저 돌린다 (`sched.ml:368-371`) | 바꿈. 자식이 도는 동안 부모는 mutex 를 쥐고 있다. |
| `Await_readable`, `Await_writable` | `eio/unix/private.ml:7-8` | fd 를 기다린다 (`sched.ml:373`, `:376`) | 바꿈 |
| `Run_in_systhread` | `eio/unix/thread_pool.ml:98` | 시스템 스레드 작업이 끝날 때까지 멈춘다 (`sched.ml:379`) | 바꿈 |
| eio_posix 의 `Enter` | `eio_posix/sched.ml:338` | 멈춘다 (`sched.ml:356`) | 바꿈 |
| eio_linux 의 `Enter` | `lib_eio_linux/sched.ml:75` | 멈춘다 | 바꿈 |
| eio_linux 의 `Get`, `Cancel` | `lib_eio_linux/sched.ml:76-77` | 스케줄러를 돌려주거나 io_uring 취소를 넣고 바로 돌아온다 (`sched.ml:401`, `:410-412`) | 바꾸지 않는다. 그러나 `Eio_linux` 가 둘을 내보내지 않아 표에 넣을 수 없다(D6). |

- effect 는 열린 타입이라 모든 갈래를 적을 수 없다. 표에 넣지 못한 effect 는 바꾼다고 본다.
- 표가 모자라면 시험이 시끄럽게 실패한다. 조용히 놓치지는 않는다.

effect 를 그 자리에서 거절하지 않고 기록만 하는 까닭이 있다.

- Eio primitive 는 내부 `Stdlib.Mutex` 를 쥔 채 `Suspend` 를 낸다. 그 mutex 는 스케줄러가 부르는 callback 에서 풀린다. `Eio.Mutex`(`eio/eio_mutex.ml:54-59`, `eio/waiters.ml:41-66`)와 `Eio.Stream`(`eio/stream.ml:54-55`, `:72`)이 그렇다.
- handler 가 `Suspend` 를 거절하면 그 callback 이 돌지 않는다. 내부 mutex 는 잠긴 채 남는다.
- 시험에서 다른 fiber 가 쥔 `Eio.Mutex` 를 잡으려던 구역을 거절했다. 그 뒤 같은 스레드에서 그 `Eio.Mutex` 를 쓴 fiber 는 `Sys_error "Mutex.lock: Resource deadlock avoided"` 로 실패했다. 시험 mutex 를 잡지 않은 fiber 도 같았다(기록 7b·8, discontinue).
- 기록만 하는 handler 에서는 같은 `Eio.Mutex` 를 그 뒤에도 쓸 수 있었다(기록 8, record).

그래서 결함이 있는 구역도 지금처럼 한 번은 멈춘다.

- 멈춘 동안 같은 스레드의 다른 fiber 가 같은 mutex 를 잡으면, 지금처럼 `Sys_error` 로 실패한다.
- 다른 도메인이나 시스템 스레드가 잡으려 하면, 지금처럼 그 스레드가 막힌다.
- 멈춘 일이 같은 mutex 를 기다리면 구역은 끝나지 않는다. 구역 안에서 맡긴 시스템 스레드 작업이 같은 mutex 를 잡는 경우가 그렇다. masc 는 시스템 스레드 작업 안의 `Stdlib.Mutex` 를 허락한다(`lib/core/eio_guard.ml:70-80`). 이때는 예외 없이 지금처럼 멈춰 선다. stderr 의 기록만 남는다.
- 이 RFC 가 바꾸는 것은 쥔 쪽이다. 구역이 끝나면, 겹치지 않아도 매번 실패한다.

Eio 밖(시스템 스레드, 시험의 main)에서는 handler 를 걸지 않는다.
masc 의 일부 코드는 `Effect.Unhandled` 를 받아 Eio 밖임을 안다(`Fs_compat.Execution_context.current`). handler 가 그 판정을 가로채면 안 된다.
시험에서 Eio 밖의 `Eio_unix.run_in_systhread` 는 그대로 `Effect.Unhandled` 로 끝났다(기록 0).

masc 의 `Systhread_host.await` 는 작업이 이미 끝났으면 멈추지 않고 돌아온다(`lib/fs_compat/systhread_host.ml:31-33`). 그 번에는 표시가 남지 않는다.
L1 은 이 빠른 길을 지운다. 이미 끝난 작업도 한 번 멈췄다가 돌아온다. 그래야 `Systhread_host.run` 을 부르는 125곳을 지나는 구역이 매번 드러난다.

### D3. 시험과 운영이 같다

- 모드, 환경 변수, `set_*_for_test` 를 두지 않는다.
- 지금 같은 결함은 요청이 같은 스레드에서 겹칠 때만 `Sys_error` 로 드러난다. 다른 도메인이 잡으려 하면 그 도메인의 스레드가 오류 없이 막힌다.
- D2 뒤에는 그 경로를 지날 때마다 쥔 쪽이 실패한다. 시험이 그 경로를 Eio 안에서 한 번 돌리면 드러난다.
- `Eio_mock` 을 쓰는 시험 말고는, 시험과 운영이 같은 Eio 백엔드를 쓴다(D6).
- 대가가 셋 있다.
  - 지금은 겹치지 않아서 답을 내는 경로도, 옮긴 뒤에는 매번 실패한다. 구역 안에서 한 일(파일 쓰기 등)은 실패 전에 끝나 있다. D5 가 한 번에 옮기는 범위를 줄여 그 위험을 나눈다.
  - `protect` 가 느려진다. Eio 안에서는 handler 를 건다. Eio 밖에서는 Eio 안인지 물을 때마다 `Effect.Unhandled` 예외 하나가 난다. 잰 값은 §5 에 있다.
  - 결함 경로를 지날 때마다 stderr 에 기록이 쌓인다.

### D4. 다 옮긴 뒤에는 CI 가 두 모듈 밖의 `Stdlib.Mutex` 를 막는다

- `tools/ocaml_boundary_audit` 에 분류를 하나 더한다. 이 도구는 `.cmt` 의 typed tree 를 읽고 `lib`, `bin`, `packages/agent_core/lib` 을 본다(`ocaml_boundary_audit.ml:43`).
- 지금 도구는 함수 자리에 놓인 이름을 경로 이름으로만 본다(`Texp_apply` 안의 `Texp_ident`, `:310-313`). 세 경우를 놓친다.
  - 별칭: `module M = Mutex` 뒤의 `M.protect`.
  - `include`: `module L = struct include Mutex end` 뒤의 `L.lock`.
  - 값으로 쓴 이름: `let h = Mutex.lock`.
- 마지막 층은 경로 이름 대신 값이 선언된 자리를 본다. `Texp_ident` 를 모두 보고, value description 의 선언 식별자(`val_uid`)가 `Stdlib__Mutex` 단위를 가리키면 잡는다(compiler-libs `types.mli:463`, `shape.mli:60`).
  - 경로의 별칭을 푸는 방법(`Env.normalize_value_path`)은 별칭만 푼다. `include` 로 들어온 값은 새 경로를 갖는다.
  - OCaml 5.5.2 에서 작은 프로그램으로 확인했다. 직접 쓴 이름, 별칭, `include`, `open` 뒤 이름, 다른 컴파일 단위의 `include` 가 모두 `Stdlib__Mutex` 식별자를 가졌다(시험 기록 「audit 식별자」).
  - §6.3 의 단위 시험이 네 경우를 확인한다.
- 허용하는 곳은 두 파일이다. `packages/agent_core/lib/os_mutex/os_mutex.ml` 과 `lib/core/cross_context_mutex.ml` 이다. 기준선 파일(`scripts/ocaml-boundary-baseline.tsv`)에 줄을 남기지 않는다.
- 지금 이 도구를 부르는 workflow 는 없다. 마지막 층이 `pr-type-check.yml` 의 `dune build @check` 뒤에 붙인다. 그 단계가 `.cmt` 를 만든다.

### D5. 층으로 옮긴다

- L1: `Os_mutex`, `Systhread_host.await` 의 빠른 길 지우기, §6.1 시험, 비용 측정. §6.1 시험은 `Eio_posix.run` 을 직접 부른다. 아직 옮긴 잠금은 없다.
- L2: D6. `Eio_main.run` 을 `Eio_posix.run` 으로 바꾼다. 기계적으로 바꾸는 일이라 디렉터리 단위로 나눈다.
- L3 부터: 잠금을 디렉터리 단위로 옮긴다. 층마다 CI 전체를 통과한다. 실패한 자리는 같은 층에서 고친다. `Cross_context_mutex` 로 바꾸거나, 멈추는 일을 잠금 밖으로 뺀다(#46446 이 그렇게 고쳤다).
- 마지막 층: D4.

### D6. masc 는 Eio 백엔드로 posix 하나를 쓴다

- 운영 서버는 macOS 에서 돌고, Eio 는 거기서 posix 를 고른다. Linux CI 는 지금 io_uring 으로 돈다. `test/dune:5827` 은 이 차이 때문에 시험 둘을 이미 posix 로 고정했다.
- Linux 에서도 백엔드는 기계가 고른다. `Eio_main.run` 은 io_uring 을 먼저 쓴다. io_uring 이 없거나(ENOSYS) 막혔거나(EPERM) 커널이 5.15 미만이면 posix 로 넘어간다(`lib_main/eio_main.ml`, `lib_eio_linux/sched.ml:513-522`).
- io_uring 백엔드(eio_linux)는 fiber 를 바꾸지 않는 effect 둘(`Get`, `Cancel`)을 더 쓴다. `Eio_linux` 가 둘을 내보내지 않아서 D2 표에 넣을 수 없다. 그래서 io_uring 에서는 둘이 「바꾼다」로 잡힌다.
  - `Cancel` 은 io_uring 작업 중인 fiber 를 취소할 때, 취소하는 쪽 스택에서 난다(`lib_eio_linux/sched.ml:166`). 잠금 구역 안에서 `Switch.fail` 등으로 그런 fiber 를 취소하면, 그 구역은 Linux 에서만 거짓으로 실패한다.
  - `Switch.fail`·`Cancel.cancel` 은 운영 코드(lib·bin·`packages/agent_core/lib`)에 28번, `packages/agent_core/test` 에 179번 나온다. 잠금 구역 안의 것이 몇인지는 세지 않았다.
  - `Get` 은 고정 버퍼를 빌리고 돌려줄 때 난다(`lib_eio_linux/low_level.ml:211-237`).
- posix 하나로 가면 표가 빠짐없이 맞는다. `Eio_mock` 을 쓰는 시험 말고는 시험이 운영과 같은 백엔드를 본다.
- 대가: Linux(CI, `Dockerfile` 이미지)에서 io_uring 을 잃는다. 그 차이는 재지 않았다.
- 코드에서 고정한다. `Eio_main.run` 을 `Eio_posix.run` 으로 바꾼다. `EIO_BACKEND` 같은 환경 변수로 고정하지 않는다(D3). 그 변수를 빠뜨린 실행은 기계에 따라 io_uring 으로 돈다.
- `Eio_main.run` 은 1,088개 파일에 3,435번 나온다. L2 가 바꾼다(D5).
- io_uring 으로 돌아가려면 Eio 가 두 effect 를 내보내거나, effect 가 fiber 를 바꾸는지 묻는 길을 열어야 한다.

### 운영자 결정 (2026-11-16)

| 번호 | 질문 | 결정 |
|---|---|---|
| D6 | Linux 에서 io_uring 을 잃더라도 Eio 백엔드를 posix 하나로 고정하는가 | 고정한다. 작성자가 추천한 안을 운영자가 받아들였다. |

## 2. 지금 모습

### 2.1 열다섯 번

이슈로 남은 일곱 건은 이슈, 이슈 댓글, 고친 PR 의 diff 에서 읽었다. 잠금이 backtrace 로 확인된 건은 #10682·#33322·#52360 셋이다. #24572 는 코드 감사로 짚었다. 나머지 셋은 추정이다.

| 닫힌 때 | 이슈 | 잠금 | 잠금 구역에서 멈춘 길 | 고친 PR | 처음 드러난 곳 |
|---|---|---|---|---|---|
| 2026-04 | #10567 | 확인 못 함. #10682 의 gate 로 추정 | 확인 못 함 | #10649 는 다른 잠금 여덟을 바꿨고, 배포 뒤 재발했다. #10861 은 EDEADLK 를 경고로 낮췄다. | 운영 로그 |
| 2026-04 | #10682 | `Worktree_live_context` 의 `single_flight_gate` | `Exec_gate.run_argv_with_status` → `Process_eio` → `Eio.Process.spawn`·`Eio.Process.await` | #10766: `Eio.Mutex` 로 바꿈 | 운영 로그 |
| 2026-07 | #24556 | 확인 못 함. `Keeper_lifecycle_reservation.with_key_lock` 으로 추정 | `File_lock_eio.with_mutex`(`Eio.Mutex`, `Fiber.yield`) → `Fs_compat.file_exists`(`Eio.Path.stat`) | #24657: `Cross_context_mutex` 를 새로 만들어 바꿈 | 운영. lane restart 가 막힘 |
| 2026-07 | #24572 | `Keeper_approval_queue` 의 `audit_io_mu`·`rules_mu`, memory bank 잠금 | `Fs_compat.mkdir_p`(`Eio.Path.mkdirs`), `Safe_ops` → `Fs_compat.load_file`(`Eio.Path.load`), `Fs_compat.save_file_atomic` | #24574: `Cross_context_mutex` 로 바꿈. memory bank 는 #26128 이 모듈째 지움 | 코드 감사 |
| 2026-08 | #24744 | 확인 못 함. #24556 과 같은 잠금으로 추정 | `File_lock_eio.with_mutex` → `Fs_compat.file_exists` | #24657 | 로컬 기동 |
| 2026-09 | #33322 | `Keeper_board_attention_candidate` 의 `ledger_mutex` | `Fs_compat.run_blocking_private_file_transaction` → `Eio_unix.run_in_systhread` | #33328: `Cross_context_mutex` 로 바꿈 | 운영. Keeper 넷이 턴을 하나씩 잃음 |
| 2026-11 | #52360 | `Keeper_efficiency` 의 `compute_mutex` | `Fs_compat.save_file_atomic` → `Atomic_replace.blocking_syscalls` → `Fs_compat.Systhread_host.run` | #52362: `Cross_context_mutex` 로 바꿈 | 운영. Dashboard 503 |

이슈 없이 고친 여덟 건은 PR 본문, 코드 주석, diff 에서 읽었다. 여덟 PR 은 모두 `Stdlib.Mutex` 를 쥔 채 fiber 가 멈춰서 난 EDEADLK 를 고쳤다.

| 병합 | PR | 잠금 | 잠금 구역에서 멈춘 일 | 고친 방법 |
|---|---|---|---|---|
| 2026-08-12 | #28391 | run registry 의 mutation lock | 영속 JSONL 쓰기 | `Cross_context_mutex` |
| 2026-08-12 | #28398 | `Exact_lane_run_registry` 의 자체 잠금 | 같은 쓰기 | `Cross_context_mutex` |
| 2026-10-27 | #46435 | `Activity_graph` 의 캐시 잠금 | 이벤트 파일 stat·읽기 | `Cross_context_mutex` |
| 2026-10-27 | #46440 | `Keeper_connector_names` 의 `directories_mu` | 파일 append | `Cross_context_mutex` |
| 2026-10-27 | #46441 | 승인 모드 저장소의 잠금 | `Fs_compat` 의 읽기·mkdir·교체 | `Cross_context_mutex`, `Atomic` |
| 2026-10-27 | #46446 | `Trajectory` 의 `round_counters_mu` | trajectory 파일 읽기 | 읽기를 잠금 밖으로 뺌 |
| 2026-10-27 | #46447 | `Tool_metrics_store` 의 `store_mu` | `Fs_compat.mkdir_p` | `Cross_context_mutex` |
| 2026-10-27 | #46448 | `Keeper_tool_call_log` 의 `file_change_cache_mu` | 날짜 파일마다 `Fs_compat.file_exists` | `Cross_context_mutex` |

열다섯 건에서 보이는 것:

- 운영을 멈춘 일이 있다. #28391 의 잠금은 2026-08-10 에 37번, 08-11 에 218번 EDEADLK 를 냈고, 그 가운데 하나가 서버를 내렸다(`lib/run_registry_core/run_registry_core.ml:436-450` 주석).
- 이슈 일곱 건에서 잠금 구역에 직접 쓴 `Eio.*`·`Eio_unix.*` 호출은 없었다. 멈춤은 masc 함수 안쪽에 있었다. 지난 masc 함수는 `Fs_compat`, `Safe_ops`, `File_lock_eio`, `Exec_gate`·`Process_eio`, `Systhread_host` 다.
- #24556·#24744·#24572 에서는 잠금 본문이 closure 로 잠금 helper 에 넘어갔다. `Mutex.protect` 자리에는 `f ()` 만 보인다.
- 이슈 일곱 건 가운데 고치기 전에 CI 시험이 잡은 건은 없다.
- 고친 방법은 거의 모두 잠금 종류를 바꾼 것이다. `Cross_context_mutex` 가 열한 번, `Eio.Mutex` 가 한 번이다. #26128 은 모듈을 지웠고, #46446 은 읽기를 잠금 밖으로 뺐다. #10861 은 EDEADLK 를 경고로 낮췄다.
- 같은 잠금이 두 종류 사이를 오갔다. #10649 가 `audit_io_mu`·`rules_mu` 를 `Eio.Mutex` 로 바꿨다. #15970·#18246 이 Eio 밖 호출자 때문에 `Stdlib.Mutex` 로 되돌렸다. 그 뒤 #24572 가 같은 자리를 짚었다.
- 2026-10-27 09:41~10:17 UTC 에 여섯 자리를 고쳤다. 2026-10-31 #46989 가 `Keeper_efficiency` 에 같은 모양을 새로 들였다. 그 자리가 #52360 이다.

### 2.2 리뷰와 시험이 놓치는 까닭

- 요청이나 작업이 겹쳐야 드러난다.
- 드러나는 모습이 둘이다.
  - 쥔 스레드가 다시 잡으면 `Sys_error "Mutex.lock: Resource deadlock avoided"` 가 난다.
  - 다른 도메인이 잡으려 하면 그 도메인의 스레드가 막힌다. 오류가 없어서 느려진 것으로만 보인다.
- 멈추는 자리가 잠금 구역에서 멀다. #52360 은 네 모듈을 건넜다.
  - `Keeper_efficiency.read_month` → `Fs_compat.save_file_atomic` → `Atomic_replace.save_file_atomic` → `Atomic_replace.blocking_syscalls` → `Fs_compat.Systhread_host.run`
- #52362 가 들어가기 전 `test/test_keeper_efficiency.ml` 은 `read_month` 를 18곳에서 불렀다. `Eio_main.run` 은 한 곳도 없었다. 시험은 모두 Eio 밖에서 돌았다.

### 2.3 자리 수

`706704b625a5` 의 `.ml` 에서 `rg` 로 셌다. `(*` 로 시작하는 줄과 `Eio.Mutex.` 가 든 줄은 뺐다. 문자열 안의 것은 거르지 않았다.

| 무엇 | 자리 | 파일 |
|---|---|---|
| `Stdlib.Mutex` 의 `lock`·`protect` (lib·bin) | 737 | 227 |
| 같은 것 (`packages/agent_core/lib`) | 30 | 10 |
| 그 가운데 `Mutex.lock` (lib·bin) | 89 | |
| `Mutex.try_lock` (lib·bin) | 6 | |
| `Condition.wait` (lib·bin) | 11 | 9 |
| `Cross_context_mutex` 의 `with_lock`·`with_durable_lock`·`try_with_lock` (lib·bin) | 66 | 29 |
| `Eio_guard.with_mutex`, `Eio.Mutex.use_ro`·`use_rw` (lib·bin) | 247 | |
| `Eio_unix.run_in_systhread` 직접 호출 (lib·bin, `systhread_host.ml` 밖) | 75 | |
| `Fs_compat.Systhread_host.run` 호출 (lib·bin, `systhread_host.ml` 밖) | 125 | |
| `Eio_main.run` (bin·lib·test·packages) | 3,435 | 1,088 |

`packages/agent_core/test` 의 2곳은 audit 범위 밖이다.
lib·bin·packages 에는 masc 가 직접 선언하거나 처리하는 effect 가 없다.

### 2.4 Eio 가 말하는 것

- `Eio.Mutex` 문서(`eio_mutex.mli`)는 잠금 구역이 막히는 일을 하면 `Eio.Mutex` 를 쓰라고 적는다. 짧게 쥐고 fiber 를 바꾸지 않을 때만 `Stdlib.Mutex` 가 더 빠를 수 있다고 적는다.
- Eio 에는 fiber 가 멈출 때 masc 가 부를 수 있는 hook 이 없다. `Eio.Private.Trace.suspend_fiber` 는 runtime events 에 기록만 남긴다(`trace.mli`).
- 멈춤은 effect 로 일어난다. `Suspend` 문서는 fiber 가 멈춰야 할 때 이 effect 를 낸다고 적는다(`eio__core.mli` 의 `Effects`). 백엔드와 `Eio_unix` 는 자기 effect(`Enter`, `Run_in_systhread`, `Await_readable` 등)로도 멈춘다.
- Eio 자신도 `Stdlib.Mutex` 를 쥔 채 `Suspend` 를 낸다. 그 mutex 는 스케줄러가 다음 fiber 를 돌리기 전에 callback 에서 풀린다(§1 D2).
- `Eio_mock` 은 `Suspend`, `Fork`, `Get_context` 만 처리한다(`eio/mock/backend.ml:74-98`). 그 아래에서 `Eio_unix` effect 는 `Effect.Unhandled` 로 끝난다. D2 가 Unhandled 로 돌아온 effect 를 「멈췄음」으로 치지 않는 까닭이다.

## 3. 왜 이 모양인가

D2 를 위해 견준 방법은 일곱이다.

| 방법 | 잡는 것 | 못 잡는 것과 대가 |
|---|---|---|
| A. 모든 잠금을 `Cross_context_mutex` 로 바꾼다 | 쥔 채 멈춰도 오류가 나지 않는다 | 잠금 안의 I/O 가 숨는다. 기다림이 길어져도 보이지 않는다. 기다림에 끝이 없다(#33588). Eio 문서는 짧은 잠금에 권하지 않는다. |
| B. typed tree 에서 잠금 구역 안의 멈춤을 찾는다 | 시험이 돌리지 않는 경로도 본다 | 함수 값과 여러 모듈을 건너는 호출을 따라가지 못한다. 이슈 일곱 건 가운데 셋은 본문이 closure 로 넘어갔다. |
| C. runtime events 에서 fiber 전환과 잠금을 대조한다 | Eio 의 모든 멈춤을 본다 | 링 버퍼가 넘치면 기록을 잃는다. 시험 실행마다 읽는 쪽이 따로 있어야 한다. 멈춘 뒤에야 안다. |
| D. masc 의 멈춤 함수 목록에서 잠금을 확인한다 | 목록에 든 함수를 지나는 경로 | 목록을 손으로 관리한다. 이슈 일곱 건이 지난 masc 함수만 다섯 갈래다. `Eio_unix.run_in_systhread` 직접 호출만 75곳이다. 빠뜨린 함수는 조용히 놓친다. `Systhread_host.run` 등 다섯 함수로는 #10682(`Process_eio`)를 놓친다. |
| E. 같은 스레드의 다른 fiber 가 쥔 동안 잡으려 하면 거절한다 | 겹칠 때 본다 | 예외가 쥔 fiber 가 아니라 잡으려던 fiber 에서 난다. 운영에서는 결함이 없는 요청이 실패한다. |
| F. 바꾸는 effect 를 그 자리에서 거절한다 | 멈추기 전에 실패한다. 다른 fiber 는 돌지 않는다 | Eio primitive 의 내부 mutex 가 잠긴 채 남는다. 시험에서 `Eio.Mutex` 하나가 그 뒤 계속 `Sys_error` 를 냈다(§1 D2). |
| G. effect 를 넘기며 기록하고, 구역이 끝날 때 실패한다 (이 RFC) | Eio 로 멈춘 모든 자리. 모듈을 몇 단계 건너도, closure 로 넘어가도 본다 | 결함 구역도 한 번은 멈춘다. 겹친 쪽은 지금처럼 실패한다. 멈춘 일이 같은 mutex 를 기다리면 예외 없이 멈춰 서고 기록만 남는다. 잠금마다 비용이 든다. 표가 Eio 판과 백엔드에 맞아야 한다(D6, §5). |

G 를 고른 까닭은 넷이다.

- 표가 masc 코드를 따라가지 않는다. 바꾸지 않는 effect 여덟만 Eio 판을 따라간다.
- 표가 모자라면 시끄럽게 실패한다. D 는 조용히 놓친다.
- 결함이 있는 fiber 에서 실패한다. E 처럼 다른 요청을 끌어들이지 않는다.
- Eio primitive 의 약속을 지킨다. F 는 결함이 없는 fiber 까지 망가뜨린다.

D4 를 두는 까닭이 있다. 2026-10-27 의 일괄 수정 나흘 뒤 같은 모양이 다시 들어왔다(§2.1).

- D4 뒤에는 새 잠금이 `Os_mutex` 와 `Cross_context_mutex` 가운데 하나다. `Stdlib.Mutex` 를 써서 D2 를 비켜 갈 수 없다.
- D4 가 결함을 직접 찾지는 않는다. `Os_mutex` 를 고른 자리가 쥔 채 멈추면, 그 경로를 Eio 안에서 지나는 첫 실행이 실패한다. 시험이 그 경로를 돌리지 않으면 운영의 첫 실행이 실패한다(§5).

## 4. 운영자에게 보이는 변화

- L1 뒤: `Systhread_host` 를 지나는 fiber 는 작업이 이미 끝났어도 한 번 멈춘다. 옮긴 잠금은 없다.
- L2 뒤: Linux 에서 masc 가 io_uring 대신 posix 로 돈다(D6).
- 옮긴 층 뒤: 그 층에 쥔 채 멈추는 자리가 남아 있으면, 그 경로를 지나는 요청과 작업이 매번 `Held_across_suspension` 으로 끝난다.
  - stderr 에 mutex 이름, effect 종류, 호출 스택 둘이 남는다.
  - 구역 안에서 한 일은 남는다.
  - `Held_across_suspension` 은 자동 재시도하지 않는다. 본문이 정상 종료했어도 나는 예외라서, 재시도하면 부작용이 두 번 적용될 수 있다.
- 마지막 층 뒤: `Stdlib.Mutex` 를 새로 부르는 PR 은 CI 에서 실패한다.

## 5. 한계와 열린 질문

- `Eio.Private` 는 이름대로 안정 약속이 아니다. Eio 를 올릴 때마다 §6.1 시험이 §1 D2 의 표를 다시 확인한다.
- 비용은 빈 본문으로만 쟀다. 같은 프로그램을 부하(load average 70~207)가 다른 때 여러 번 돌렸다. 100만 번을 다섯 번 재서 가운데 값을 적었다. 단위는 ns 다.

  | 경우 | `Mutex.protect` | 시험 `protect` |
  |---|---|---|
  | Eio 안 | 22~30 | 67~405 |
  | Eio 밖 | 19~30 | 49~277 |

  - 흔들림이 커서 자릿수도 정하지 못한다. 기록한 실행 하나는 부하를 적지 않았다.
  - L1 이 부하가 낮은 CI 에서 다시 잰다. masc 에서 자주 잠그는 길(로그 쓰기 등)로도 잰다. 그 값을 보고 L2 로 갈지 정한다.
  - Eio 밖을 가리는 방법은 L1 이 비용을 보고 고른다. 하나는 지금처럼 `Effect.Unhandled` 로 묻는 것이다. 다른 하나는 handler 를 늘 걸고, Unhandled 로 돌아온 effect 를 치지 않는 것이다.
- 기다릴 때만 멈추는 연산(`Eio.Mutex`·`Eio.Stream`)은 실제로 기다릴 때만 effect 를 낸다. 그런 자리는 겹칠 때만 드러난다(기록 7a·7b).
- 시험 단계에서 잡으려면 시험이 그 경로를 Eio 안에서 돌려야 한다. #52362 전 효율 시험은 Eio 밖에서만 돌았다(§2.2).
  - D1~D3 가 #46989 때 있었다면, 그 시험은 통과했을 것이다. 운영에서는 패널이 그 달을 처음 읽을 때 거의 늘 실패했을 것이다. 서버는 `read_month` 를 실행기 풀 worker 의 fiber 에서 돌린다. 그 fiber 의 캐시 쓰기는 `Systhread_host.run` 을 지나는데, 작업이 이미 끝났으면 멈추지 않는다. L1 뒤에는 늘 멈춘다.
  - 코드 경로로 따진 것이고 돌려 보지는 않았다.
- 멈춘 일이 같은 mutex 를 기다리는 구역은 예외 없이 멈춰 선다. 시험은 시간 제한으로만 끝난다. §6.1 의 시험 9 가 이 경우를 하위 프로세스로 돌려 stderr 기록을 확인한다.
- 취소로 끝난 구역은 실패하지 않는다. stderr 기록만 남는다. 같은 경로가 취소 없이 지날 때 실패한다.
- `Effect.Unhandled` 로 돌아온 effect 도 stderr 기록은 남긴다. 기록을 넘기기 전에 쓰기 때문이다. 그 구역은 끝에서 실패하지 않는다.
- `Os_mutex` 는 기록을 stderr 에 직접 쓴다. `masc_log` 도 `Os_mutex` 를 써야 하므로, `Os_mutex` 는 `masc_log` 에 기댈 수 없다.
- 잠금 구역 안의 막히는 시스템 호출(`Unix.read` 등)과 `Condition.wait` 는 fiber 를 바꾸지 않는다. 도메인을 막을 뿐이다. 다른 종류의 결함이라 이 RFC 범위 밖이다.
- 모듈 이름 `Os_mutex` 는 L1 에서 바꿀 수 있다.

## 6. 확인 방법

### 6.1 L1 시험

1~8 은 Eio fiber 에서 `Os_mutex.protect` 안에서 부른다.

1. `Fs_compat.Systhread_host.run`, `Eio.Path.stat`, `Eio.Fiber.yield`, `Eio.Process` 실행, `Eio_unix.run_in_systhread`, `Fiber.fork` 를 부른 구역은 모두 `Held_across_suspension` 으로 끝난다. 예외는 mutex 이름, effect 종류, 호출 스택 둘을 싣는다. 부른 쪽 스택에 `protect` 가 있다.
2. `Eio.Fiber.check`, 단조 시계 읽기, `Eio_unix.pipe` 만 부른 구역은 끝까지 돈다.
3. 본문이 예외로 끝나도 표시가 있으면 `Held_across_suspension` 으로 끝나고, 본문 예외와 그 backtrace 를 싣는다.
4. 실패 뒤 다음 `protect` 가 기다리지 않고 잡는다.
5. 다른 fiber 가 쥔 `Eio.Mutex` 를 잡으려던 구역, 용량이 1 이상인 빈 `Eio.Stream` 에서 꺼내려던 구역은 실패한다. 그 `Eio.Mutex` 와 `Eio.Stream` 은 그 뒤에도 쓸 수 있다.
6. `Fiber.first` 의 진 쪽이 구역 안에서 멈춰 있다가 취소되면, `Fiber.first` 는 이긴 쪽 값을 돌려준다. `Switch.fail` 로 멈춘 구역을 취소하면 switch 는 원래 실패만 전하고 `Held_across_suspension` 을 섞지 않는다. 두 경우 모두 기록은 stderr 에 있고 mutex 는 풀려 있다. 시험 기록의 경우 10 은 취소 보존 갈래를 넣기 전 결과이며 이 규칙의 성공 증거가 아니다.
7. `Cross_context_mutex.with_lock` 안에서는 1 의 호출이 끝까지 돈다.
8. 변이 시험: #52362 전 `read_month` 의 잠금을 `Os_mutex` 로 바꾸고 fiber 하나에서 부른다. 겹침 없이, 돌릴 때마다 실패해야 한다.
9. 시스템 스레드 작업이 같은 mutex 를 잡는 구역을 하위 프로세스에서 돌린다. 시간 제한이 지나면 부모가 하위 프로세스를 끝내고, stderr 에 그 mutex 의 기록이 있는지 본다.
10. Eio 밖에서는 `Fs_compat.Systhread_host.run` 을 부른 구역이 끝까지 돌고, `Fs_compat.Execution_context.current` 가 `Non_eio` 를 돌려준다.
11. 1~10 을 macOS 와 Linux CI 에서 posix 백엔드로 돌린다(D6).
12. Eio 안과 밖의 빈 본문, 잠금이 많은 masc 경로 하나에서 `Stdlib.Mutex` 와 `Os_mutex` 의 시간을 CI 에서 견준다.

### 6.2 옮기는 층

- 층마다 CI 전체를 통과한다.
- 실패한 자리를 고친 커밋은 mutex 이름을 적는다.
- `Held_across_suspension` 을 재시도 래퍼로 감싸지 않는다. 잠금 종류를 바꾸거나 멈추는 일을 잠금 밖으로 뺀다.
- 옮길 라이브러리마다 `masc.agent_core.os_mutex` 의존성을 순환 없이 더할 수 있는지 확인한다.

### 6.3 마지막 층

- audit 단위 시험: 두 모듈 밖의 `Stdlib.Mutex` 를 잡는다. 직접 부른 이름, 별칭, `include`, 값으로 쓴 이름을 모두 본다.
- main 에서 audit 를 돌리면 0곳이다.

### 6.4 배포 뒤

- 서버 stderr 의 기록과 `Held_across_suspension` 을 센다. 나오면 그 mutex 이름으로 이슈를 연다.

## 7. 하지 않는 것

- 한 자리씩 손으로 고치기. 열다섯 번 그렇게 했다.
- masc 함수에 잠금 확인을 하나씩 넣기(§3 D).
- 바꾸는 effect 를 그 자리에서 거절하기(§3 F).
- 기록만 남기고 계속 돌기. 취소된 구역만 예외다(D2).
- 시험에서만 켜는 모드나 환경 변수.
- 기존 767곳을 기준선 파일로 남겨 두기.
- 모든 잠금을 `Cross_context_mutex` 로 바꾸기(§3 A).
- io_uring 에서 거짓 실패를 피하려고 effect 이름을 문자열로 가리기.
- 잠금 구역 안의 막히는 시스템 호출과 `Condition.wait` 고치기(§5).

## 8. 층

RFC 가 Draft 일 때 native stack 으로 묶는다. 층마다 자기 changelog 조각을 넣는다.

| 층 | 내용 | 확인 |
|---|---|---|
| L0 | 이 RFC 와 시험 기록 | `python3 scripts/rfc-generate-index.py --check` |
| L1 | `Os_mutex`, `Systhread_host.await` 빠른 길 지우기, 비용 측정 | §6.1 |
| L2 | posix 고정(D6): `Eio_main.run` 을 `Eio_posix.run` 으로 | 층마다 CI 전체 |
| L3 부터 | 잠금을 디렉터리 단위로 옮기기 | 층마다 CI 전체 (§6.2) |
| 마지막 | audit 분류와 별칭·값 이름 잡기, `pr-type-check.yml` 연결 | §6.3 |
