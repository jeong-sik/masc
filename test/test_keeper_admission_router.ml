(** Unit tests for Keeper_admission_router.

    Tests cover:
    - Dispatch on first available bucket (top candidate)
    - Dispatch fallback when top is throttled
    - Wait when all above-floor candidates throttled
    - Surface Min_tier_unsatisfiable when no above-floor candidates
    - drift_record reason classification (preferred / fallback /
      survival_recovery / secondary_preferred) *)

open Masc_mcp
module KAR = Keeper_admission_router
module KAP = Keeper_admission_policy
module KPTB = Keeper_provider_token_bucket

let now_ref = ref 0.0
let now () = !now_ref

let make_bucket ~capacity ~refill_rate provider =
  KPTB.create ~provider ~capacity ~refill_rate ~now

let make_policy ~candidates ~min_tier =
  match
    KAP.of_fields ~keeper_id:"k" ~candidates ~weight:1 ~min_tier
  with
  | Ok p -> p
  | Error _ -> Alcotest.fail "of_fields rejected test setup"

let candidate ~p ~m ~t : KAP.candidate = { provider = p; model = m; tier = t }

(* Drain a bucket so subsequent try_acquire returns false. *)
let drain b =
  let rec loop () = if KPTB.try_acquire b then loop () in
  loop ()

(* ------------------------------------------------------------------ *)
(* Dispatch path                                                       *)
(* ------------------------------------------------------------------ *)

let test_dispatch_top_candidate () =
  let bucket = make_bucket ~capacity:1 ~refill_rate:1.0 "anthropic" in
  let policy =
    make_policy ~min_tier:KAP.Acceptable
      ~candidates:[ candidate ~p:"anthropic" ~m:"x" ~t:KAP.Preferred ]
  in
  let buckets = function "anthropic" -> Some bucket | _ -> None in
  match KAR.schedule ~policy ~buckets with
  | KAR.Dispatch { candidate = c; drift } ->
      Alcotest.(check string) "dispatched anthropic" "anthropic" c.provider;
      Alcotest.(check string) "preferred = anthropic" "anthropic"
        drift.preferred_provider;
      Alcotest.(check string) "actual = anthropic" "anthropic"
        drift.actual_provider;
      Alcotest.(check string) "reason = preferred" "preferred" drift.reason
  | _ -> Alcotest.fail "expected Dispatch"

let test_dispatch_fallback_when_top_drained () =
  let top = make_bucket ~capacity:1 ~refill_rate:0.001 "anthropic" in
  drain top;
  let alt = make_bucket ~capacity:1 ~refill_rate:1.0 "glm" in
  let policy =
    make_policy ~min_tier:KAP.Acceptable
      ~candidates:
        [ candidate ~p:"anthropic" ~m:"x" ~t:KAP.Preferred
        ; candidate ~p:"glm" ~m:"y" ~t:KAP.Acceptable
        ]
  in
  let buckets = function
    | "anthropic" -> Some top
    | "glm" -> Some alt
    | _ -> None
  in
  match KAR.schedule ~policy ~buckets with
  | KAR.Dispatch { candidate = c; drift } ->
      Alcotest.(check string) "dispatched glm" "glm" c.provider;
      Alcotest.(check string) "drift reason = fallback" "fallback"
        drift.reason
  | _ -> Alcotest.fail "expected Dispatch on fallback"

let test_dispatch_survival_recovery_label () =
  let top = make_bucket ~capacity:1 ~refill_rate:0.001 "anthropic" in
  drain top;
  let surv = make_bucket ~capacity:1 ~refill_rate:1.0 "ollama" in
  let policy =
    make_policy ~min_tier:KAP.Survival
      ~candidates:
        [ candidate ~p:"anthropic" ~m:"x" ~t:KAP.Preferred
        ; candidate ~p:"ollama" ~m:"local" ~t:KAP.Survival
        ]
  in
  let buckets = function
    | "anthropic" -> Some top
    | "ollama" -> Some surv
    | _ -> None
  in
  match KAR.schedule ~policy ~buckets with
  | KAR.Dispatch { drift; _ } ->
      Alcotest.(check string) "reason = survival_recovery"
        "survival_recovery" drift.reason
  | _ -> Alcotest.fail "expected Dispatch on survival"

(* ------------------------------------------------------------------ *)
(* Wait + Surface                                                      *)
(* ------------------------------------------------------------------ *)

let test_wait_when_all_throttled () =
  let top = make_bucket ~capacity:1 ~refill_rate:0.001 "anthropic" in
  drain top;
  let alt = make_bucket ~capacity:1 ~refill_rate:0.001 "glm" in
  drain alt;
  let policy =
    make_policy ~min_tier:KAP.Acceptable
      ~candidates:
        [ candidate ~p:"anthropic" ~m:"x" ~t:KAP.Preferred
        ; candidate ~p:"glm" ~m:"y" ~t:KAP.Acceptable
        ]
  in
  let buckets = function
    | "anthropic" -> Some top
    | "glm" -> Some alt
    | _ -> None
  in
  match KAR.schedule ~policy ~buckets with
  | KAR.Wait -> ()
  | _ -> Alcotest.fail "expected Wait when all throttled"

let test_surface_when_no_buckets_configured () =
  (* Bucket lookup returns None for every provider → no above-floor
     supply structurally exists.  Surface, not Wait. *)
  let policy =
    make_policy ~min_tier:KAP.Acceptable
      ~candidates:[ candidate ~p:"anthropic" ~m:"x" ~t:KAP.Preferred ]
  in
  let buckets _ = None in
  match KAR.schedule ~policy ~buckets with
  | KAR.Surface KAR.Min_tier_unsatisfiable -> ()
  | _ -> Alcotest.fail "expected Surface Min_tier_unsatisfiable"

(* ------------------------------------------------------------------ *)
(* classify_reason coverage                                            *)
(* ------------------------------------------------------------------ *)

let test_classify_reason_table () =
  let cases =
    [ ("anthropic", "anthropic", KAP.Preferred, "preferred")
    ; ("anthropic", "glm", KAP.Acceptable, "fallback")
    ; ("anthropic", "ollama", KAP.Survival, "survival_recovery")
    ; ("anthropic", "kimi", KAP.Preferred, "secondary_preferred")
    ]
  in
  List.iter
    (fun (preferred, actual, tier, expected) ->
      let got = KAR.classify_reason ~preferred ~actual ~tier in
      Alcotest.(check string)
        (Printf.sprintf "classify (%s, %s)" preferred actual)
        expected got)
    cases

(* ------------------------------------------------------------------ *)
(* Test runner                                                         *)
(* ------------------------------------------------------------------ *)

let () =
  Alcotest.run "keeper_admission_router"
    [ ( "dispatch"
      , [ Alcotest.test_case "top candidate when token available" `Quick
            test_dispatch_top_candidate
        ; Alcotest.test_case "fallback when top drained" `Quick
            test_dispatch_fallback_when_top_drained
        ; Alcotest.test_case "survival_recovery label on Survival tier"
            `Quick test_dispatch_survival_recovery_label
        ] )
    ; ( "wait_surface"
      , [ Alcotest.test_case "Wait when all above-floor throttled" `Quick
            test_wait_when_all_throttled
        ; Alcotest.test_case
            "Surface Min_tier_unsatisfiable when no buckets" `Quick
            test_surface_when_no_buckets_configured
        ] )
    ; ( "classify"
      , [ Alcotest.test_case "reason table coverage" `Quick
            test_classify_reason_table
        ] )
    ]
