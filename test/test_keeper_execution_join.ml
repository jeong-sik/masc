(** Tests for RFC-0233 PR-2: the in-flight [tool_use_id ↔ execution_id]
    join table ([Keeper_execution_join]) and the event bridge stamping
    that consumes it ([Keeper_event_bridge.native_event_to_json]). *)

open Alcotest
module Join = Masc.Keeper_execution_join
module Bridge = Masc.Keeper_event_bridge
module Error_json = Masc.Keeper_event_bridge_error_json

let member key json =
  match json with
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let payload_member key json =
  Option.bind (member "payload" json) (member key)

let string_of_field = function
  | Some (`String s) -> Some s
  | _ -> None

(* ── Join table semantics ─────────────────────────────── *)

let test_record_take_roundtrip () =
  Join.For_testing.clear ();
  Join.record ~tool_use_id:"tu-1" ~execution_id:"exec-1-0001";
  check (option string) "take returns the pair" (Some "exec-1-0001")
    (Join.take ~tool_use_id:"tu-1");
  check (option string) "take removes the entry" None
    (Join.take ~tool_use_id:"tu-1");
  check int "table empty after take" 0 (Join.For_testing.size ())

let test_empty_tool_use_id_ignored () =
  Join.For_testing.clear ();
  Join.record ~tool_use_id:"" ~execution_id:"exec-1-0002";
  check int "empty id records nothing" 0 (Join.For_testing.size ());
  check (option string) "empty id lookup is None" None (Join.take ~tool_use_id:"")

let test_missing_entry_is_none () =
  Join.For_testing.clear ();
  check (option string) "unknown id is None" None
    (Join.take ~tool_use_id:"tu-unknown")

let test_rerecord_overwrites () =
  Join.For_testing.clear ();
  Join.record ~tool_use_id:"tu-2" ~execution_id:"exec-1-000a";
  Join.record ~tool_use_id:"tu-2" ~execution_id:"exec-1-000b";
  check (option string) "last record wins" (Some "exec-1-000b")
    (Join.take ~tool_use_id:"tu-2")

(* ── Bridge stamping ──────────────────────────────────── *)

let mk_event ?caused_by payload : Agent_sdk.Event_bus.event =
  { meta =
      { correlation_id = "corr-1"
      ; run_id = "run-1"
      ; ts = 1781200000.0
      ; caused_by
      }
  ; payload
  }

let test_tool_called_carries_tool_use_id () =
  Join.For_testing.clear ();
  let json =
    Bridge.native_event_to_json
      (mk_event
         (Agent_sdk.Event_bus.ToolCalled
            { agent_name = "oas-r1"; tool_name = "Read"; tool_use_id = "tu-3"
            ; input = `Null; turn = 0 }))
    |> Option.get
  in
  check (option string) "payload tool_use_id" (Some "tu-3")
    (string_of_field (payload_member "tool_use_id" json));
  check bool "tool_called has no execution_id (mint happens after publish)"
    true
    (payload_member "execution_id" json = None)

let test_tool_completed_stamps_execution_id () =
  Join.For_testing.clear ();
  (* The hook records the pair before OAS publishes ToolCompleted. *)
  Join.record ~tool_use_id:"tu-4" ~execution_id:"exec-2-0001";
  let json =
    Bridge.native_event_to_json
      (mk_event ~caused_by:"run-called-1"
         (Agent_sdk.Event_bus.ToolCompleted
            { agent_name = "keeper-x-agent"; tool_name = "Read"
            ; tool_use_id = "tu-4"; output = Ok { content = "ok"; _meta = None }; turn = 1 }))
    |> Option.get
  in
  check (option string) "payload execution_id" (Some "exec-2-0001")
    (string_of_field (payload_member "execution_id" json));
  check (option string) "payload tool_use_id" (Some "tu-4")
    (string_of_field (payload_member "tool_use_id" json));
  check (option string) "envelope caused_by survives serialization"
    (Some "run-called-1")
    (string_of_field (member "caused_by" json));
  check int "entry consumed exactly once" 0 (Join.For_testing.size ())

let test_tool_completed_without_entry_omits_execution_id () =
  Join.For_testing.clear ();
  (* Worker/eval lanes never record a pair — absence by domain. *)
  let json =
    Bridge.native_event_to_json
      (mk_event
         (Agent_sdk.Event_bus.ToolCompleted
            { agent_name = "oas-worker"; tool_name = "Execute"
            ; tool_use_id = "tu-5"; output = Ok { content = "ok"; _meta = None }; turn = 2 }))
    |> Option.get
  in
  check bool "no execution_id field for non-keeper execution" true
    (payload_member "execution_id" json = None);
  check (option string) "tool_use_id still present" (Some "tu-5")
    (string_of_field (payload_member "tool_use_id" json))

let test_empty_tool_use_id_omitted_from_payload () =
  Join.For_testing.clear ();
  let json =
    Bridge.native_event_to_json
      (mk_event
         (Agent_sdk.Event_bus.ToolCalled
            { agent_name = "oas-r1"; tool_name = "Read"; tool_use_id = ""
            ; input = `Null; turn = 0 }))
    |> Option.get
  in
  check bool "empty provider id is omitted" true
    (payload_member "tool_use_id" json = None)

let test_agent_failed_matches_typed_sse_event () =
  let agent_name = "oas-r1" in
  let task_id = "task-failed-1" in
  let elapsed_s = 4.25 in
  let caused_by = "run-agent-started-1" in
  let error = Agent_sdk.Error.Internal "bridge failure" in
  let projection = Error_json.agent_failed_error_projection error in
  let actual =
    Bridge.native_event_to_json
      (mk_event
         ~caused_by
         (Agent_sdk.Event_bus.AgentFailed
            { agent_name; task_id; error; elapsed = elapsed_s }))
    |> Option.get
    |> Yojson.Safe.to_string
  in
  let expected =
    Sse_event.agent_failed
      ~caused_by
      ~ts_unix:1781200000.0
      ~correlation_id:"corr-1"
      ~run_id:"run-1"
      ~agent_name
      ~task_id
      ~elapsed_s
      ~error:projection.error
      ~error_domain:projection.error_domain
      ~error_code:projection.error_code
      ~error_retryable:projection.error_retryable
      ~error_detail:projection.error_detail
      ()
    |> Yojson.Safe.to_string
  in
  check string "agent_failed bridge matches typed constructor" expected actual

let test_authorization_errors_have_typed_projection () =
  let check_projection label expected_domain error =
    let projection = Error_json.agent_failed_error_projection error in
    check string (label ^ " domain") expected_domain projection.error_domain;
    check bool (label ^ " non-retryable") false projection.error_retryable;
    check (option string)
      (label ^ " variant")
      (Some "authorization_error")
      (string_of_field (member "variant" projection.error_detail))
  in
  check_projection
    "API authorization"
    "api"
    (Agent_sdk.Error.Api
       (Agent_sdk.Retry.AuthorizationError { message = "permission refused" }));
  check_projection
    "provider authorization"
    "provider"
    (Agent_sdk.Error.Provider
       (Llm_provider.Error.AuthorizationError
          { provider = "provider"; detail = "permission refused" }))

let () =
  run "keeper_execution_join"
    [ ( "join_table"
      , [ test_case "record/take roundtrip" `Quick test_record_take_roundtrip
        ; test_case "empty tool_use_id ignored" `Quick test_empty_tool_use_id_ignored
        ; test_case "missing entry is None" `Quick test_missing_entry_is_none
        ; test_case "re-record overwrites" `Quick test_rerecord_overwrites
        ] )
    ; ( "bridge_stamping"
      , [ test_case "tool_called carries tool_use_id" `Quick
            test_tool_called_carries_tool_use_id
        ; test_case "tool_completed stamps execution_id" `Quick
            test_tool_completed_stamps_execution_id
        ; test_case "non-keeper completion omits execution_id" `Quick
            test_tool_completed_without_entry_omits_execution_id
        ; test_case "empty tool_use_id omitted" `Quick
            test_empty_tool_use_id_omitted_from_payload
        ; test_case "agent_failed matches typed constructor" `Quick
            test_agent_failed_matches_typed_sse_event
        ; test_case "authorization errors have typed projection" `Quick
            test_authorization_errors_have_typed_projection
        ] )
    ]
