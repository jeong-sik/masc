(* Deterministic tests for Eval_variance (task-628 / M1 run-variance spine).
   Pure statistics over fixed inputs — no I/O, no provider, fully reproducible.
   Runnable as a standalone executable; exits non-zero on the first failure. *)

module Eval_variance = Masc_mcp.Eval_variance

let failures = ref 0

let check name cond =
  if cond then Printf.printf "  ok   %s\n" name
  else (
    incr failures;
    Printf.printf "  FAIL %s\n" name)

let approx ?(eps = 1e-6) a b = Float.abs (a -. b) <= eps

let some_band = function Some b -> b | None -> failwith "expected Some band"

let () =
  print_endline "z_for_confidence (Acklam probit)";
  check "z@0.95 ~ 1.95996"
    (approx ~eps:1e-3 (Eval_variance.z_for_confidence 0.95) 1.959964);
  check "z@0.90 ~ 1.64485"
    (approx ~eps:1e-3 (Eval_variance.z_for_confidence 0.90) 1.644854);
  check "z@0.99 ~ 2.57583"
    (approx ~eps:1e-3 (Eval_variance.z_for_confidence 0.99) 2.575829);

  print_endline "band_of_scores";
  check "empty -> None" (Eval_variance.band_of_scores [] = None);
  check "singleton -> None" (Eval_variance.band_of_scores [ 0.8 ] = None);
  let identical = some_band (Eval_variance.band_of_scores [ 0.8; 0.8; 0.8; 0.8; 0.8 ]) in
  check "identical: mean=0.8" (approx identical.mean 0.8);
  check "identical: std=0" (approx identical.std 0.0);
  check "identical: ci_width=0" (approx identical.ci_width 0.0);
  check "identical: n=5" (identical.n = 5);
  let b = some_band (Eval_variance.band_of_scores [ 0.6; 0.8; 0.7; 0.9; 0.5 ]) in
  check "mean=0.7" (approx b.mean 0.7);
  (* sample std (n-1) of {0.6,0.8,0.7,0.9,0.5} = sqrt(0.1/4) ~ 0.158114 *)
  check "sample std ~0.158114" (approx ~eps:1e-5 b.std 0.158114);
  check "ci symmetric about mean"
    (approx (b.ci_high -. b.mean) (b.mean -. b.ci_low));
  check "ci_width = ci_high - ci_low"
    (approx b.ci_width (b.ci_high -. b.ci_low));
  check "ci_width > 0 for variable scores" (b.ci_width > 0.0);

  print_endline "band_of_proportion (Wilson)";
  check "trials=0 -> None"
    (Eval_variance.band_of_proportion ~trials:0 ~successes:0 () = None);
  check "successes>trials -> None"
    (Eval_variance.band_of_proportion ~trials:5 ~successes:6 () = None);
  let p_all = some_band (Eval_variance.band_of_proportion ~trials:10 ~successes:10 ()) in
  check "10/10: mean=1.0" (approx p_all.mean 1.0);
  check "10/10: ci_high <= 1.0" (p_all.ci_high <= 1.0 +. 1e-9);
  check "10/10: ci_low < 1.0 (Wilson not degenerate)" (p_all.ci_low < 1.0);
  let p_none = some_band (Eval_variance.band_of_proportion ~trials:10 ~successes:0 ()) in
  check "0/10: mean=0.0" (approx p_none.mean 0.0);
  check "0/10: ci_low >= 0.0" (p_none.ci_low >= -1e-9);
  let p_half = some_band (Eval_variance.band_of_proportion ~trials:10 ~successes:5 ()) in
  check "5/10: mean=0.5" (approx p_half.mean 0.5);
  check "5/10: ci brackets 0.5"
    (p_half.ci_low < 0.5 && p_half.ci_high > 0.5);

  print_endline "compare (difference CI excludes 0)";
  let high = some_band (Eval_variance.band_of_scores [ 0.90; 0.91; 0.89; 0.92; 0.88 ]) in
  let low = some_band (Eval_variance.band_of_scores [ 0.60; 0.61; 0.59; 0.62; 0.58 ]) in
  check "well-separated high vs low -> Improvement"
    (Eval_variance.compare ~baseline:low ~candidate:high ()
     = Eval_variance.Improvement);
  check "well-separated low vs high -> Regression"
    (Eval_variance.compare ~baseline:high ~candidate:low ()
     = Eval_variance.Regression);
  check "identical bands -> Inconclusive"
    (Eval_variance.compare ~baseline:high ~candidate:high ()
     = Eval_variance.Inconclusive);
  let noisy_a = some_band (Eval_variance.band_of_scores [ 0.5; 0.9; 0.3; 0.8; 0.4 ]) in
  let noisy_b = some_band (Eval_variance.band_of_scores [ 0.55; 0.85; 0.35; 0.75; 0.45 ]) in
  check "overlapping noisy bands -> Inconclusive"
    (Eval_variance.compare ~baseline:noisy_a ~candidate:noisy_b ()
     = Eval_variance.Inconclusive);

  print_endline "difference (inspectable delta + CI)";
  let d = Eval_variance.difference ~baseline:low ~candidate:high () in
  check "delta ~0.30 (0.90 - 0.60)" (approx ~eps:1e-9 d.delta 0.30);
  check "difference.verdict matches compare"
    (d.verdict = Eval_variance.compare ~baseline:low ~candidate:high ());
  check "improvement -> ci_low > 0" (d.ci_low > 0.0);
  check "ci_low < ci_high" (d.ci_low < d.ci_high);
  check "ci brackets delta" (d.ci_low <= d.delta && d.delta <= d.ci_high);
  let d_eq = Eval_variance.difference ~baseline:high ~candidate:high () in
  check "identical -> delta=0" (approx d_eq.delta 0.0);
  check "identical -> Inconclusive" (d_eq.verdict = Eval_variance.Inconclusive);
  check "identical -> ci brackets 0" (d_eq.ci_low <= 0.0 && d_eq.ci_high >= 0.0);
  let dj = Eval_variance.difference_to_json d in
  check "difference json has delta + verdict"
    (match dj with
     | `Assoc l -> List.mem_assoc "delta" l && List.mem_assoc "verdict" l
     | _ -> false);

  print_endline "check_gate";
  let few = some_band (Eval_variance.band_of_scores [ 0.7; 0.8 ]) in
  check "n=2 < min_runs=5 -> Too_few_runs"
    (match Eval_variance.check_gate Eval_variance.default_gate few with
     | Too_few_runs { got = 2; need = 5 } -> true
     | _ -> false);
  let tight = some_band (Eval_variance.band_of_scores [ 0.80; 0.80; 0.81; 0.79; 0.80 ]) in
  check "tight band, n=5 -> Gate_ok"
    (Eval_variance.check_gate Eval_variance.default_gate tight = Eval_variance.Gate_ok);
  let wide_gate = { Eval_variance.min_runs = 5; max_ci_width = 0.001 } in
  check "tight band vs strict ci gate -> Ci_too_wide"
    (match Eval_variance.check_gate wide_gate tight with
     | Ci_too_wide _ -> true
     | _ -> false);

  print_endline "json";
  let j = Eval_variance.variance_band_to_json tight in
  check "json has mean field"
    (match j with `Assoc l -> List.mem_assoc "mean" l | _ -> false);

  if !failures = 0 then print_endline "\nALL EVAL_VARIANCE TESTS PASSED"
  else (
    Printf.printf "\n%d FAILURE(S)\n" !failures;
    exit 1)
