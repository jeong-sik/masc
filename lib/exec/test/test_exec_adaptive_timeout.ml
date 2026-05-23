(* P18 tests: adaptive timeout *)

module AT = Masc_exec.Exec_adaptive_timeout
module BH = Masc_exec.Bash_history

let entry ?(success = true) ~duration_ms prefix =
  BH.{ ts = 0.0; cmd_hash = "x"; cmd_prefix = prefix;
       semantic_kind = "read"; duration_ms; success }

let test_default_config () =
  let c = AT.default_config in
  Alcotest.(check int) "default_ms" 120_000 c.default_ms;
  Alcotest.(check int) "min_ms" 30_000 c.min_ms;
  Alcotest.(check int) "max_ms" 600_000 c.max_ms;
  Alcotest.(check (float 0.01)) "multiplier" 1.5 c.multiplier;
  Alcotest.(check int) "min_samples" 3 c.min_samples

let test_compute_empty () =
  let t = AT.compute AT.default_config [] in
  Alcotest.(check int) "empty returns default" 120_000 t

let test_compute_few_samples () =
  let entries = [ entry ~duration_ms:100 "ls"; entry ~duration_ms:200 "ls" ] in
  let t = AT.compute AT.default_config entries in
  Alcotest.(check int) "2 samples < 3 => default" 120_000 t

let test_compute_adapts () =
  let config = { AT.default_config with min_ms = 50; multiplier = 1.5 } in
  let entries = List.init 10 (fun i ->
    entry ~duration_ms:(100 + i * 10) "dune")
  in
  let t = AT.compute config entries in
  (* sorted: 100,110,...,190. p95 idx = min(9, 9) = 9 => p95 = 190 *)
  (* recommended = 190 * 1.5 = 285, clamped by min=50 *)
  Alcotest.(check int) "adapted" 285 t

let test_compute_min_clamp () =
  let config = { AT.default_config with min_ms = 500; multiplier = 1.5 } in
  let entries = List.init 5 (fun _ -> entry ~duration_ms:10 "fast") in
  let t = AT.compute config entries in
  (* p95=10 * 1.5=15, clamped to min=500 *)
  Alcotest.(check int) "clamped to min" 500 t

let test_compute_max_clamp () =
  let config = { AT.default_config with max_ms = 200; multiplier = 1.5 } in
  let entries = List.init 5 (fun _ -> entry ~duration_ms:500_000 "slow") in
  let t = AT.compute config entries in
  (* p95=500000 * 1.5=750000, clamped to max=200 *)
  Alcotest.(check int) "clamped to max" 200 t

let test_compute_ignores_failures () =
  let config = { AT.default_config with min_ms = 50; multiplier = 1.5 } in
  let entries = [
    entry ~duration_ms:100 "ls";
    entry ~duration_ms:50_000 ~success:false "ls";
    entry ~duration_ms:110 "ls";
    entry ~duration_ms:120 "ls";
  ] in
  let t = AT.compute config entries in
  (* only 3 successes: 100,110,120. p95 idx=2 => p95=120. 120*1.5=180 *)
  Alcotest.(check int) "ignores failures" 180 t

let () =
  test_default_config ();
  test_compute_empty ();
  test_compute_few_samples ();
  test_compute_adapts ();
  test_compute_min_clamp ();
  test_compute_max_clamp ();
  test_compute_ignores_failures ();
  print_endline "test_exec_adaptive_timeout: 7/7 passed"
