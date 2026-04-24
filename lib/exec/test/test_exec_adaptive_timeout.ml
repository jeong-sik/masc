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

let test_stats_default () =
  let entries = [ entry ~duration_ms:100 "ls" ] in
  (match AT.stats AT.default_config entries with
   | AT.Default { reason; recommended_ms } ->
     Alcotest.(check bool) "reason is non-empty" true (String.length reason > 0);
     Alcotest.(check int) "recommended from config default" 120_000 recommended_ms
   | _ -> Alcotest.fail "should be Default")

let test_stats_adapted () =
  let config = { AT.default_config with min_ms = 50; multiplier = 1.5 } in
  let entries = List.init 5 (fun i ->
    entry ~duration_ms:(100 + i * 50) "build")
  in
  (match AT.stats config entries with
   | AT.Adapted { p95_ms; recommended_ms; sample_count } ->
     (* sorted: 100,150,200,250,300. p95 idx=4 => 300 *)
     Alcotest.(check int) "p95" 300 p95_ms;
     Alcotest.(check int) "recommended" 450 recommended_ms;
     Alcotest.(check int) "sample_count" 5 sample_count
   | _ -> Alcotest.fail "should be Adapted")

let test_stats_json_adapted () =
  let entries = List.init 5 (fun i ->
    entry ~duration_ms:(100 + i * 50) "build")
  in
  let config = { AT.default_config with min_ms = 50; multiplier = 1.5 } in
  let s = AT.stats config entries in
  let json = AT.stats_to_json s in
  (match json with
   | `Assoc fields ->
     (match List.assoc_opt "adapted" fields with
      | Some (`Bool true) -> ()
      | _ -> Alcotest.fail "adapted should be true");
     (match List.assoc_opt "p95_ms" fields with
      | Some (`Int 300) -> ()
      | _ -> Alcotest.fail "p95_ms should be 300")
   | _ -> Alcotest.fail "expected assoc")

let test_stats_json_default () =
  let s = AT.stats AT.default_config [] in
  let json = AT.stats_to_json s in
  (match json with
   | `Assoc fields ->
     (match List.assoc_opt "adapted" fields with
      | Some (`Bool false) -> ()
      | _ -> Alcotest.fail "adapted should be false");
     (match List.assoc_opt "recommended_ms" fields with
      | Some (`Int 120_000) -> ()
      | _ -> Alcotest.fail "should have default recommended_ms")
   | _ -> Alcotest.fail "expected assoc")

let test_stats_json_default_uses_config_default () =
  let config = { AT.default_config with default_ms = 45_000 } in
  let s = AT.stats config [] in
  let json = AT.stats_to_json s in
  (match json with
   | `Assoc fields ->
     (match List.assoc_opt "recommended_ms" fields with
      | Some (`Int 45_000) -> ()
      | _ -> Alcotest.fail "should use configured default_ms")
   | _ -> Alcotest.fail "expected assoc")

let () =
  test_default_config ();
  test_compute_empty ();
  test_compute_few_samples ();
  test_compute_adapts ();
  test_compute_min_clamp ();
  test_compute_max_clamp ();
  test_compute_ignores_failures ();
  test_stats_default ();
  test_stats_adapted ();
  test_stats_json_adapted ();
  test_stats_json_default ();
  test_stats_json_default_uses_config_default ();
  print_endline "test_exec_adaptive_timeout: 12/12 passed"
