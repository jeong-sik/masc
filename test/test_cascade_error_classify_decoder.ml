(* test/test_cascade_error_classify_decoder.ml

   Pins the typed-reason round-trip behavior of
   [Cascade_error_classify.classify_masc_internal_error_of_string] so a
   schema-drift payload (unknown reason tag or missing reason field)
   returns [None] instead of synthesizing a sentinel
   [Other_detail "unknown_cascade_reason"] / [Other_detail "missing_reason_field"]
   that downstream consumers could not distinguish from a real
   [Other_detail] cascade reason.

   Closes the §R1 gap from the 2026-05-20 consolidated state report. *)

module Classify = Masc_mcp.Cascade_error_classify
module Keeper_types = Masc_mcp.Keeper_types

let pp_internal_error fmt = function
  | None -> Format.fprintf fmt "None"
  | Some e ->
    Format.fprintf fmt "Some(%s)" (Classify.kind_of_masc_internal_error e)

let internal_error_testable =
  Alcotest.testable pp_internal_error ( = )

let wrap_masc_oas_error (payload : Yojson.Safe.t) : string =
  "[masc_oas_error] " ^ Yojson.Safe.to_string payload

(* --- positive round-trip cases --------------------------------------- *)

let test_roundtrip_other_detail () =
  (* [Other_detail msg] is a legitimate emitted variant for free-form
     cascade reasons (e.g. "all providers tried").  It must still
     decode losslessly even after the schema-drift hardening. *)
  let payload =
    `Assoc
      [ ("kind", `String "cascade_exhausted")
      ; ("cascade_name", `String "primary")
      ; ( "reason"
        , `Assoc
            [ ("tag", `String "other_detail")
            ; ("message", `String "all providers tried")
            ] )
      ]
  in
  let decoded =
    Classify.classify_masc_internal_error_of_string (wrap_masc_oas_error payload)
  in
  match decoded with
  | Some (Classify.Cascade_exhausted { cascade_name; reason }) ->
    Alcotest.(check string)
      "cascade name preserved"
      "primary"
      (Classify.cascade_name_to_string cascade_name);
    (match reason with
     | Keeper_types.Other_detail msg ->
       Alcotest.(check string) "Other_detail payload preserved" "all providers tried" msg
     | _ -> Alcotest.fail "expected Other_detail reason")
  | _ -> Alcotest.fail "expected Cascade_exhausted"

let test_roundtrip_structural_attempt_timeout () =
  let payload =
    `Assoc
      [ ("kind", `String "cascade_exhausted")
      ; ("cascade_name", `String "primary")
      ; ( "reason"
        , `Assoc
            [ ("tag", `String "structural_attempt_timeout")
            ; ("detail", `String "max_execution_time_s exceeded")
            ] )
      ]
  in
  let decoded =
    Classify.classify_masc_internal_error_of_string (wrap_masc_oas_error payload)
  in
  match decoded with
  | Some (Classify.Cascade_exhausted { reason; _ }) ->
    (match reason with
     | Keeper_types.Structural_attempt_timeout { detail } ->
       Alcotest.(check string)
         "Structural_attempt_timeout detail preserved"
         "max_execution_time_s exceeded"
         detail
     | _ -> Alcotest.fail "expected Structural_attempt_timeout")
  | _ -> Alcotest.fail "expected Cascade_exhausted"

let test_roundtrip_bare_string_reason () =
  (* Bare string reasons like "no_providers_available" decode through the
     [`String _] arm of [cascade_exhaustion_reason_of_json]. *)
  let payload =
    `Assoc
      [ ("kind", `String "cascade_exhausted")
      ; ("cascade_name", `String "secondary")
      ; ("reason", `String "no_providers_available")
      ]
  in
  let decoded =
    Classify.classify_masc_internal_error_of_string (wrap_masc_oas_error payload)
  in
  match decoded with
  | Some (Classify.Cascade_exhausted { reason; _ }) ->
    Alcotest.check
      (Alcotest.testable
         (fun fmt _ -> Format.fprintf fmt "reason")
         ( = ))
      "bare string reason decoded"
      Keeper_types.No_providers_available
      reason
  | _ -> Alcotest.fail "expected Cascade_exhausted"

let test_roundtrip_capacity_backpressure () =
  let payload =
    `Assoc
      [ ("kind", `String "capacity_exhausted")
      ; ("cascade_name", `String "primary")
      ; ("source", `String "client_capacity")
      ; ("detail", `String "client capacity key glm is full")
      ; ("retry_after_sec", `Float 2.5)
      ]
  in
  let decoded =
    Classify.classify_masc_internal_error_of_string (wrap_masc_oas_error payload)
  in
  match decoded with
  | Some
      (Classify.Capacity_backpressure
         { cascade_name; source; detail; retry_after_sec }) ->
    Alcotest.(check string)
      "cascade name preserved"
      "primary"
      (Classify.cascade_name_to_string cascade_name);
    Alcotest.(check string)
      "source preserved"
      "client_capacity"
      (Classify.capacity_backpressure_source_to_string source);
    Alcotest.(check string)
      "detail preserved"
      "client capacity key glm is full"
      detail;
    Alcotest.(check (option (float 0.001)))
      "retry_after preserved"
      (Some 2.5)
      retry_after_sec
  | _ -> Alcotest.fail "expected Capacity_backpressure"

(* --- schema-drift cases: must return None ---------------------------- *)

let test_unknown_reason_tag_decodes_to_none () =
  (* Emitter wrote a [tag] that the decoder does not know.  Previously
     this synthesized [Other_detail "unknown_cascade_reason"].  After
     the §R1 hardening the entire payload is opaque ([None]) so
     downstream typed pattern matches cannot mistake a sentinel for a
     real cascade reason. *)
  let payload =
    `Assoc
      [ ("kind", `String "cascade_exhausted")
      ; ("cascade_name", `String "primary")
      ; ( "reason"
        , `Assoc
            [ ("tag", `String "future_reason_not_yet_known")
            ; ("message", `String "drift")
            ] )
      ]
  in
  let decoded =
    Classify.classify_masc_internal_error_of_string (wrap_masc_oas_error payload)
  in
  Alcotest.check internal_error_testable
    "unknown reason tag → None (no sentinel synthesized)"
    None decoded

let test_missing_reason_field_decodes_to_none () =
  let payload =
    `Assoc
      [ ("kind", `String "cascade_exhausted")
      ; ("cascade_name", `String "primary")
      ]
  in
  let decoded =
    Classify.classify_masc_internal_error_of_string (wrap_masc_oas_error payload)
  in
  Alcotest.check internal_error_testable
    "missing reason field → None (no sentinel synthesized)"
    None decoded

let test_malformed_reason_payload_decodes_to_none () =
  (* "reason" is present but is an unexpected JSON shape (a bool). *)
  let payload =
    `Assoc
      [ ("kind", `String "cascade_exhausted")
      ; ("cascade_name", `String "primary")
      ; ("reason", `Bool true)
      ]
  in
  let decoded =
    Classify.classify_masc_internal_error_of_string (wrap_masc_oas_error payload)
  in
  Alcotest.check internal_error_testable
    "malformed reason payload → None (no sentinel synthesized)"
    None decoded

let () =
  Alcotest.run "cascade_error_classify_decoder"
    [ ( "round-trip"
      , [ Alcotest.test_case "Other_detail" `Quick test_roundtrip_other_detail
        ; Alcotest.test_case
            "Structural_attempt_timeout" `Quick
            test_roundtrip_structural_attempt_timeout
        ; Alcotest.test_case
            "bare string reason" `Quick test_roundtrip_bare_string_reason
        ; Alcotest.test_case
            "capacity backpressure" `Quick test_roundtrip_capacity_backpressure
        ] )
    ; ( "schema-drift → None"
      , [ Alcotest.test_case
            "unknown reason tag" `Quick test_unknown_reason_tag_decodes_to_none
        ; Alcotest.test_case
            "missing reason field"
            `Quick
            test_missing_reason_field_decodes_to_none
        ; Alcotest.test_case
            "malformed reason payload"
            `Quick
            test_malformed_reason_payload_decodes_to_none
        ] )
    ]
