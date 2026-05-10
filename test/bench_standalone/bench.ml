(** Benchmark: single-Domain fiber vs Executor_pool for keeper workloads.

    RFC-0059 §9.4: Measures wall-clock for N concurrent simulated
    keeper turns under three workload types:

    1. pure_io    — simulated HTTP call (Eio.Time.sleep).
                    Tests cooperative yielding within a single domain.
    2. pure_cpu   — CPU-bound work (compute_intensive).
                    Tests actual OS-thread blocking.
    3. mixed      — IO + CPU (simulated LLM call + tool execution).
                    Closest to real keeper behavior.

    Standalone — no masc_mcp dependency. Inline Executor_pool weight
    policy from Domain_pool (PR-6 of RFC-0059):
      - IO-bound: weight 0.05 (~20 concurrent jobs/domain)
      - CPU-bound: weight 1.0 (1 job/domain)

    Usage:  dune exec test/bench_standalone/bench.exe
    Output: CSV to stdout

    Columns:
      scenario        — single_domain | executor_pool
      workload        — pure_io | pure_cpu | mixed
      keeper_count    — N concurrent keepers
      domain_count    — worker domain count (1 for single_domain)
      wall_clock_s    — measured wall-clock time
      run             — repetition number *)

let runs = 3
let keeper_counts = [| 4; 16; 64 |]
let domain_counts = [| 1; 2; 4; 8; 15 |]

(* Inline weight policy from Domain_pool (PR-6 RFC-0059). *)
let weight_io = 0.05
let weight_cpu = 1.0

(* ── Simulated workloads ─────────────────────────────────── *)

(** Simulate a CPU-bound tool call: ~50ms of actual computation.
    Uses factorial-style integer arithmetic that cannot be optimized
    away. Returns a dummy result to prevent dead-code elimination. *)
let compute_intensive () =
  let rec loop acc i =
    if i <= 0
    then acc
    else (
      (* Mixed arithmetic to prevent optimization *)
      let x = Int64.of_int i in
      let x = Int64.mul x (Int64.of_int (i + 1)) in
      let x = Int64.logxor x (Int64.shift_left x 1) in
      loop (acc + (Int64.to_int x land 0xFFFF)) (i - 1))
  in
  ignore (loop 0 1_000_000)
;;

(** Simulate an LLM API call: 1s network round-trip (non-blocking yield). *)
let simulate_llm_call clock = Eio.Time.sleep clock 1.0

(** Simulate a tool execution: 50ms CPU-bound computation. *)
let simulate_tool_call () = compute_intensive ()

(* ── Scenario 1: single-Domain fiber baseline ────────────── *)

(** Pure IO: each keeper does one LLM call. *)
let measure_single_pure_io clock sw n =
  let t0 = Unix.gettimeofday () in
  let ps =
    Array.init n (fun _ ->
      let p, r = Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
        simulate_llm_call clock;
        Eio.Promise.resolve_ok r ());
      p)
  in
  Array.iter Eio.Promise.await_exn ps;
  Unix.gettimeofday () -. t0
;;

(** Pure CPU: each keeper does one tool call. *)
let measure_single_pure_cpu sw n =
  let t0 = Unix.gettimeofday () in
  let ps =
    Array.init n (fun _ ->
      let p, r = Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
        simulate_tool_call ();
        Eio.Promise.resolve_ok r ());
      p)
  in
  Array.iter Eio.Promise.await_exn ps;
  Unix.gettimeofday () -. t0
;;

(** Mixed: each keeper does 1 LLM call + 1 tool call (sequential). *)
let measure_single_mixed clock sw n =
  let t0 = Unix.gettimeofday () in
  let ps =
    Array.init n (fun _ ->
      let p, r = Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
        simulate_llm_call clock;
        simulate_tool_call ();
        Eio.Promise.resolve_ok r ());
      p)
  in
  Array.iter Eio.Promise.await_exn ps;
  Unix.gettimeofday () -. t0
;;

(* ── Scenario 2: Executor_pool with N worker domains ──────── *)

let measure_pool_pure_io clock dm sw n dc =
  let pool = Eio.Executor_pool.create ~sw ~domain_count:dc dm in
  let t0 = Unix.gettimeofday () in
  let ps =
    Array.init n (fun _ ->
      Eio.Executor_pool.submit_fork ~sw pool ~weight:weight_io (fun () ->
        simulate_llm_call clock))
  in
  Array.iter (fun p -> ignore (Eio.Promise.await_exn p)) ps;
  Unix.gettimeofday () -. t0
;;

let measure_pool_pure_cpu dm sw n dc =
  let pool = Eio.Executor_pool.create ~sw ~domain_count:dc dm in
  let t0 = Unix.gettimeofday () in
  let ps =
    Array.init n (fun _ ->
      Eio.Executor_pool.submit_fork ~sw pool ~weight:weight_cpu (fun () ->
        simulate_tool_call ()))
  in
  Array.iter (fun p -> ignore (Eio.Promise.await_exn p)) ps;
  Unix.gettimeofday () -. t0
;;

let measure_pool_mixed clock dm sw n dc =
  let pool = Eio.Executor_pool.create ~sw ~domain_count:dc dm in
  let t0 = Unix.gettimeofday () in
  let ps =
    Array.init n (fun _ ->
      (* Submit LLM call as IO, tool call as CPU — same as real
         keeper would with Domain_pool.submit_io / submit_cpu. *)
      Eio.Executor_pool.submit_fork ~sw pool ~weight:weight_io (fun () ->
        simulate_llm_call clock;
        simulate_tool_call ()))
  in
  Array.iter (fun p -> ignore (Eio.Promise.await_exn p)) ps;
  Unix.gettimeofday () -. t0
;;

(* ── Main ─────────────────────────────────────────────────── *)

let () =
  Eio_main.run (fun env ->
    let dm = Eio.Stdenv.domain_mgr env in
    let clock = Eio.Stdenv.clock env in
    Printf.printf "scenario,workload,keeper_count,domain_count,wall_clock_s,run\n%!";
    (* ── Pure IO ──────────────────────────────────────────── *)
    for k = 0 to Array.length keeper_counts - 1 do
      for r = 1 to runs do
        Eio.Switch.run (fun sw ->
          let wall = measure_single_pure_io clock sw keeper_counts.(k) in
          Printf.printf "single_domain,pure_io,%d,1,%.4f,%d\n%!" keeper_counts.(k) wall r)
      done
    done;
    for dc = 0 to Array.length domain_counts - 1 do
      for k = 0 to Array.length keeper_counts - 1 do
        for r = 1 to runs do
          Eio.Switch.run (fun sw ->
            let wall =
              measure_pool_pure_io clock dm sw keeper_counts.(k) domain_counts.(dc)
            in
            Printf.printf
              "executor_pool,pure_io,%d,%d,%.4f,%d\n%!"
              keeper_counts.(k)
              domain_counts.(dc)
              wall
              r)
        done
      done
    done;
    (* ── Pure CPU ─────────────────────────────────────────── *)
    for k = 0 to Array.length keeper_counts - 1 do
      for r = 1 to runs do
        Eio.Switch.run (fun sw ->
          let wall = measure_single_pure_cpu sw keeper_counts.(k) in
          Printf.printf "single_domain,pure_cpu,%d,1,%.4f,%d\n%!" keeper_counts.(k) wall r)
      done
    done;
    for dc = 0 to Array.length domain_counts - 1 do
      for k = 0 to Array.length keeper_counts - 1 do
        for r = 1 to runs do
          Eio.Switch.run (fun sw ->
            let wall = measure_pool_pure_cpu dm sw keeper_counts.(k) domain_counts.(dc) in
            Printf.printf
              "executor_pool,pure_cpu,%d,%d,%.4f,%d\n%!"
              keeper_counts.(k)
              domain_counts.(dc)
              wall
              r)
        done
      done
    done;
    (* ── Mixed (IO + CPU) ─────────────────────────────────── *)
    for k = 0 to Array.length keeper_counts - 1 do
      for r = 1 to runs do
        Eio.Switch.run (fun sw ->
          let wall = measure_single_mixed clock sw keeper_counts.(k) in
          Printf.printf "single_domain,mixed,%d,1,%.4f,%d\n%!" keeper_counts.(k) wall r)
      done
    done;
    for dc = 0 to Array.length domain_counts - 1 do
      for k = 0 to Array.length keeper_counts - 1 do
        for r = 1 to runs do
          Eio.Switch.run (fun sw ->
            let wall =
              measure_pool_mixed clock dm sw keeper_counts.(k) domain_counts.(dc)
            in
            Printf.printf
              "executor_pool,mixed,%d,%d,%.4f,%d\n%!"
              keeper_counts.(k)
              domain_counts.(dc)
              wall
              r)
        done
      done
    done)
;;
