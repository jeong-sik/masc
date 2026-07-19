(** Closed OAS Tool Invocation projection in [Keeper_event_bridge]. *)

open Alcotest
module Bridge = Masc.Keeper_event_bridge
module Error_json = Masc.Keeper_event_bridge_error_json

let member key json =
  match json with
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let payload_member key json =
  Option.bind (member "payload" json) (member key)

let schedule_member key json =
  Option.bind (payload_member "schedule" json) (member key)

let string_of_field = function
  | Some (`String s) -> Some s
  | _ -> None

let int_of_field = function
  | Some (`Int value) -> Some value
  | _ -> None

(* ── Bridge projection ────────────────────────────────── *)

let mk_event ?caused_by payload : Agent_sdk.Event_bus.event =
  { meta =
      { correlation_id = "corr-1"
      ; run_id = "run-1"
      ; ts = 1781200000.0
      ; caused_by
      }
  ; payload
  }

let invocation ?(turn = 0) ?(planned_index = 0) tool_use_id =
  Agent_sdk.Tool.Invocation.create
    ~tool_use_id
    ~turn
    ~schedule:
      { planned_index
      ; batch_index = 0
      ; batch_size = 1
      ; execution_mode = Agent_sdk.Tool.Serial
      }

let test_tool_called_carries_tool_use_id () =
  let json =
    Bridge.native_event_to_json
      (mk_event
         (Agent_sdk.Event_bus.ToolCalled
            { invocation = invocation "tu-3"
            ; agent_name = "oas-r1"
            ; tool_name = "Read"
            ; input = `Null
            }))
    |> Option.get
  in
  check (option string) "payload tool_use_id" (Some "tu-3")
    (string_of_field (payload_member "tool_use_id" json));
  check (option int) "payload turn" (Some 0)
    (int_of_field (payload_member "turn" json));
  check (option int) "payload planned_index" (Some 0)
    (int_of_field (schedule_member "planned_index" json));
  check (option int) "payload batch_index" (Some 0)
    (int_of_field (schedule_member "batch_index" json));
  check (option int) "payload batch_size" (Some 1)
    (int_of_field (schedule_member "batch_size" json));
  check bool "OAS event does not claim a MASC execution identity"
    true
    (payload_member "execution_id" json = None)

let test_tool_completed_preserves_invocation_without_execution_id () =
  let json =
    Bridge.native_event_to_json
      (mk_event ~caused_by:"run-called-1"
         (Agent_sdk.Event_bus.ToolCompleted
            { invocation = invocation ~turn:1 ~planned_index:3 "tu-4"
            ; agent_name = "keeper-x-agent"
            ; tool_name = "Read"
            ; output = Ok { content = "ok"; _meta = None }
            }))
    |> Option.get
  in
  check bool "payload has no foreign execution_id" true
    (payload_member "execution_id" json = None);
  check (option string) "payload tool_use_id" (Some "tu-4")
    (string_of_field (payload_member "tool_use_id" json));
  check (option int) "payload exact turn" (Some 1)
    (int_of_field (payload_member "turn" json));
  check (option int) "payload exact planned_index" (Some 3)
    (int_of_field (schedule_member "planned_index" json));
  check (option string) "envelope caused_by survives serialization"
    (Some "run-called-1")
    (string_of_field (member "caused_by" json))

let test_tool_completed_without_entry_omits_execution_id () =
  (* Worker/eval lanes never record a pair — absence by domain. *)
  let json =
    Bridge.native_event_to_json
      (mk_event
         (Agent_sdk.Event_bus.ToolCompleted
            { invocation = invocation ~turn:2 "tu-5"
            ; agent_name = "oas-worker"
            ; tool_name = "Execute"
            ; output = Ok { content = "ok"; _meta = None }
            }))
    |> Option.get
  in
  check bool "no execution_id field for non-keeper execution" true
    (payload_member "execution_id" json = None);
  check (option string) "tool_use_id still present" (Some "tu-5")
    (string_of_field (payload_member "tool_use_id" json))

let test_empty_tool_use_id_is_preserved () =
  let json =
    Bridge.native_event_to_json
      (mk_event
         (Agent_sdk.Event_bus.ToolCalled
            { invocation = invocation ""
            ; agent_name = "oas-r1"
            ; tool_name = "Read"
            ; input = `Null
            }))
    |> Option.get
  in
  check (option string) "empty provider id remains exact evidence" (Some "")
    (string_of_field (payload_member "tool_use_id" json))

let test_agent_failed_matches_typed_sse_event () =
  let agent_name = "oas-r1" in
  let task_id = "task-failed-1" in
  let elapsed_s = 4.25 in
  let caused_by = "run-agent-started-1" in
  let error =
    Agent_sdk.Error.Agent
      (Agent_sdk.Error.HookExecutionFailed
         { hook_name = "post_tool_use"
         ; stage = "execute"
         ; tool_name = Some "Execute"
         ; tool_use_id = Some "tool-1"
         ; detail = "hook failed"
         })
  in
  let projection = Error_json.agent_failed_error_projection error in
  check (option string)
    "hook failure variant"
    (Some "hook_execution_failed")
    (string_of_field (member "variant" projection.error_detail));
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
  run "keeper_event_bridge"
    [ ( "tool_invocation_projection"
      , [ test_case "tool_called carries tool_use_id" `Quick
            test_tool_called_carries_tool_use_id
        ; test_case "tool_completed keeps OAS occurrence separate" `Quick
            test_tool_completed_preserves_invocation_without_execution_id
        ; test_case "non-keeper completion omits execution_id" `Quick
            test_tool_completed_without_entry_omits_execution_id
        ; test_case "empty tool_use_id preserved" `Quick
            test_empty_tool_use_id_is_preserved
        ; test_case "agent_failed matches typed constructor" `Quick
            test_agent_failed_matches_typed_sse_event
        ; test_case "authorization errors have typed projection" `Quick
            test_authorization_errors_have_typed_projection
        ] )
    ]
