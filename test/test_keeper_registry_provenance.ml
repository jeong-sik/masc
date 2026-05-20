(** RFC-0127 PR-1 — provenance carrier tests.

    PR-1 widens [Keeper_state_machine.Fiber_terminated] and
    [Keeper_registry.Provider_runtime_error] with optional
    [provider_id : string option] and [http_status : int option] fields.
    These tests verify:

    - the carrier preserves values across construction
    - [event_to_string] and [failure_reason_to_string] surface the fields
      with [provider=X http=N] suffix when set
    - the [None / None] forms remain byte-identical to pre-PR-1 output
    - JSON serializer round-trips the optional fields

    Data flow (cascade [Provider_error.ServerError] → these fields) is
    PR-2 scope; PR-1 only ships the typed carrier. *)

open Alcotest

module KSM = Masc_mcp.Keeper_state_machine
module KSMJ = Masc_mcp.Keeper_state_machine_json
module R = Masc_mcp.Keeper_registry

let test_fiber_terminated_carrier_none () =
  let ev =
    KSM.Fiber_terminated
      { outcome = "fiber_unresolved"
      ; provider_id = None
      ; http_status = None
      }
  in
  (check string)
    "event_to_string: None/None is byte-identical to pre-PR-1"
    "fiber_terminated(fiber_unresolved)"
    (KSM.event_to_string ev)

let test_fiber_terminated_carrier_some () =
  let ev =
    KSM.Fiber_terminated
      { outcome = "fiber_unresolved"
      ; provider_id = Some "runpod_mtp"
      ; http_status = Some 502
      }
  in
  let s = KSM.event_to_string ev in
  (check bool)
    "event_to_string contains provider=runpod_mtp"
    true
    (Astring.String.is_infix ~affix:"provider=runpod_mtp" s);
  (check bool)
    "event_to_string contains http=502"
    true
    (Astring.String.is_infix ~affix:"http=502" s)

let test_fiber_terminated_carrier_partial () =
  let ev =
    KSM.Fiber_terminated
      { outcome = "crash"
      ; provider_id = Some "glm_coding"
      ; http_status = None
      }
  in
  let s = KSM.event_to_string ev in
  (check bool)
    "event_to_string contains provider=glm_coding"
    true
    (Astring.String.is_infix ~affix:"provider=glm_coding" s);
  (check bool)
    "event_to_string does not contain http= when http_status = None"
    false
    (Astring.String.is_infix ~affix:"http=" s)

let test_provider_runtime_error_carrier_none () =
  let r =
    R.Provider_runtime_error
      { code = "provider_error"
      ; detail = "kimi unicode crash"
      ; provider_id = None
      ; http_status = None
      }
  in
  (check string)
    "failure_reason_to_string: None/None is byte-identical to pre-PR-1"
    "provider_runtime_error(provider_error:kimi unicode crash)"
    (R.failure_reason_to_string r)

let test_provider_runtime_error_carrier_some () =
  let r =
    R.Provider_runtime_error
      { code = "api_error_timeout"
      ; detail = "Timeout after 300.0s"
      ; provider_id = Some "runpod_mtp"
      ; http_status = Some 502
      }
  in
  let s = R.failure_reason_to_string r in
  (check bool)
    "failure_reason_to_string contains provider=runpod_mtp"
    true
    (Astring.String.is_infix ~affix:"provider=runpod_mtp" s);
  (check bool)
    "failure_reason_to_string contains http=502"
    true
    (Astring.String.is_infix ~affix:"http=502" s)

let test_json_serializer_none () =
  let ev =
    KSM.Fiber_terminated
      { outcome = "fiber_unresolved"
      ; provider_id = None
      ; http_status = None
      }
  in
  let json = KSMJ.event_to_json ev in
  let s = Yojson.Safe.to_string json in
  (check bool)
    "JSON does not include provider_id when None"
    false
    (Astring.String.is_infix ~affix:"provider_id" s);
  (check bool)
    "JSON does not include http_status when None"
    false
    (Astring.String.is_infix ~affix:"http_status" s)

let test_json_serializer_some () =
  let ev =
    KSM.Fiber_terminated
      { outcome = "fiber_unresolved"
      ; provider_id = Some "runpod_mtp"
      ; http_status = Some 502
      }
  in
  let json = KSMJ.event_to_json ev in
  let s = Yojson.Safe.to_string json in
  (check bool)
    "JSON includes provider_id when Some"
    true
    (Astring.String.is_infix ~affix:"\"provider_id\":\"runpod_mtp\"" s);
  (check bool)
    "JSON includes http_status when Some"
    true
    (Astring.String.is_infix ~affix:"\"http_status\":502" s)

let () =
  run "keeper_registry_provenance"
    [ ( "fiber_terminated_carrier"
      , [ test_case "none/none byte-identical" `Quick
            test_fiber_terminated_carrier_none
        ; test_case "some/some surfaces both" `Quick
            test_fiber_terminated_carrier_some
        ; test_case "partial (provider only)" `Quick
            test_fiber_terminated_carrier_partial
        ] )
    ; ( "provider_runtime_error_carrier"
      , [ test_case "none/none byte-identical" `Quick
            test_provider_runtime_error_carrier_none
        ; test_case "some/some surfaces both" `Quick
            test_provider_runtime_error_carrier_some
        ] )
    ; ( "json_serializer"
      , [ test_case "none omits fields" `Quick test_json_serializer_none
        ; test_case "some emits fields" `Quick test_json_serializer_some
        ] )
    ]
