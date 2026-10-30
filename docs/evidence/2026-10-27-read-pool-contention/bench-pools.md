# 풀 분리(L3)와 claim(L4b) 합성 벤치마크

2026-10-27 15:4x KST, `feat/rfc-0204-cache-wait` `c87fe6251e6`에서 돌렸어요. MacBook M3 Max(16코어)이고, 같은 기계에서 운영 서버와 다른 세션이 돌고 있었어요(load average 62). 그래서 절대값보다 전후 비교로 봐요. 운영 서버의 수치가 아니에요. 운영 효과는 배포 뒤 L2 `pool_wait`와 경로별 p99로 재요.

## 1. 배경 작업이 공유 풀을 채울 때 읽기의 대기 (L3)

- 공유 풀 domain 2개. 배경 fiber 6개가 40 ms CPU job을 쉬지 않고 넣어요.
- 읽기(`Pool_lane.with_read`)가 10 ms마다 작은 job을 넣고, 넣은 때부터 시작할 때까지를 재요. 300번 재요.
- 읽기 풀(domain 1개)을 깔지 않은 경우와 깐 경우를 비교했어요. 두 번 돌렸어요.

| 경우 | p50 | p90 | p99 | max |
|---|---|---|---|---|
| 공유 풀만(1회) | 109.3 ms | 110.8 ms | 125.6 ms | 148.4 ms |
| 읽기 풀 + 공유 풀(1회) | 0.0 ms | 0.1 ms | 0.6 ms | 1.1 ms |
| 공유 풀만(2회) | 109.2 ms | 114.9 ms | 144.8 ms | 242.9 ms |
| 읽기 풀 + 공유 풀(2회) | 0.0 ms | 0.2 ms | 1.5 ms | 2.7 ms |

공유 풀만 쓰면 읽기는 FIFO 줄에서 배경 job 뒤에 서요. 대기는 배경 job 길이와 줄 길이를 따라가요. 운영 서버의 배경 job(Librarian 등)은 초 단위라, 같은 구조에서 대기도 초 단위가 돼요. TUI의 10초 timeout이 그 예예요.

## 2. 기다리는 job이 하나뿐인 worker를 쥘 때 (L4b)

- 풀 domain 1개. 풀 job 하나가 worker를 쥔 채 키 K를 조회해요.
- K의 owner(풀 밖 fiber)는 계산을 같은 풀에 넣어, 그 job 뒤에 줄을 서요.
- 계산은 5 ms CPU예요. 둘 다 값을 받을 때까지 재요. 10번 재고, timeout은 2초예요.
- "claim 없음"은 같은 코드에서 기다리던 job이 맡지 못하게 막은 빌드로 쟀어요. L4b 전 동작과 같아요.

| 경우 | p50 | p90 | max |
|---|---|---|---|
| claim 없음(L4b 전) | 2003.8 ms | 2165.9 ms | 2165.9 ms |
| claim 있음(L4b) | 5.2 ms | 5.2 ms | 5.2 ms |

claim이 없으면 기다리던 job이 wait timeout(2초)까지 worker를 쥐고, 그동안 owner의 계산은 시작하지 못해요. 10번 중 5번은 owner 쪽도 compute timeout을 남겼어요. claim이 있으면 기다리던 job이 그 계산을 맡아 5 ms 만에 둘 다 값을 받아요.

## 프로그램

`scratch_bench/bench_pools.ml`(dune `executable`, 라이브러리 `masc.dashboard masc.masc_core masc.masc_eio_context masc.time_compat eio eio_main unix yojson`), `bench_pools.exe read`, `bench_pools.exe queued`.

```ocaml
(* Scratch benchmark for RFC-0204 L3 and L4b. Not committed.

   1. Read wait: the shared pool is kept busy by background fibers that submit
      40 ms CPU jobs back to back. A read (Pool_lane.with_read) submits a tiny
      job every 10 ms; we record how long it waits before it starts. Run with
      and without a read pool.
   2. Queued compute: a pool with one worker. A pool job holds the worker and
      then looks up key K; the owner of K (outside the pool) has its compute
      queued behind that job. We record the time until both have K. *)

let now () = Unix.gettimeofday ()

let busy ms =
  let t0 = now () in
  while now () -. t0 < ms /. 1000. do () done
;;

let summary label samples =
  let a = Array.of_list samples in
  Array.sort compare a;
  let n = Array.length a in
  let at p = a.(min (n - 1) (int_of_float (p *. float n))) in
  Printf.printf "%-44s n=%d p50=%7.1f ms p90=%7.1f ms p99=%7.1f ms max=%7.1f ms\n%!" label n
    (at 0.5) (at 0.9) (at 0.99) a.(n - 1)
;;

let read_wait env ~read_pool =
  Eio.Switch.run (fun sw ->
    let clock = Eio.Stdenv.clock env in
    let dm = Eio.Stdenv.domain_mgr env in
    let shared = Domain_pool.create ~sw ~domain_count:2 dm in
    Domain_pool_ref.set shared;
    let read = if read_pool then Some (Domain_pool.create ~sw ~domain_count:1 dm) else None in
    Option.iter Domain_pool_ref.set_read read;
    let with_read f =
      match read with
      | Some r -> Executor_pool_ref.For_testing.with_read_pool (Domain_pool.executor_pool r) f
      | None -> f ()
    in
    Fun.protect ~finally:Domain_pool_ref.clear_for_tests (fun () ->
      Executor_pool_ref.For_testing.with_pool (Domain_pool.executor_pool shared) (fun () ->
        with_read (fun () ->
          let stop = Atomic.make false in
          for _ = 1 to 6 do
            Eio.Fiber.fork ~sw (fun () ->
              while not (Atomic.get stop) do
                Domain_pool_ref.submit_cpu_or_inline (fun () -> busy 40.)
              done)
          done;
          Eio.Time.sleep clock 0.3;
          let waits = ref [] in
          for _ = 1 to 300 do
            let t0 = now () in
            let started =
              Pool_lane.with_read (fun () -> Domain_pool_ref.submit_cpu_or_inline now)
            in
            waits := ((started -. t0) *. 1000.) :: !waits;
            Eio.Time.sleep clock 0.01
          done;
          Atomic.set stop true;
          summary
            (if read_pool then "read wait, read pool (1) + shared (2)" else "read wait, shared pool (2) only")
            !waits))))
;;

let queued_compute env ~rounds ~timeout_sec =
  Eio.Switch.run (fun sw ->
    let clock = Eio.Stdenv.clock env in
    Eio_context.set_switch sw;
    Time_compat.set_clock clock;
    let pool = Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
    Domain_pool_ref.set pool;
    Fun.protect
      ~finally:(fun () ->
        Domain_pool_ref.clear_for_tests ();
        Eio_context.For_testing.clear_root_switch ())
      (fun () ->
        Executor_pool_ref.For_testing.with_pool (Domain_pool.executor_pool pool) (fun () ->
          let times = ref [] in
          for round = 1 to rounds do
            Dashboard_cache.invalidate_all ();
            let key = Printf.sprintf "bench-queued-%d" round in
            let lookup () =
              Dashboard_cache.get_or_compute_with_timeout key ~ttl:60. ~clock ~timeout_sec
                (fun () ->
                  busy 5.;
                  `String "v")
            in
            let on_worker, arrived = Eio.Promise.create () in
            let go, start = Eio.Promise.create () in
            let waiter =
              Eio.Fiber.fork_promise ~sw (fun () ->
                Executor_pool_ref.submit_or_inline (fun () ->
                  Eio.Promise.resolve arrived ();
                  Eio.Promise.await go;
                  lookup ()))
            in
            Eio.Promise.await on_worker;
            let owner = Eio.Fiber.fork_promise ~sw lookup in
            let t0 = now () in
            Eio.Promise.resolve start ();
            ignore (Eio.Promise.await_exn waiter);
            ignore (Eio.Promise.await_exn owner);
            times := ((now () -. t0) *. 1000.) :: !times
          done;
          summary
            (Printf.sprintf "queued compute, 1 worker (timeout %.0fs)" timeout_sec)
            !times)))
;;

let () =
  Eio_main.run (fun env ->
    Eio_guard.enable ();
    match Sys.argv with
    | [| _; "read" |] ->
      read_wait env ~read_pool:false;
      read_wait env ~read_pool:true
    | [| _; "queued" |] -> queued_compute env ~rounds:10 ~timeout_sec:2.
    | _ -> prerr_endline "usage: bench_pools.exe (read | queued)")
;;
```
