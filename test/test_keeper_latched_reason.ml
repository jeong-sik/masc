open Alcotest
module R = Keeper_latched_reason

let reasons =
  [ ( "gRPC operator pause"
    , R.Operator_paused { operator_actor = R.operator_actor_grpc_directive } )
  ; ( "keeper_down operator pause"
    , R.Operator_paused { operator_actor = R.operator_actor_keeper_down } )
  ; "dead tombstone", R.Dead_tombstone
  ; "transcript corruption reset required", R.Transcript_corruption_reset_required
  ]
;;

let expect_ok label = function
  | Ok value -> value
  | Error error -> failf "%s expected Ok, got Error %s" label error
;;

let expect_error label = function
  | Error error -> check bool (label ^ " reports a diagnostic") true (error <> "")
  | Ok value -> failf "%s unexpectedly parsed as %a" label R.pp value
;;

let test_wire_round_trip () =
  List.iter
    (fun (label, reason) ->
      let parsed = expect_ok label (R.of_wire (R.to_wire reason)) in
      check bool label true (R.equal reason parsed))
    reasons
;;

let test_json_round_trip () =
  List.iter
    (fun (label, reason) ->
      let parsed = expect_ok label (R.Stable.of_yojson (R.Stable.to_yojson reason)) in
      check bool label true (R.equal reason parsed))
    reasons
;;

let test_retired_failure_latches_fail_closed () =
  [ "retired_failure_latch:cycles=4"
  ; "runtime_exhausted:all_providers_failed"
  ; "stale_storm"
  ]
  |> List.iter (fun wire -> expect_error wire (R.of_wire wire));
  [ `Assoc [ "kind", `String "retired_failure_latch" ]
  ; `Assoc [ "kind", `String "runtime_exhausted" ]
  ]
  |> List.iter (fun json ->
    expect_error (Yojson.Safe.to_string json) (R.Stable.of_yojson json))
;;

let test_hash_is_deterministic () =
  List.iter
    (fun (label, reason) -> check int label (R.hash reason) (R.hash reason))
    reasons
;;

(* Strength ordering. The latch decides which recovery paths stay open, so a
   weaker request must never replace a stronger persisted latch — that is a
   privilege change, not a relabel. Pinned as a full matrix rather than a few
   samples: the 2026-07-27 incident was exactly one cell of it
   (Operator_paused requested over a persisted
   Transcript_corruption_reset_required). *)

let strength_of label reason expected =
  check
    bool
    (label ^ " strength")
    true
    (R.strength_to_wire (R.strength reason) = expected)
;;

let test_strength_is_assigned_per_variant () =
  strength_of
    "gRPC operator pause"
    (R.Operator_paused { operator_actor = R.operator_actor_grpc_directive })
    "resumable";
  strength_of
    "keeper_down operator pause"
    (R.Operator_paused { operator_actor = R.operator_actor_keeper_down })
    "resumable";
  strength_of
    "transcript corruption"
    R.Transcript_corruption_reset_required
    "reset_required";
  strength_of "dead tombstone" R.Dead_tombstone "terminal"
;;

let replaced label = function
  | R.Replace reason -> reason
  | R.Keep_stronger { persisted; rejected } ->
    failf
      "%s: expected the request to apply, but %a was kept over %a"
      label
      R.pp
      persisted
      R.pp
      rejected
;;

let kept label = function
  | R.Keep_stronger { persisted; _ } -> persisted
  | R.Replace reason ->
    failf "%s: expected the persisted latch to stand, but %a applied" label R.pp reason
;;

let operator_grpc = R.Operator_paused { operator_actor = R.operator_actor_grpc_directive }
let operator_down = R.Operator_paused { operator_actor = R.operator_actor_keeper_down }

let test_no_persisted_latch_always_applies () =
  List.iter
    (fun (label, requested) ->
      let applied =
        replaced label (R.replace ~persisted:None ~requested)
      in
      check bool (label ^ " applies when nothing is persisted") true
        (R.equal requested applied))
    reasons
;;

let test_equal_strength_applies () =
  (* Re-pausing under a different operator actor is legitimate: both are
     resumable, so neither constrains recovery more than the other. *)
  let applied =
    replaced
      "keeper_down over grpc"
      (R.replace ~persisted:(Some operator_grpc) ~requested:operator_down)
  in
  check bool "the newer actor is recorded" true (R.equal operator_down applied);
  List.iter
    (fun (label, reason) ->
      let applied =
        replaced label (R.replace ~persisted:(Some reason) ~requested:reason)
      in
      check bool (label ^ " over itself applies") true (R.equal reason applied))
    reasons
;;

let test_stronger_request_upgrades () =
  List.iter
    (fun (label, persisted, requested) ->
      let applied =
        replaced label (R.replace ~persisted:(Some persisted) ~requested)
      in
      check bool (label ^ " upgrades") true (R.equal requested applied))
    [ ( "transcript over operator pause"
      , operator_down
      , R.Transcript_corruption_reset_required )
    ; "dead over operator pause", operator_grpc, R.Dead_tombstone
    ; ( "dead over transcript"
      , R.Transcript_corruption_reset_required
      , R.Dead_tombstone )
    ]
;;

let test_weaker_request_keeps_persisted () =
  List.iter
    (fun (label, persisted, requested) ->
      let stood = kept label (R.replace ~persisted:(Some persisted) ~requested) in
      check bool (label ^ " keeps the persisted latch") true (R.equal persisted stood))
    [ (* The live 2026-07-27 downgrade: masc_keeper_down on a
         transcript-corrupted keeper relabelled it as ordinarily paused, which
         re-armed generic resume over a checkpoint admission still rejects. *)
      ( "keeper_down over transcript"
      , R.Transcript_corruption_reset_required
      , operator_down )
    ; ( "grpc directive over transcript"
      , R.Transcript_corruption_reset_required
      , operator_grpc )
    ; "keeper_down over dead", R.Dead_tombstone, operator_down
    ; "grpc directive over dead", R.Dead_tombstone, operator_grpc
    ; ( "transcript over dead"
      , R.Dead_tombstone
      , R.Transcript_corruption_reset_required )
    ]
;;

let test_rejected_request_is_reported_not_dropped () =
  (* The caller must be able to say what was asked for and refused; a silent
     preserve reads as "the pause was recorded as requested". *)
  match
    R.replace
      ~persisted:(Some R.Transcript_corruption_reset_required)
      ~requested:operator_down
  with
  | R.Keep_stronger { persisted; rejected } ->
    check bool "persisted is reported" true
      (R.equal R.Transcript_corruption_reset_required persisted);
    check bool "the refused request is reported" true (R.equal operator_down rejected)
  | R.Replace reason -> failf "expected the persisted latch to stand, got %a" R.pp reason
;;

let () =
  run
    "keeper_latched_reason"
    [ ( "lifecycle-only latch"
      , [ test_case "wire round-trip" `Quick test_wire_round_trip
        ; test_case "stable JSON round-trip" `Quick test_json_round_trip
        ; test_case
            "retired failure latches fail closed"
            `Quick
            test_retired_failure_latches_fail_closed
        ; test_case "hash is deterministic" `Quick test_hash_is_deterministic
        ] )
    ; ( "strength ordering"
      , [ test_case "each variant states a strength" `Quick
            test_strength_is_assigned_per_variant
        ; test_case "no persisted latch always applies" `Quick
            test_no_persisted_latch_always_applies
        ; test_case "equal strength applies" `Quick test_equal_strength_applies
        ; test_case "a stronger request upgrades" `Quick test_stronger_request_upgrades
        ; test_case "a weaker request keeps the persisted latch" `Quick
            test_weaker_request_keeps_persisted
        ; test_case "a refused request is reported, not dropped" `Quick
            test_rejected_request_is_reported_not_dropped
        ] )
    ]
;;
