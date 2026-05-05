(* Cycle 23 / Tier B6 tests — Resilience.Recovery error_mode + strategy. *)

module R = Resilience.Recovery

let contains haystack needle =
  let h = String.length haystack in
  let n = String.length needle in
  let rec loop i =
    i + n <= h
    && (String.sub haystack i n = needle || loop (i + 1))
  in
  n = 0 || loop 0

(* ─── Convenience constructors ────────────────────────────────── *)

let test_transient_default_args () =
  let e = R.transient ~detail:"network blip" () in
  match e with
  | R.TransientError { detail; max_retries; backoff_ms } ->
      assert (detail = "network blip");
      assert (max_retries = 3);
      assert (backoff_ms = 200)
  | _ -> assert false

let test_transient_explicit_args () =
  let e = R.transient ~detail:"x" ~max_retries:5 ~backoff_ms:1000 () in
  match e with
  | R.TransientError { max_retries; backoff_ms; _ } ->
      assert (max_retries = 5);
      assert (backoff_ms = 1000)
  | _ -> assert false

let test_permanent_with_handoff () =
  let e =
    R.permanent ~detail:"401 unauthorized"
      ~fallback:(R.HumanHandoff "rotate API key")
  in
  match e with
  | R.PermanentError { detail; fallback_strategy = R.HumanHandoff msg } ->
      assert (detail = "401 unauthorized");
      assert (msg = "rotate API key")
  | _ -> assert false

let test_resource_exhausted () =
  let e =
    R.resource_exhausted ~resource:`Tokens ~consumed:1000.0 ~limit:500.0
  in
  match e with
  | R.ResourceExhausted { resource; consumed; limit; _ } ->
      assert (resource = `Tokens);
      assert (consumed = Some 1000.0);
      assert (limit = Some 500.0)
  | _ -> assert false

let test_ambiguity_branches () =
  let e =
    R.ambiguity ~detail:"interpretation unclear"
      ~branches:[ "branch_a"; "branch_b" ]
  in
  match e with
  | R.AmbiguityError { branches; _ } -> assert (List.length branches = 2)
  | _ -> assert false

let test_consensus_failure_with_dissenters () =
  let e =
    R.consensus_failure ~detail:"no agreement"
      ~dissenters:[ "verifier"; "scholar" ]
  in
  match e with
  | R.ConsensusError { dissenters; _ } -> assert (List.length dissenters = 2)
  | _ -> assert false

let test_degradation_required_level () =
  let e =
    R.degradation_required ~detail:"too aggressive" ~recommended_level:3
  in
  match e with
  | R.DegradationRequired { recommended_level; _ } ->
      assert (recommended_level = 3)
  | _ -> assert false

(* ─── classify_string heuristic ───────────────────────────────── *)

let test_classify_transient_timeout () =
  match R.classify_string "Connection timeout while fetching" with
  | R.TransientError _ -> ()
  | _ -> assert false

let test_classify_transient_rate_limit () =
  match R.classify_string "HTTP 429 rate limit exceeded" with
  | R.TransientError _ -> ()
  | _ -> assert false

let test_classify_resource_token () =
  match R.classify_string "token budget exhausted" with
  | R.TransientError _ ->
      (* "exhausted" is not in transient phrases; "token" would
         match resource. But "budget" matches Cost first depending
         on iteration order — accept either resource. *)
      assert false
  | R.ResourceExhausted { consumed; limit; detail; _ } ->
      assert (consumed = None);
      assert (limit = None);
      assert (detail = Some "token budget exhausted")
  | _ -> assert false

let test_classify_permanent_fallback () =
  match R.classify_string "Some generic error" with
  | R.PermanentError { fallback_strategy = R.HumanHandoff _; _ } -> ()
  | _ -> assert false

(* ─── default_strategy mapping ────────────────────────────────── *)

let test_strategy_for_transient_is_retry () =
  let mode = R.transient ~detail:"x" ~max_retries:5 ~backoff_ms:100 () in
  match R.default_strategy mode with
  | R.Retry { max_attempts; backoff } ->
      assert (max_attempts = 5);
      let delay = backoff 0 in
      (* 100ms = 0.1s, attempt 0 → 0.1 * 1 = 0.1 *)
      assert (Float.abs (delay -. 0.1) < 1e-9)
  | _ -> assert false

let test_strategy_for_permanent_default_string () =
  let mode =
    R.permanent ~detail:"contract violation"
      ~fallback:(R.UseDefaultString "default-value")
  in
  match R.default_strategy mode with
  | R.Fallback { fallback_value; _ } ->
      assert (fallback_value = "default-value")
  | _ -> assert false

let test_strategy_for_permanent_handoff () =
  let mode =
    R.permanent ~detail:"401" ~fallback:(R.HumanHandoff "rotate key")
  in
  match R.default_strategy mode with
  | R.Handoff _ -> ()
  | _ -> assert false

let test_strategy_for_resource_is_abort () =
  let mode =
    R.resource_exhausted ~resource:`Memory ~consumed:1000.0 ~limit:500.0
  in
  match R.default_strategy mode with
  | R.Abort _ -> ()
  | _ -> assert false

let test_strategy_for_unknown_resource_does_not_fake_zeroes () =
  let mode = R.classify_string "token budget exhausted" in
  match R.default_strategy mode with
  | R.Abort { reason; _ } ->
      assert (contains reason "measurement=unknown");
      assert (not (contains reason "consumed=0.00"));
      assert (not (contains reason "limit=0.00"))
  | _ -> assert false

let test_strategy_for_ambiguity_is_handoff () =
  let mode =
    R.ambiguity ~detail:"two paths" ~branches:[ "a"; "b" ]
  in
  match R.default_strategy mode with
  | R.Handoff _ -> ()
  | _ -> assert false

let test_strategy_for_consensus_is_handoff () =
  let mode =
    R.consensus_failure ~detail:"split" ~dissenters:[ "x" ]
  in
  match R.default_strategy mode with
  | R.Handoff _ -> ()
  | _ -> assert false

let test_strategy_for_degradation_is_handoff () =
  let mode =
    R.degradation_required ~detail:"overrun" ~recommended_level:2
  in
  match R.default_strategy mode with
  | R.Handoff _ -> ()
  | _ -> assert false

(* ─── Strategy GADT phantom-tag discrimination ────────────────── *)

let test_strategy_phantom_tags_compile () =
  (* If this compiles, the [> `Retry | `Fallback | ...] return type
     of default_strategy is correctly polymorphic across the four
     classes. We do not assert anything here beyond the type-check. *)
  let _ : [ `Retry | `Fallback | `Handoff | `Abort ] R.strategy =
    R.default_strategy (R.transient ~detail:"x" ())
  in
  let _ : [ `Retry | `Fallback | `Handoff | `Abort ] R.strategy =
    R.default_strategy
      (R.resource_exhausted ~resource:`Disk ~consumed:0.0 ~limit:0.0)
  in
  ()

let () =
  test_transient_default_args ();
  test_transient_explicit_args ();
  test_permanent_with_handoff ();
  test_resource_exhausted ();
  test_ambiguity_branches ();
  test_consensus_failure_with_dissenters ();
  test_degradation_required_level ();
  test_classify_transient_timeout ();
  test_classify_transient_rate_limit ();
  test_classify_resource_token ();
  test_classify_permanent_fallback ();
  test_strategy_for_transient_is_retry ();
  test_strategy_for_permanent_default_string ();
  test_strategy_for_permanent_handoff ();
  test_strategy_for_resource_is_abort ();
  test_strategy_for_unknown_resource_does_not_fake_zeroes ();
  test_strategy_for_ambiguity_is_handoff ();
  test_strategy_for_consensus_is_handoff ();
  test_strategy_for_degradation_is_handoff ();
  test_strategy_phantom_tags_compile ();
  print_endline "test_recovery: all assertions passed"
