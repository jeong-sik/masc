---
name: ocaml-coding
description: "masc 저장소에서 OCaml 5.5 + Eio 코드를 쓰기 전에 보는 점검표다. 오류를 Result 와 닫힌 합타입으로 다루는 법, 예외 잡기와 Eio 취소, Mutex·Lazy 선택, 자원 정리(Switch.on_release 와 Fun.protect), 막히는 I/O, .mli 먼저 고치기, 결정론 게이트와 CI lint 가 새 줄에서 잡는 모양을 다룬다. lib/·bin/·test/ 의 .ml/.mli 를 새로 쓰거나 고칠 때 쓴다."
---

# masc OCaml 점검표

이 저장소는 OCaml 5.5 에 고정돼 있다(`dune-project` 의 `(ocaml (= 5.5.1))`).
표준 라이브러리와 Eio 의 사실은 공식 인터페이스로 확인한다.

- OCaml 매뉴얼: https://ocaml.org/manual/5.5/index.html
- API: `https://ocaml.org/manual/5.5/api/<Module>.html`
- Eio: opam 스위치의 `lib/eio/*.mli`, 또는 https://ocaml.org/p/eio/latest/doc/Eio/index.html

규칙의 원본은 `docs/constitution.xml` 이다. 이 문서와 헌법이 다르면 헌법이 맞다.

## 1. 상태와 오류는 닫힌 합타입

- 서로 배타적인 상태·판정·오류는 variant 로 쓴다. 문자열이나 부분 문자열을 비교해 다음 동작을
  고르지 않는다(헌법 `string_matching`). `String.starts_with ~prefix:"..."` 로 분기하고 싶어지면
  그 값을 만드는 쪽에 생성자를 하나 더 둔다.
- 파서는 모르는 입력에 `None` 이나 `Error` 를 준다. 편한 기본값으로 눌러 담지 않는다.
- `match` 는 경우를 다 적는다. 새 생성자를 넣었을 때 컴파일러가 빠진 자리를 알려 주게 한다.
  상태 전이표에 `| _ -> false` 를 두면 새 상태의 전이가 빠져도 컴파일된다.
- 실패할 수 있는 계산은 `Result` 로 돌려준다.

  ```ocaml
  let ( let* ) = Result.bind

  let process input =
    let* parsed = parse input in
    let* computed = compute parsed in
    Ok (render computed)
  ```

- `failwith "not implemented"` 같은 자리 채움을 두지 않는다. 컴파일은 되고 실행하면 터진다.
- `assert false` 는 타입으로 막을 수 없는, 정말 도달하지 않는 가지에만 둔다.
- `option` 의 `None` 이 무엇을 뜻하는지 `.mli` 문서 주석에 적는다.

## 2. 예외 잡기와 Eio 취소

Eio 는 취소를 `Eio.Cancel.Cancelled` 예외로 전한다. 모든 예외를 잡는 가지는 이 취소까지 삼킨다.
삼킨 fiber 는 멈추라는 요청을 받고도 계속 돈다.

- 잡을 예외의 생성자를 적는다.

  ```ocaml
  match Eio.Path.load path with
  | contents -> Ok contents
  | exception (Eio.Io _ as ex) -> Error (Format.asprintf "%a" Eio.Exn.pp ex)
  ```

- 전부 잡아야 하면 취소를 먼저 다시 던진다.

  ```ocaml
  match run () with
  | value -> Ok value
  | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
  | exception ex -> Error (Printexc.to_string ex)
  ```

- `lib/` 에서 CI 가 잡는 모양:
  - `scripts/lint-cancel-guard.sh`: `with _ ->`, `with <이름> ->`, `| exception _ ->` 는 바로 위 세 줄
    안에 `Eio.Cancel.Cancelled` 가 있거나, 여덟 줄 안에서 그 이름을 다시 `raise` 해야 한다.
    예외 표시 `cancel-guard-ok: <이유>` 는 개수 상한이 있다.
  - `scripts/ci/check-silent-failure-patterns.sh`: `try ignore (...)`, 앞줄에 로그 없는 `| _ -> ()`.
  - `scripts/ci/check-wildcard-only-match.py`: 모든 가지가 `_` 뿐인 `match`.

## 3. 결정론 게이트

`scripts/ci/check-determinism-contract.sh` 는 `origin/main...HEAD` 의 `lib/` diff 에서 **새로 추가된**
줄 중 아래 모양을 실패로 잡는다. 위아래 두 줄 안에 `DET-OK:` 나 `NDT-OK:` 이유 주석이 있으면 넘어간다.

| 모양 | 대신 |
|---|---|
| `Option.value opt ~default:x` | `match opt with Some v -> v \| None -> x` |
| `\| _ -> Some ...` | 생성자마다 가지를 적는다 |
| `Unix.gettimeofday`, `Random.`, `Unix.times`, `Sys.time`, `Unix.getpid` | 경계에서 한 번 읽어 인자로 넘긴다 |

- 게이트는 **커밋된 HEAD** 를 비교한다. 파일만 고치고 돌리면 옛 커밋의 줄을 본다. 커밋한 뒤 돌린다.
- 실패 보고에 남의 파일 줄이 같이 찍혀도, 이 PR 의 실패는 `origin/main...HEAD:` 뒤에 적힌 줄이다.
- 들여쓰기만 바뀌어 옮겨진 줄은 새 줄로 치지 않는다.

## 4. Mutex 고르기

Eio 인터페이스(`eio_mutex.mli`)가 말하는 차이: `Stdlib.Mutex` 는 기다리는 동안 도메인 전체를 막고,
`Eio.Mutex` 는 기다리는 동안 다른 fiber 를 돌린다.

| 상황 | 선택 |
|---|---|
| 잠근 구간에서 I/O 를 하거나 fiber 가 바뀔 수 있다 | `Eio.Mutex` |
| 잠근 구간이 짧고 fiber 가 바뀌지 않는다 | `Stdlib.Mutex` |
| 모듈 초기화처럼 Eio 문맥 밖에서 잡힌다 | `Stdlib.Mutex` |
| `Eio_main.run` 없이 테스트에서 불린다 | `Stdlib.Mutex` |

- `Eio.Mutex.use_rw ~protect t fn`: `fn` 이 예외를 내면 mutex 가 못 쓰게 된다(`Poisoned`).
  `~protect:true` 는 잠근 구간을 취소에서 보호한다. 잠금을 기다리는 동안은 보호하지 않는다.
- `Eio.Mutex.use_ro t fn`: 읽기만 할 때. 예외가 나도 풀고 넘어간다.
- 한 도메인 안에서만 도는 코드는 막히는 연산을 하기 전에는 fiber 가 바뀌지 않는다. mutex 가 필요 없을 수 있다.
- mutex 로 감싸는 방식을 바꾸면 `rg -n '<함수 이름>' test/` 로 테스트 호출을 전부 센다.
  `Eio_main.run` 밖에서 부르는 테스트가 있으면 같이 고친다.

## 5. Lazy 고르기

- `Stdlib.Lazy.force` 는 동시에 안전하지 않다. 여러 fiber·systhread·도메인이 한 값을 동시에
  force 하면 `Lazy.Undefined` 가 날 수 있다(`lazy.mli`).
- Eio fiber 여럿이 force 하는 값은 `Eio.Lazy.from_fun ~cancel fn`.
  - `` `Restart ``: force 하던 fiber 가 취소되면 기다리던 다음 fiber 가 `fn` 을 다시 돌린다.
  - `` `Record ``: 취소를 기록하고 그 뒤로는 계속 취소로 답한다.
  - `` `Protect ``: force 하는 동안 취소를 막는다.
- 여러 도메인·systhread 가 쓰지만 Eio 밖인 값은 `Lazy.Mutexed`(5.5 부터). 내부에서 `Stdlib.Mutex` 로
  기다리므로 Eio fiber 에서 쓰면 도메인을 막는다.
- 테스트나 모듈 초기화에서만 force 되는 값은 `Stdlib.Lazy` 로 두고, 왜 괜찮은지 주석을 단다.

## 6. 자원 정리

```ocaml
Eio.Switch.run @@ fun sw ->
let flow = open_flow ~sw in
Eio.Switch.on_release sw (fun () -> Eio.Flow.close flow);
use flow
```

- `Switch.on_release` 의 정리 함수는 `Cancel.protect` 안에서 돈다. 스위치가 이미 취소됐어도
  정리가 끊기지 않는다. 등록 역순으로 하나씩 돌고, 정리 함수의 예외는 스위치 실패로 넘어간다.
- `Fun.protect ~finally work`: `finally` 가 예외를 내면 `Fun.Finally_raised` 로 바뀌고 `work` 의 원래
  예외는 사라진다(`fun.mli`). 취소된 fiber 의 `finally` 에서 취소될 수 있는 Eio 연산을 부르면 그 연산이
  다시 `Cancelled` 를 내고, 원래 오류가 묻힌다.
- 그래서 `lib/` 에서 `Fun.protect` 의 `~finally:` 안에 `Eio.`·`Fiber.`·`Promise.await`·
  `Stream.take/add/close`·`Condition.await`·`Mutex.lock/use_/with_` 를 새로 쓰면
  `scripts/ci/check-fun-protect-finally-guard.py` 가 실패시킨다. 막히거나 fiber 를 바꾸는 정리는
  `Switch.on_release` 로 옮긴다. 순수 동기 정리(`close_in ic` 등)만 `Fun.protect` 에 둔다.

## 7. 막히는 I/O 와 무거운 계산

Eio 는 협력형 스케줄러다. 취소와 시간 초과는 fiber 가 멈추는 지점에서만 먹힌다.

- `Eio.Time.with_timeout clock d fn` 은 `fn` 을 `d` 초 뒤 취소한다. `fn` 이 `Sys.readdir`,
  `Unix.read`, CPU 루프처럼 Eio 로 양보하지 않으면 끝날 때까지 안 끊긴다.
- Keeper 런타임과 제품 흐름에는 없어도 되는 시간 초과를 두지 않는다(헌법 `budget_gate`).
  시간 초과를 넣기 전에 그 대기가 끝나지 않는 경우가 실제로 무엇인지부터 적는다.
- 막히는 표준 라이브러리 호출: `Eio_unix.run_in_systhread (fun () -> ...)`
- 파일: `Eio.Path` (Eio 로 양보한다)
- 무거운 순수 계산: `Eio.Executor_pool.submit_exn pool ~weight (fun () -> ...)`
- HTTP 핸들러 안에서 무거운 계산을 직접 하지 않는다. 핸들러가 멈추면 같은 도메인의 다른 요청도 멈춘다.
  대시보드 스냅샷처럼 뒤에서 미리 계산해 두고 핸들러는 마지막 값만 읽게 한다. 계산 실패는 삼키지
  않고 알린 뒤 마지막 값을 유지한다.

  ```ocaml
  let start_refresh ~sw ~clock ~interval ~compute ~on_error latest =
    Eio.Fiber.fork ~sw (fun () ->
        let rec loop () =
          (match compute () with
           | Ok snapshot -> latest := Some snapshot
           | Error err -> on_error err);
          Eio.Time.sleep clock interval;
          loop ()
        in
        loop ())
  ```

  `compute` 가 예외 대신 `Result` 를 돌려주게 만든다. 여기서 `try ... with _ -> ()` 로 감싸면
  계산 실패도 취소도 조용히 사라진다(2절).

## 8. API 를 바꿀 때는 .mli 먼저

- `.mli` 가 있으면 `.mli` 를 먼저 고치고 `.ml` 을 맞춘다. `.ml` 에만 인자를 더하면 인터페이스와
  안 맞아 컴파일이 실패한다.
- 레코드 필드를 늘리면 그 레코드를 만드는 자리를 `rg -c` 로 전부 세고 모두 고친다.
  `type t = Other.t = { ... }` 로 다시 적은 `.ml`/`.mli` 짝도 같이 고친다.
- 선택 인자 뒤에 위치 인자가 없으면 `()` 를 받는다. 없으면 경고 16(지울 수 없는 선택 인자)이다.

  ```ocaml
  let submit ~title ?(refs = []) () = ...
  ```

- 루트 `dune` 이 모든 프로파일에 `-w +32+69 -warn-error +a` 를 건다. 안 쓰는 값(32)과 안 읽는
  레코드 필드(69)도 오류다. 값이나 필드의 마지막 사용처를 지웠으면 그 값·필드도 같은 커밋에서 지운다.

## 9. 표준 라이브러리 — 있을 거라고 착각하기 쉬운 것

다른 언어의 짝을 떠올려 호출을 지어내기 쉽다. 헷갈리면 5.5 API 문서를 먼저 연다.

| 호출 | 5.5 에서 | 비고 |
|---|---|---|
| `Unix.unsetenv` | 있다 (5.5 부터) | 이 저장소 테스트가 이미 쓴다 |
| `Sys.unsetenv` | 없다 | `Unix.unsetenv` 를 쓴다 |
| `Unix.putenv k ""` | 있다 | 지우는 게 아니다. `Sys.getenv_opt k` 는 `Some ""` 을 준다 |
| `List.take` / `List.drop` | 있다 (5.3 부터) | 음수면 `Invalid_argument` |
| `String.starts_with ~prefix` | 있다 (4.13 부터) | 분기 판단에 쓰지 않는다(1절) |
| `Option.get_or` | 없다 | `match` 로 쓴다(3절) |
| `Lazy.Mutexed` | 있다 (5.5 부터) | 5절 |

같은 함수에서 "Unbound value" 가 두 번 나오면 그 함수가 있는지부터 의심하고 인터페이스를 연다.

## 쓰고 나서 훑어보기

```sh
rg -n 'with _ ->|\| exception _ ->|with [a-z_]+ ->' <file>   # 2절
rg -n 'Option\.value.*~default:|\| *_ *-> *Some' <file>       # 3절
rg -n 'Fun\.protect' <file>                                    # 6절: finally 안에 Eio 연산이 있나
rg -n 'Stdlib\.Lazy|lazy \(' <file>                            # 5절: 여러 fiber 가 force 하나
rg -n 'failwith|assert false' <file>                           # 1절
rg -n 'Sys\.readdir|Unix\.(read|write|sleep)' <file>           # 7절: Eio 문맥에서 막히나
```
