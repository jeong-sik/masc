(** Codec tests for [Compaction_trigger].

    The trigger decoder stays a durable reader: dashboards decode historical
    "pre_compact" records via [of_detail_json]. *)

open Alcotest

let test_provider_overflow_trigger_roundtrip () =
  let trigger = Compaction_trigger.Provider_overflow { limit_tokens = Some 200_000 } in
  check string "typed trigger label" "provider_overflow" (Compaction_trigger.to_label trigger);
  List.iter
    (fun expected ->
       match
         Compaction_trigger.of_detail_json (Compaction_trigger.to_detail_json expected)
       with
       | Ok actual when actual = expected -> ()
       | Ok _ | Error _ -> fail "typed compaction trigger did not round-trip")
    [ trigger
    ; Compaction_trigger.Provider_overflow { limit_tokens = None }
    ; Compaction_trigger.Request_body_over_capacity
        { actual_bytes = 1_048_577; limit_bytes = 1_048_576 }
    ; Compaction_trigger.Request_body_refused_by_provider { status = 413 }
    ; Compaction_trigger.Serving_input_capacity
        (Compaction_trigger.Boundary_unknown
           { input_tokens = 524_299
           ; accepted_through = 524_298
           ; rejected_from = None
           })
    ; Compaction_trigger.Serving_input_capacity
        (Compaction_trigger.Boundary_unknown
           { input_tokens = 524_299
           ; accepted_through = 524_298
           ; rejected_from = Some 524_300
           })
    ; Compaction_trigger.Serving_input_capacity
        (Compaction_trigger.Input_rejected
           { input_tokens = 524_300
           ; accepted_through = 524_298
           ; rejected_from = 524_299
           })
    ; Compaction_trigger.Manual
    ];
  let decode_serving ~reason ~input_tokens ~accepted_through ~rejected_from =
    Compaction_trigger.of_detail_json
      (`Assoc
        [ "kind", `String "serving_input_capacity"
        ; "reason", `String reason
        ; "input_tokens", `Int input_tokens
        ; "accepted_through", `Int accepted_through
        ; "rejected_from", `Int rejected_from
        ])
  in
  (match
     decode_serving
       ~reason:"boundary_unknown"
       ~input_tokens:524_300
       ~accepted_through:524_298
       ~rejected_from:524_299
   with
   | Error
       (Compaction_trigger.Invalid_boundary_unknown
          { input_tokens = 524_300; rejected_from = 524_299 } as error) ->
     check
       string
       "boundary_unknown diagnostic states its valid side"
       "serving input capacity boundary_unknown requires rejected_from > input_tokens, got input=524300 rejected=524299"
       (Compaction_trigger.decode_error_to_string error)
   | Ok _ | Error _ ->
     fail "boundary_unknown admitted a rejection at or below the measured input");
  match
    decode_serving
      ~reason:"input_rejected"
      ~input_tokens:524_300
      ~accepted_through:524_298
      ~rejected_from:524_301
  with
  | Error
      (Compaction_trigger.Invalid_input_rejected_boundary
         { input_tokens = 524_300
         ; accepted_through = 524_298
         ; rejected_from = Some 524_301
         } as error) ->
    check
      string
      "input_rejected diagnostic states its valid interval"
      "serving input capacity input_rejected requires accepted_through < rejected_from <= input_tokens, got input=524300 accepted=524298 rejected=524301"
      (Compaction_trigger.decode_error_to_string error)
  | Ok _ | Error _ ->
    fail "input_rejected admitted a boundary above the measured input"
;;

let test_request_body_over_capacity_rejects_non_refusals () =
  let decode fields =
    Compaction_trigger.of_detail_json
      (`Assoc (("kind", `String "request_body_over_capacity") :: fields))
  in
  (* The label asserts actual > limit. A record that satisfies the field shape but
     not the comparison describes a request that fit, so decoding it would put a
     capacity trigger in front of a compaction that had no capacity reason. *)
  (match decode [ "actual_bytes", `Int 100; "limit_bytes", `Int 100 ] with
   | Error
       (Compaction_trigger.Request_body_within_capacity
          { actual_bytes = 100; limit_bytes = 100 }) -> ()
   | Ok _ | Error _ -> fail "an equal-size request body was admitted as over capacity");
  (match decode [ "actual_bytes", `Int 200 ] with
   | Error (Compaction_trigger.Missing_request_body_bytes "limit_bytes") -> ()
   | Ok _ | Error _ -> fail "a trigger missing limit_bytes was admitted");
  (match decode [ "actual_bytes", `Int 0; "limit_bytes", `Int 10 ] with
   | Error (Compaction_trigger.Invalid_request_body_bytes "actual_bytes") -> ()
   | Ok _ | Error _ -> fail "a zero-byte body was admitted as a measurement");
  match
    decode
      [ "actual_bytes", `Int 200; "limit_bytes", `Int 100; "limit_tokens", `Int 5 ]
  with
  | Error (Compaction_trigger.Unknown_field "limit_tokens") -> ()
  | Ok _ | Error _ -> fail "the token field was accepted on the byte axis"
;;

let test_retired_trigger_kinds_are_rejected () =
  let decode kind =
    Compaction_trigger.of_detail_json (`Assoc [ "kind", `String kind ])
  in
  List.iter
    (fun kind ->
       match decode kind with
       | Error (Compaction_trigger.Unknown_kind actual)
         when String.equal actual kind -> ()
       | Ok _ | Error _ -> failf "retired trigger %s was not explicitly rejected" kind)
    [ "ratio"; "messages"; "tokens" ];
  match
    Compaction_trigger.of_detail_json
      (`Assoc [ "kind", `String "provider_overflow" ])
  with
  | Error Compaction_trigger.Missing_provider_limit -> ()
  | Ok _ | Error _ -> fail "provider overflow without limit_tokens was admitted"
;;

let test_malformed_trigger_details_are_typed_errors () =
  let check_error message expected json =
    match Compaction_trigger.of_detail_json json with
    | Error actual when actual = expected -> ()
    | Ok _ | Error _ -> fail message
  in
  check_error
    "non-object trigger detail was admitted"
    Compaction_trigger.Expected_object
    (`String "manual");
  check_error
    "missing trigger kind was admitted"
    Compaction_trigger.Missing_kind
    (`Assoc []);
  check_error
    "unknown manual field was admitted"
    (Compaction_trigger.Unknown_field "limit_tokens")
    (`Assoc [ "kind", `String "manual"; "limit_tokens", `Null ]);
  check_error
    "unknown provider field was admitted"
    (Compaction_trigger.Unknown_field "extra")
    (`Assoc
      [ "kind", `String "provider_overflow"
      ; "limit_tokens", `Int 200_000
      ; "extra", `Null
      ]);
  check_error
    "duplicate trigger kind was admitted"
    (Compaction_trigger.Duplicate_field "kind")
    (`Assoc [ "kind", `String "manual"; "kind", `String "manual" ]);
  check_error
    "duplicate provider limit was admitted"
    (Compaction_trigger.Duplicate_field "limit_tokens")
    (`Assoc
      [ "kind", `String "provider_overflow"
      ; "limit_tokens", `Int 200_000
      ; "limit_tokens", `Int 200_000
      ]);
  check_error
    "non-string trigger kind was admitted"
    Compaction_trigger.Invalid_kind
    (`Assoc [ "kind", `Int 1 ]);
  List.iter
    (fun limit ->
       check_error
         "invalid provider limit was admitted"
         Compaction_trigger.Invalid_provider_limit
         (`Assoc [ "kind", `String "provider_overflow"; "limit_tokens", limit ]))
    [ `Int 0; `Int (-1); `String "200000" ]
;;

let () =
  run "keeper_overflow_recovery" [
    "compaction-trigger-codec",
    [ test_case "provider overflow trigger codec" `Quick
        test_provider_overflow_trigger_roundtrip;
      test_case "retired trigger kinds rejected" `Quick
        test_retired_trigger_kinds_are_rejected;
      test_case "request body over capacity rejects non-refusals" `Quick
        test_request_body_over_capacity_rejects_non_refusals;
      test_case "malformed trigger details are typed errors" `Quick
        test_malformed_trigger_details_are_typed_errors;
    ]
  ]
