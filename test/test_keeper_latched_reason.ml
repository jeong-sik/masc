open Alcotest
module R = Keeper_latched_reason

let reasons =
  [ ( "gRPC operator pause"
    , R.Operator_paused { operator_actor = R.operator_actor_grpc_directive } )
  ; ( "keeper_down operator pause"
    , R.Operator_paused { operator_actor = R.operator_actor_keeper_down } )
  ; "dead tombstone", R.Dead_tombstone
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
    ]
;;
