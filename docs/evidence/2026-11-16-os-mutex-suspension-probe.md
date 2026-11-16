# OS mutex 를 쥔 채 멈추는 fiber — effect handler 시험 (2026-11-16)

[RFC a-fiber-that-suspends-while-holding-an-os-mutex-fails-at-unlock](../rfc/RFC-a-fiber-that-suspends-while-holding-an-os-mutex-fails-at-unlock.md) 의 D2 를 고르려고 돌린 시험이다.
masc 코드는 빌드하지도 돌리지도 않았다.

## 환경

- macOS (Darwin 27.2.0, arm64), 한 장비.
- OCaml 5.5.2, eio 1.3, eio_main 1.3. `Eio_main.run` 은 eio_posix 1.3 을 골랐다.
- eio_linux 는 설치돼 있지 않다. Linux 에서는 돌리지 않았다.

## 견준 handler 둘

시험 프로그램은 `Stdlib.Mutex` 를 잡고, Eio fiber 안이면 본문을 `Effect.Deep` handler 안에서 돌린다.

- `discontinue`: fiber 를 바꾸는 effect 를 낸 자리에서 `Effect.Deep.discontinue` 로 거절한다.
- `record`: effect 를 모두 Eio 로 넘긴다. fiber 를 바꾸는 첫 effect 의 호출 스택을 기록하고, 본문이 끝나면 예외로 끝난다.

fiber 를 바꾸지 않는다고 보는 effect 는 여덟이다.
`Get_context`, `Get_monotonic_clock`, `Pipe`, `Import_socket_stream`·`_listening`·`_datagram`, `Socketpair_stream`·`_datagram` 이다.
나머지 effect 와 모르는 effect 는 모두 바꾼다고 본다.

## 돌리는 법

빈 디렉터리에 아래 세 파일을 둔다.

- `dune-project`: `(lang dune 3.0)`
- `dune`: `(executable (name proto) (libraries eio_main eio.unix threads.posix unix))`
- `proto.ml`: 이 문서 맨 아래 프로그램

```sh
dune build --root . ./proto.exe
./_build/default/proto.exe discontinue
./_build/default/proto.exe record
```

## 결과

아래 표와 「다시 돌린 결과」는 취소 보존 갈래를 넣기 전 프로그램의 실행 기록이다.
경우 10 의 `record` 는 취소를 `Held_across_suspension` 으로 바꿨으므로 RFC D2 의 취소 규칙을 입증하지 않는다.
문서 끝 재현 프로그램에는 리뷰 대응으로 취소를 그대로 다시 던지는 갈래를 더했다. 이 수정본은 다시 실행하지 않았고, 아래 관측값을 수정본의 결과로 바꾸어 쓰지 않는다.
구현 층의 `test_os_mutex` 는 `Fiber.first` 와 `Switch.fail` 로 취소된 구역에 대해 원래 결과·stderr 기록·잠금 해제를 확인하도록 한다.

두 실행 모두 끝 코드 0 으로 끝났다.

| 경우 | discontinue | record |
|---|---|---|
| 0 outside Eio: run_in_systhread stays unhandled | ran to the end | ran to the end |
| 1a Fiber.yield | Held_across_suspension m | Held_across_suspension m |
| 1b Eio_unix.run_in_systhread | Held_across_suspension m | Held_across_suspension m |
| 1c Eio.Path.stat | Held_across_suspension m | Held_across_suspension m |
| 1d Eio.Process.run true | Held_across_suspension m | Held_across_suspension m |
| 1e Eio.Time.sleep 0 | Held_across_suspension m | Held_across_suspension m |
| 2a Fiber.check | ran to the end | ran to the end |
| 2b Eio_unix.pipe | ran to the end | ran to the end |
| 2c Eio.Time.Mono.now | ran to the end | ran to the end |
| 3 Fiber.fork inside | Held_across_suspension m | Held_across_suspension m |
| 3b the same switch forks and finishes afterwards | ran to the end | ran to the end |
| 4 body catches Held_across_suspension itself | Held_across_suspension m | Held_across_suspension m |
| 5 next protect after a failure takes the mutex | ran to the end | ran to the end |
| 7a free Eio.Mutex inside | ran to the end | ran to the end |
| 7b Eio.Mutex held by another fiber | other exception: Multiple exceptions: Dune__exe__Proto.Held_across_suspension("m", 0); Sys_error("Mutex.lock: Resource deadlock avoided") | Held_across_suspension m |
| 8 the same Eio.Mutex afterwards, no OS mutex | other exception: Sys_error("Mutex.lock: Resource deadlock avoided") | ran to the end |
| 9 body raises its own exception after a suspension | Held_across_suspension m | Held_across_suspension m (body raised Failure("body")) |
| 10 switch fails while the section is suspended | other exception: Multiple exceptions: Dune__exe__Proto.Held_across_suspension("m", 0); Failure("stop") | other exception: Multiple exceptions: Failure("stop"); Dune__exe__Proto.Held_across_suspension("m", _) |

`discontinue` 의 7b·8 이 갈림길이다.
`Eio.Mutex.lock` 은 내부 `Stdlib.Mutex` 를 잡은 채 `Suspend` 를 내고, 스케줄러가 부르는 callback 에서 푼다(`eio/eio_mutex.ml:54-59`, `eio/waiters.ml:41-66`).
`discontinue` 는 그 callback 이 돌지 않게 한다. 내부 mutex 가 잠긴 채 남는다.
8 은 시험 mutex 없이 같은 `Eio.Mutex` 만 썼는데도 `Sys_error` 로 실패했다.

`record` 가 1c 에서 남긴 기록이다. 맨 아래 줄이 잠금 구역 안의 호출이다.

```text
--- m: first suspension recorded at
Raised by primitive operation at Eio_unix__Thread_pool.run_in_systhread in file "lib_eio/unix/thread_pool.ml", line 124, characters 13-49
Called from Eio_posix__Err.run in file "lib_eio_posix/err.ml", line 28, characters 6-10
Called from Eio_posix__Fs.Dir.stat in file "lib_eio_posix/fs.ml", line 82, characters 4-54
Called from Eio__Path.stat in file "lib_eio/path.ml", line 112, characters 6-29
Called from Dune__exe__Proto.(fun) in file "proto.ml", line 146, characters 36-87
```

## 비용

빈 본문을 100만 번 돌리는 일을 다섯 번 재고 가운데 값을 적었다. 단위는 ns/op 이다.
멈춤이 없으면 두 handler 가 하는 일은 거의 같다. 그래서 두 실행을 같은 경로의 두 번 잼으로 읽는다.

| 무엇 | discontinue 실행 | record 실행 |
|---|---|---|
| outside Eio: Mutex.protect | 23 | 23 |
| outside Eio: probe protect | 142 | 277 |
| in Eio: Mutex.protect | 27 | 26 |
| in Eio: probe protect | 405 | 271 |
| in Eio: Mutex.protect, body calls Fiber.check | 321 | 271 |
| in Eio: probe protect, body calls Fiber.check | 659 | 1016 |

같은 경로가 실행마다 두 배 가까이 흔들렸다. 아래 「다시 돌린 결과」에서는 자릿수도 달랐다. 이 표로는 비용을 정하지 못한다.

## 다시 돌린 결과

새 맥락 검토 에이전트(Claude Opus 5.5)가 같은 장비에서 아래 프로그램을 글자 그대로 다시 빌드해 돌렸다.

- `record` 의 18줄은 모두 같았다. `discontinue` 의 7b·8·10 도 같았다.
- `discontinue` 의 1d 는 일곱 번 모두 `Multiple exceptions: Held_across_suspension; Held_across_suspension` 이었다. 위 표의 첫 실행은 하나였다.
- 비용은 부하를 따라 움직였다. Eio 안 빈 본문 `protect` 는 load average 70~135 에서 67·74ns, 200 안팎에서 103·214ns 였다. Eio 안 `Mutex.protect` 는 22~30ns 였다. Eio 밖 `protect` 는 49~195ns, `Mutex.protect` 는 19~30ns 였다. 위 표의 첫 실행은 부하를 적지 않았다.

`record` 기록 12개 가운데 넷은 비었고, 다섯은 Eio 함수만 담았고, 셋이 `proto.ml` 에 닿았다. 꼬리 호출이 프레임을 지운다.
handler 는 `protect` 를 부른 쪽 스택 위에서 돈다. 그래서 handler 안에서 `Printexc.get_callstack` 을 부르면 그쪽 스택이 잡힌다.
`recording` 의 기록 줄을 아래처럼 바꿔 다시 돌렸다(load average 207·197·179).

```ocaml
first := Some (Printexc.raw_backtrace_to_string (Effect.Deep.get_callstack k 6)
               ^ "  -- caller side (handler runs on the parent stack):\n"
               ^ Printexc.raw_backtrace_to_string (Printexc.get_callstack 8));
```

1e(`Eio.Time.sleep`)는 effect 를 낸 쪽이 비었고, 부른 쪽에 `protect` 와 그 경우의 줄이 잡혔다. 줄 번호는 바꾼 프로그램 기준이다.

```text
  -- caller side (handler runs on the parent stack):
Raised by primitive operation at Dune__exe__Proto.recording.(fun) in file "proto.ml", line 76, characters 68-94
Called from Dune__exe__Proto.protect in file "proto.ml", line 89, characters 18-34
Called from Dune__exe__Proto.case in file "proto.ml", line 100, characters 10-14
Called from Dune__exe__Proto.(fun) in file "proto.ml", line 151, characters 2-91
```

## audit 식별자

RFC D4 는 `Stdlib.Mutex` 를 경로 이름이 아니라 값의 선언 식별자(`val_uid`)로 가린다.
`include` 로 들여온 값도 그 식별자를 지니는지 OCaml 5.5.2 에서 확인했다.

`t.ml` 은 한 파일 안의 경우다.

```ocaml
module L = struct include Mutex end
module M = Mutex
let a = L.lock
let b = M.lock
let c = Mutex.lock
let d = Stdlib.Mutex.lock
```

`u.ml` 과 `v.ml` 은 컴파일 단위를 건너는 경우다.

```ocaml
(* u.ml *)
module L = struct include Mutex end
(* v.ml *)
let a = U.L.lock
open U.L
let b = protect
```

`ocamlc -bin-annot -c` 로 컴파일하고, 아래 프로그램으로 `.cmt` 의 값 이름마다 식별자를 찍었다.
dune 파일은 `(executable (name reader) (modules reader) (libraries compiler-libs.common))` 이다.

```ocaml
(* Prints, for every value identifier in a .cmt, its path, the uid of the
   value description the typer resolved, and that description's location.
   Checks whether `include Mutex` keeps the Stdlib__Mutex uid. *)
let () =
  let cmt = Cmt_format.read_cmt Sys.argv.(1) in
  match cmt.cmt_annots with
  | Cmt_format.Implementation str ->
    let expr (sub : Tast_iterator.iterator) (e : Typedtree.expression) =
      (match e.exp_desc with
       | Typedtree.Texp_ident (path, _, vd) ->
         Format.printf "%-20s uid=%a loc=%a@." (Path.name path) Shape.Uid.print
           vd.Types.val_uid Location.print_loc vd.Types.val_loc
       | _ -> ());
      Tast_iterator.default_iterator.expr sub e
    in
    let it = { Tast_iterator.default_iterator with expr } in
    it.structure it str
  | _ -> prerr_endline "not an implementation"
```

결과:

```text
L.lock               uid=[intf]Stdlib__Mutex.2 loc=File "mutex.mli", line 35, characters 0-20
M.lock               uid=[intf]Stdlib__Mutex.2 loc=File "mutex.mli", line 35, characters 0-20
Stdlib.Mutex.lock    uid=[intf]Stdlib__Mutex.2 loc=File "mutex.mli", line 35, characters 0-20
Stdlib.Mutex.lock    uid=[intf]Stdlib__Mutex.2 loc=File "mutex.mli", line 35, characters 0-20
U.L.lock             uid=[intf]Stdlib__Mutex.2 loc=File "mutex.mli", line 35, characters 0-20
U.L.protect          uid=[intf]Stdlib__Mutex.5 loc=File "mutex.mli", line 62, characters 0-37
```

- 경로 이름은 `L.lock`, `M.lock`, `U.L.lock`, `U.L.protect` 로 저마다 다르다. 지금 audit 도구는 이 넷을 `Stdlib.Mutex` 로 알아보지 못한다.
- 식별자는 모두 `Stdlib__Mutex` 단위를 가리킨다.

## 확인하지 못한 것

- eio_linux 와 Linux. eio_linux 소스는 읽었지만 돌리지 않았다.
- masc 코드와 masc 의 실제 경로 비용.
- 여러 도메인이 같은 mutex 를 잡는 경우.

## 프로그램

현재 재현용 수정본이다. 위 표를 낸 원본과 달리 `recording.finish` 는 취소를 기록한 뒤 `Held_across_suspension` 을 만들지 않고, `exnc` 가 원래 취소와 backtrace 를 다시 던진다. 수정 뒤 실행 결과는 아직 없다.

```ocaml
(* Probe for the RFC "a fiber that suspends while holding an OS mutex fails at
   unlock". Not masc code. Runs a Stdlib.Mutex critical section under an
   Effect.Deep handler inside Eio and prints what each body does.

   Usage: proto.exe discontinue | proto.exe record
   - discontinue: refuse a fiber-switching effect where it is performed.
   - record: forward every effect, remember the first fiber-switching one,
     fail when the critical section ends. *)

exception Held_across_suspension of { mutex : string; body_raised : exn option }

type mode = Discontinue | Record

let in_eio () =
  match Effect.perform Eio.Private.Effects.Get_context with
  | (_ : Eio.Private.Fiber_context.t) -> true
  | exception Effect.Unhandled _ -> false

(* Effects that Eio 1.3 with eio_posix answers without switching fibers.
   Effect.t is an open type, so an unknown effect counts as switching. *)
let switches (type a) (eff : a Effect.t) =
  match eff with
  | Eio.Private.Effects.Get_context -> false
  | Eio_unix.Private.Get_monotonic_clock -> false
  | Eio_unix.Private.Pipe _ -> false
  | Eio_unix.Net.Import_socket_stream _ -> false
  | Eio_unix.Net.Import_socket_listening _ -> false
  | Eio_unix.Net.Import_socket_datagram _ -> false
  | Eio_unix.Net.Socketpair_stream _ -> false
  | Eio_unix.Net.Socketpair_datagram _ -> false
  | _ -> true

let discontinuing name f =
  let refused = ref false in
  Effect.Deep.match_with f ()
    { retc =
        (fun v ->
          if !refused then raise (Held_across_suspension { mutex = name; body_raised = None });
          v)
    ; exnc = raise
    ; effc =
        (fun (type c) (eff : c Effect.t) ->
          if not (switches eff) then None
          else
            Some
              (fun (k : (c, _) Effect.Deep.continuation) ->
                (match eff with
                 | Eio.Private.Effects.Fork (ctx, _) -> Eio.Private.Fiber_context.destroy ctx
                 | _ -> ());
                refused := true;
                Effect.Deep.discontinue k
                  (Held_across_suspension { mutex = name; body_raised = None })))
    }

let recording name f =
  let first = ref None in
  let finish body_raised =
    match !first with
    | None -> ()
    | Some stack ->
      Printf.eprintf "--- %s: first suspension recorded at\n%s%!" name stack;
      (match body_raised with
       | Some (Eio.Cancel.Cancelled _) -> ()
       | None | Some _ ->
         raise (Held_across_suspension { mutex = name; body_raised }))
  in
  Effect.Deep.match_with f ()
    { retc = (fun v -> finish None; v)
    ; exnc = (fun e ->
        let backtrace = Printexc.get_raw_backtrace () in
        finish (Some e);
        Printexc.raise_with_backtrace e backtrace)
    ; effc =
        (fun (type c) (eff : c Effect.t) ->
          if not (switches eff) then None
          else
            Some
              (fun (k : (c, _) Effect.Deep.continuation) ->
                if Option.is_none !first then
                  first := Some (Printexc.raw_backtrace_to_string (Effect.Deep.get_callstack k 6));
                match Effect.perform eff with
                | v -> Effect.Deep.continue k v
                | exception e -> Effect.Deep.discontinue k e))
    }

let protect mode m name f =
  Mutex.lock m;
  match
    if not (in_eio ()) then f ()
    else
      match mode with
      | Discontinue -> discontinuing name f
      | Record -> recording name f
  with
  | v ->
    Mutex.unlock m;
    v
  | exception e ->
    Mutex.unlock m;
    raise e

let case label f =
  let r =
    match f () with
    | () -> "ran to the end"
    | exception Held_across_suspension { mutex; body_raised = None } ->
      "Held_across_suspension " ^ mutex
    | exception Held_across_suspension { mutex; body_raised = Some e } ->
      Printf.sprintf "Held_across_suspension %s (body raised %s)" mutex (Printexc.to_string e)
    | exception e -> "other exception: " ^ String.concat " | " (String.split_on_char '\n' (Printexc.to_string e))
  in
  Printf.printf "%-56s %s\n%!" label r

let n = 1_000_000

let cost label f =
  let once () =
    let t0 = Unix.gettimeofday () in
    for _ = 1 to n do f () done;
    (Unix.gettimeofday () -. t0) *. 1e9 /. float n
  in
  let runs = List.sort compare (List.init 5 (fun _ -> once ())) in
  Printf.printf "%-56s %4.0f ns/op (median of 5 x %d)\n%!" label (List.nth runs 2) n

let () =
  let mode =
    match Sys.argv with
    | [| _; "discontinue" |] -> Discontinue
    | [| _; "record" |] -> Record
    | _ ->
      prerr_endline "usage: proto.exe discontinue|record";
      exit 2
  in
  let protect = protect mode in
  let m = Mutex.create () in
  let cell = ref 0 in
  case "0 outside Eio: run_in_systhread stays unhandled" (fun () ->
    protect m "m" (fun () ->
      match Eio_unix.run_in_systhread (fun () -> ()) with
      | () -> failwith "expected Effect.Unhandled"
      | exception Effect.Unhandled _ -> ()));
  cost "cost outside Eio: Mutex.protect" (fun () -> Mutex.protect m (fun () -> incr cell));
  cost "cost outside Eio: probe protect" (fun () -> protect m "m" (fun () -> incr cell));
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let pm = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  case "1a Fiber.yield" (fun () -> protect m "m" Eio.Fiber.yield);
  case "1b Eio_unix.run_in_systhread" (fun () ->
    protect m "m" (fun () -> Eio_unix.run_in_systhread (fun () -> ())));
  case "1c Eio.Path.stat" (fun () ->
    protect m "m" (fun () -> ignore (Eio.Path.stat ~follow:true Eio.Path.(fs / "/tmp"))));
  case "1d Eio.Process.run true" (fun () ->
    protect m "m" (fun () -> Eio.Process.run pm [ "true" ]));
  case "1e Eio.Time.sleep 0" (fun () -> protect m "m" (fun () -> Eio.Time.sleep clock 0.0));
  case "2a Fiber.check" (fun () -> protect m "m" Eio.Fiber.check);
  case "2b Eio_unix.pipe" (fun () ->
    Eio.Switch.run @@ fun sw -> protect m "m" (fun () -> ignore (Eio_unix.pipe sw)));
  case "2c Eio.Time.Mono.now" (fun () ->
    protect m "m" (fun () -> ignore (Eio.Time.Mono.now (Eio.Stdenv.mono_clock env))));
  case "3 Fiber.fork inside" (fun () ->
    Eio.Switch.run @@ fun sw -> protect m "m" (fun () -> Eio.Fiber.fork ~sw (fun () -> ())));
  case "3b the same switch forks and finishes afterwards" (fun () ->
    Eio.Switch.run @@ fun sw ->
    (try protect m "m" (fun () -> Eio.Fiber.fork ~sw (fun () -> ()))
     with Held_across_suspension _ -> ());
    Eio.Fiber.fork ~sw Eio.Fiber.yield);
  case "4 body catches Held_across_suspension itself" (fun () ->
    protect m "m" (fun () -> try Eio.Fiber.yield () with Held_across_suspension _ -> ()));
  case "5 next protect after a failure takes the mutex" (fun () ->
    (try protect m "m" Eio.Fiber.yield with Held_across_suspension _ -> ());
    protect m "m" (fun () -> ()));
  let em = Eio.Mutex.create () in
  case "7a free Eio.Mutex inside" (fun () ->
    protect m "m" (fun () -> Eio.Mutex.use_rw ~protect:false em ignore));
  case "7b Eio.Mutex held by another fiber" (fun () ->
    let started, set_started = Eio.Promise.create () in
    Eio.Fiber.both
      (fun () ->
        Eio.Mutex.use_rw ~protect:false em (fun () ->
          Eio.Promise.resolve set_started ();
          Eio.Fiber.yield ()))
      (fun () ->
        Eio.Promise.await started;
        protect m "m" (fun () -> Eio.Mutex.use_rw ~protect:false em ignore)));
  case "8 the same Eio.Mutex afterwards, no OS mutex" (fun () ->
    Eio.Mutex.use_rw ~protect:false em ignore);
  case "9 body raises its own exception after a suspension" (fun () ->
    protect m "m" (fun () -> Eio.Fiber.yield (); failwith "body"));
  case "10 switch fails while the section is suspended" (fun () ->
    Eio.Switch.run @@ fun sw ->
    Eio.Fiber.fork ~sw (fun () -> protect m "m" (fun () -> Eio.Time.sleep clock 10.0));
    Eio.Switch.fail sw (Failure "stop"));
  cost "cost in Eio: Mutex.protect" (fun () -> Mutex.protect m (fun () -> incr cell));
  cost "cost in Eio: probe protect" (fun () -> protect m "m" (fun () -> incr cell));
  cost "cost in Eio: Mutex.protect, body calls Fiber.check" (fun () ->
    Mutex.protect m (fun () -> Eio.Fiber.check (); incr cell));
  cost "cost in Eio: probe protect, body calls Fiber.check" (fun () ->
    protect m "m" (fun () -> Eio.Fiber.check (); incr cell))
```
