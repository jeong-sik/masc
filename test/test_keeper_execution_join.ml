(** Tests for RFC-0233 PR-2: the in-flight [invocation ↔ execution_id]
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

let int_of_field = function
  | Some (`Int value) -> Some value
  | _ -> None

let invocation
      ?(turn = 0)
      ?(planned_index = 0)
      ?(batch_index = 0)
      ?(batch_size = 1)
      ?(execution_mode = Agent_core.Tool_contract.Serial)
      tool_use_id
  =
  Agent_core.Tool_contract.Invocation.create
    ~tool_use_id
    ~turn
    ~completion:Agent_core.Tool_contract.Continue_after_success
    ~schedule:
      { planned_index
      ; batch_index
      ; batch_size
      ; execution_mode
      }

(* ── Join table semantics ─────────────────────────────── *)

let test_record_take_roundtrip () =
  Join.For_testing.clear ();
  let invocation = invocation "tu-1" in
  Join.record ~invocation ~execution_id:"exec-1-0001";
  check (option string) "take returns the pair" (Some "exec-1-0001")
    (Join.take ~invocation);
  check (option string) "take removes the entry" None
    (Join.take ~invocation);
  check int "table empty after take" 0 (Join.For_testing.size ())

let test_blank_tool_use_id_joins_by_invocation () =
  Join.For_testing.clear ();
  let invocation = invocation "" in
  Join.record ~invocation ~execution_id:"exec-1-0002";
  check (option string)
    "blank provider id still joins"
    (Some "exec-1-0002")
    (Join.take ~invocation)

let test_missing_entry_is_none () =
  Join.For_testing.clear ();
  let invocation = invocation "tu-unknown" in
  check (option string) "unknown id is None" None
    (Join.take ~invocation)

let test_distinct_occurrences_with_repeated_id_do_not_overwrite () =
  Join.For_testing.clear ();
  let first = invocation ~turn:1 ~planned_index:0 "tu-2" in
  let second = invocation ~turn:1 ~planned_index:1 "tu-2" in
  Join.record ~invocation:first ~execution_id:"exec-1-000a";
  Join.record ~invocation:second ~execution_id:"exec-1-000b";
  check (option string)
    "second occurrence"
    (Some "exec-1-000b")
    (Join.take ~invocation:second);
  check (option string)
    "first occurrence remains"
    (Some "exec-1-000a")
    (Join.take ~invocation:first)

let test_abandoned_join_is_released_with_invocation () =
  Join.For_testing.clear ();
  let record_abandoned () =
    let abandoned = invocation ~turn:4 ~planned_index:2 "cancelled" in
    Join.record ~invocation:abandoned ~execution_id:"exec-abandoned"
  in
  record_abandoned ();
  Gc.full_major ();
  Gc.full_major ();
  check int "cancelled publication leaves no join entry" 0 (Join.For_testing.size ())

(* ── Bridge stamping ──────────────────────────────────── *)

let mk_event ?(event_id = "event-1") ?caused_by payload : Agent_core.Event_bus.event =
  let meta =
    Agent_core.Event_bus.mk_envelope
      ~event_id
      ~correlation_id:"corr-1"
      ~run_id:"run-1"
      ?caused_by
      ()
  in
  { meta = { meta with event_time = 1781200000.0; observed_at = 1781200000.5 }
  ; payload
  }

let test_tool_called_carries_tool_use_id () =
  Join.For_testing.clear ();
  let json =
    Bridge.native_event_to_json
      (mk_event
         (Agent_core.Event_bus.ToolCalled
            { invocation =
                invocation
                  ~batch_index:2
                  ~batch_size:3
                  ~execution_mode:Agent_core.Tool_contract.Concurrent
                  "tu-3"
            ; agent_name = "agent_core-r1"
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
    (int_of_field (payload_member "planned_index" json));
  check (option int) "payload batch_index" (Some 2)
    (int_of_field (payload_member "batch_index" json));
  check (option int) "payload batch_size" (Some 3)
    (int_of_field (payload_member "batch_size" json));
  check (option string) "payload execution_mode" (Some "concurrent")
    (string_of_field (payload_member "execution_mode" json));
  check bool "tool_called has no execution_id (mint happens after publish)"
    true
    (payload_member "execution_id" json = None)

let test_tool_completed_stamps_execution_id () =
  Join.For_testing.clear ();
  (* The hook records the pair before AGENT_CORE publishes ToolCompleted. *)
  let invocation = invocation ~turn:1 ~planned_index:3 "tu-4" in
  Join.record ~invocation ~execution_id:"exec-2-0001";
  let json =
    Bridge.native_event_to_json
      (mk_event ~caused_by:"run-called-1"
         (Agent_core.Event_bus.ToolCompleted
            { invocation
            ; agent_name = "keeper-x-agent"
            ; tool_name = "Read"
            ; output = Ok { content = "ok"; _meta = None }
            }))
    |> Option.get
  in
  check (option string) "payload execution_id" (Some "exec-2-0001")
    (string_of_field (payload_member "execution_id" json));
  check (option string) "payload tool_use_id" (Some "tu-4")
    (string_of_field (payload_member "tool_use_id" json));
  check (option int) "payload exact turn" (Some 1)
    (int_of_field (payload_member "turn" json));
  check (option int) "payload exact planned_index" (Some 3)
    (int_of_field (payload_member "planned_index" json));
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
         (Agent_core.Event_bus.ToolCompleted
            { invocation = invocation ~turn:2 "tu-5"
            ; agent_name = "agent_core-worker"
            ; tool_name = "Execute"
            ; output = Ok { content = "ok"; _meta = None }
            }))
    |> Option.get
  in
  check bool "no execution_id field for non-keeper execution" true
    (payload_member "execution_id" json = None);
  check (option string) "tool_use_id still present" (Some "tu-5")
    (string_of_field (payload_member "tool_use_id" json))

let test_tool_approval_completed_preserves_exact_occurrence () =
  let json =
    Bridge.native_event_to_json
      (mk_event
         (Agent_core.Event_bus.ToolApprovalCompleted
            { invocation = invocation ~turn:4 ~planned_index:2 "tu-approved"
            ; agent_name = "keeper-approval"
            ; tool_name = "Execute"
            ; approval = Agent_core.Hooks.Approved
            }))
    |> Option.get
  in
  check (option string)
    "typed event kind"
    (Some "tool_approval_completed")
    (string_of_field (member "event_type" json));
  check (option string)
    "closed approval result"
    (Some "approved")
    (string_of_field (payload_member "approval" json));
  check (option string)
    "exact tool occurrence"
    (Some "tu-approved")
    (string_of_field (payload_member "tool_use_id" json));
  check (option int)
    "exact invocation turn"
    (Some 4)
    (int_of_field (payload_member "turn" json));
  check (option int)
    "exact invocation index"
    (Some 2)
    (int_of_field (payload_member "planned_index" json));
  check bool
    "approval event does not copy tool input"
    true
    (payload_member "input" json = None)

let test_empty_tool_use_id_omitted_from_payload () =
  Join.For_testing.clear ();
  let json =
    Bridge.native_event_to_json
      (mk_event
         (Agent_core.Event_bus.ToolCalled
            { invocation = invocation ""
            ; agent_name = "agent_core-r1"
            ; tool_name = "Read"
            ; input = `Null
            }))
    |> Option.get
  in
  check bool "empty provider id is omitted" true
    (payload_member "tool_use_id" json = None)

let test_non_terminal_agent_outcomes_keep_distinct_wire_types () =
  let yielded =
    Bridge.native_event_to_json
      (mk_event
         (Agent_core.Event_bus.AgentYielded
            { agent_name = "keeper-yield"
            ; task_id = "run-yield"
            ; turn = 4
            ; elapsed = 2.5
            }))
    |> Option.get
  in
  check
    (option string)
    "yield wire kind"
    (Some "agent_yielded")
    (string_of_field (member "event_type" yielded));
  check (option int) "yield turn" (Some 4) (int_of_field (payload_member "turn" yielded));
  let request : Agent_core.Error.input_required =
    { request_id = "request-1"
    ; participant_name = Some "operator"
    ; question = "Continue?"
    ; schema = Some (`Assoc [ "type", `String "boolean" ])
    ; timeout_s = Some 30.0
    ; created_at = 1781200000.0
    }
  in
  let input_required =
    Bridge.native_event_to_json
      (mk_event
         (Agent_core.Event_bus.AgentInputRequired
            { agent_name = "keeper-input"
            ; task_id = "run-input"
            ; request
            ; elapsed = 3.5
            }))
    |> Option.get
  in
  check
    (option string)
    "input-required wire kind"
    (Some "agent_input_required")
    (string_of_field (member "event_type" input_required));
  check
    (option string)
    "input request id"
    (Some "request-1")
    (string_of_field (payload_member "request_id" input_required));
  check
    (option string)
    "input question"
    (Some "Continue?")
    (string_of_field (payload_member "question" input_required));
  check
    (option string)
    "input participant"
    (Some "operator")
    (string_of_field (payload_member "participant_name" input_required));
  check
    bool
    "input schema"
    true
    (payload_member "schema" input_required
     = Some (`Assoc [ "type", `String "boolean" ]));
  check
    bool
    "input timeout"
    true
    (payload_member "timeout_s" input_required = Some (`Float 30.0))

let terminal_projection_string_field ~label key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`String value) -> value
     | Some value ->
       Alcotest.failf
         "%s field %s expected string, got %s"
         label
         key
         (Yojson.Safe.to_string value)
     | None -> Alcotest.failf "%s field %s missing" label key)
  | value ->
    Alcotest.failf
      "%s error_detail expected object, got %s"
      label
      (Yojson.Safe.to_string value)
;;

let check_terminal_projection
      ~label
      ~secret
      ~expected_variant
      ~expected_tool_use_id
      error
  =
  let projection = Error_json.agent_failed_error_projection error in
  let fields = Error_json.agent_failed_error_fields error in
  let full_projection = Yojson.Safe.to_string (`Assoc fields) in
  Alcotest.(check string) (label ^ " summary") expected_variant projection.error;
  Alcotest.(check bool)
    (label ^ " top-level summary hides raw detail")
    false
    (String_util.contains_substring_ci projection.error secret);
  Alcotest.(check bool)
    (label ^ " full fields hide raw detail")
    false
    (String_util.contains_substring_ci full_projection secret);
  Alcotest.(check string)
    (label ^ " typed variant")
    expected_variant
    (terminal_projection_string_field
       ~label
       "variant"
       projection.error_detail);
  Alcotest.(check string)
    (label ^ " safe tool use id")
    expected_tool_use_id
    (terminal_projection_string_field
       ~label
       "tool_use_id"
       projection.error_detail);
  Alcotest.(check string)
    (label ^ " detail digest")
    Digestif.SHA256.(digest_string secret |> to_hex)
    (terminal_projection_string_field
       ~label
       "detail_digest"
       projection.error_detail)
;;

let test_terminal_agent_failure_projection_redacts_detail () =
  let effect_secret = "terminal-effect-secret-7fe8c90d" in
  check_terminal_projection
    ~label:"terminal effect"
    ~secret:effect_secret
    ~expected_variant:"terminal_tool_effect_failed"
    ~expected_tool_use_id:"tool-terminal-safe"
    (Agent_core.Error.Agent
       (Agent_core.Error.TerminalToolEffectFailed
          { tool_use_id = "tool-terminal-safe"
          ; effect_disposition = Agent_core.Error.proven_post_terminal_effect
          ; detail = effect_secret
          }));
  let durability_secret = "terminal-durability-secret-2cc19a31" in
  check_terminal_projection
    ~label:"terminal durability"
    ~secret:durability_secret
    ~expected_variant:"terminal_tool_durability_failed"
    ~expected_tool_use_id:"tool-durable-safe"
    (Agent_core.Error.Agent
       (Agent_core.Error.TerminalToolDurabilityFailed
          { invocation =
              invocation ~turn:9 ~planned_index:4 "tool-durable-safe"
          ; effect_disposition = Agent_core.Error.unknown_terminal_effect
          ; detail = durability_secret
          }))
;;

let test_agent_failed_keeps_canonical_envelope_and_typed_error () =
  let agent_name = "agent_core-r1" in
  let task_id = "task-failed-1" in
  let elapsed_s = 4.25 in
  let caused_by = "run-agent-started-1" in
  let error =
    Agent_core.Error.Agent
      (Agent_core.Error.HookExecutionFailed
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
         ~event_id:"event-agent-failed-1"
         ~caused_by
         (Agent_core.Event_bus.AgentFailed
            { agent_name; task_id; error; elapsed = elapsed_s }))
    |> Option.get
  in
  check (option string) "producer event identity" (Some "event-agent-failed-1")
    (string_of_field (member "event_id" actual));
  check (option string) "causation survives" (Some caused_by)
    (string_of_field (member "caused_by" actual));
  check (option string) "serialized error domain" (Some projection.error_domain)
    (string_of_field (payload_member "error_domain" actual));
  check bool "serialized typed detail" true
    (payload_member "error_detail" actual = Some projection.error_detail)

let test_publish_to_bridge_preserves_one_producer_identity () =
  Eio_main.run @@ fun _env ->
  let bus = Agent_core.Event_bus.create () in
  let config =
    Agent_core.Event_bus.subscription_config
      ~capacity:2
      ~overflow:Agent_core.Event_bus.Drop_oldest
    |> Result.get_ok
  in
  let subscription = Agent_core.Event_bus.subscribe ~config bus in
  let event =
    Agent_core.Event_bus.mk_event
      ~event_id:"event-publish-bridge-1"
      ~correlation_id:"corr-publish-bridge"
      ~run_id:"run-publish-bridge"
      (Agent_core.Event_bus.TurnStarted { agent_name = "keeper-a"; turn = 3 })
  in
  Agent_core.Event_bus.publish bus event;
  let delivered =
    match Agent_core.Event_bus.drain subscription with
    | [ delivered ] -> delivered
    | events -> failf "expected one delivered event, got %d" (List.length events)
  in
  let first = Bridge.native_event_to_json delivered |> Option.get in
  let retry = Bridge.native_event_to_json delivered |> Option.get in
  check (option string) "published identity reaches adapter"
    (Some "event-publish-bridge-1")
    (string_of_field (member "event_id" first));
  check string "re-serialization keeps exact occurrence identity"
    (Yojson.Safe.to_string first)
    (Yojson.Safe.to_string retry)

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
    (Agent_core.Error.Api
       (Agent_core.Retry.AuthorizationError { message = "permission refused" }));
  check_projection
    "provider authorization"
    "provider"
    (Agent_core.Error.Provider
       (Llm_provider.Error.AuthorizationError
          { provider = "provider"; detail = "permission refused" }))

let test_request_body_too_large_projection_preserves_bounds () =
  let projection =
    Error_json.agent_failed_error_projection
      (Agent_core.Error.Api
         (Agent_core.Retry.InvalidRequest
            { message = "request body too large"
            ; reason =
                Agent_core.Retry.Request_body_too_large
                  { actual_bytes = 1_671_330; limit_bytes = 1_048_576 }
            }))
  in
  check
    (option string)
    "typed variant"
    (Some "invalid_request")
    (string_of_field (member "variant" projection.error_detail));
  check
    (option string)
    "typed reason"
    (Some "request_body_too_large")
    (string_of_field (member "reason" projection.error_detail));
  check
    (option int)
    "actual request bytes"
    (Some 1_671_330)
    (int_of_field (member "actual_bytes" projection.error_detail));
  check
    (option int)
    "request byte limit"
    (Some 1_048_576)
    (int_of_field (member "limit_bytes" projection.error_detail))

let test_provider_request_body_refusal_projection_preserves_status () =
  let projection =
    Error_json.agent_failed_error_projection
      (Agent_core.Error.Api
         (Agent_core.Retry.InvalidRequest
            { message = "payload too large"
            ; reason =
                Agent_core.Retry.Request_body_refused_by_provider { status = 413 }
            }))
  in
  check
    (option string)
    "typed variant"
    (Some "invalid_request")
    (string_of_field (member "variant" projection.error_detail));
  check
    (option string)
    "typed reason"
    (Some "request_body_refused_by_provider")
    (string_of_field (member "reason" projection.error_detail));
  check
    (option int)
    "provider refusal status"
    (Some 413)
    (int_of_field (member "status" projection.error_detail));
  check
    bool
    "unknown byte limit is not fabricated"
    true
    (Option.is_none (member "limit_bytes" projection.error_detail))

let test_input_capacity_projection_preserves_evidence () =
  let constraint_ =
    Llm_provider.Serving_constraint.make
      ~source_kind:Llm_provider.Serving_constraint.Probe
      ~source_ref:"probe://incident/2793"
      ~checked_at_unix_s:100
      ~confidence:Llm_provider.Serving_constraint.High
      ~expires_at_unix_s:200
      ~accepted_through:524298
      ~rejected_from:524299
      ()
    |> Result.get_ok
  in
  let projection =
    Error_json.agent_failed_error_projection
      (Agent_core.Error.Api
         (Agent_core.Retry.InputCapacity
            { message = "typed capacity"
            ; constraint_
            ; reason =
                Agent_core.Retry.Serving_constraint_rejected
                  (Llm_provider.Serving_constraint.Input_rejected
                     { input_tokens = 524299
                     ; accepted_through = 524298
                     ; rejected_from = 524299
                     })
            }))
  in
  check
    (option string)
    "typed variant"
    (Some "input_capacity")
    (string_of_field (member "variant" projection.error_detail));
  let constraint_json = member "constraint" projection.error_detail |> Option.get in
  check
    (option int)
    "accepted-through evidence"
    (Some 524298)
    (int_of_field (member "accepted_through" constraint_json));
  check
    (option string)
    "probe provenance"
    (Some "probe://incident/2793")
    (string_of_field (member "source_ref" constraint_json));
  let reason_json = member "reason" projection.error_detail |> Option.get in
  check
    (option string)
    "typed reason"
    (Some "input_rejected")
    (string_of_field (member "kind" reason_json))

(* [Retry.Timeout] carries a typed phase that separates an admission or queue
   wait from a streaming stall. The arm bound only [message], so every timeout
   reached the wire indistinguishable from every other one. *)
let test_timeout_projection_preserves_phase () =
  let projection =
    Error_json.agent_failed_error_projection
      (Agent_core.Error.Api
         (Agent_core.Retry.Timeout
            { message = "per-provider timeout after 90.0s"
            ; phase = Some Llm_provider.Http_client.Admission
            }))
  in
  check
    (option string)
    "typed variant"
    (Some "timeout")
    (string_of_field (member "variant" projection.error_detail));
  check
    (option string)
    "typed phase"
    (Some
       (Llm_provider.Http_client.timeout_phase_to_label
          Llm_provider.Http_client.Admission))
    (string_of_field (member "timeout_phase" projection.error_detail))

(* An absent phase stays absent on the wire. Naming one would report a phase
   the provider never attributed. *)
let test_timeout_projection_without_phase_reports_null () =
  let projection =
    Error_json.agent_failed_error_projection
      (Agent_core.Error.Api
         (Agent_core.Retry.Timeout { message = "unattributed timeout"; phase = None }))
  in
  check
    (option string)
    "typed variant"
    (Some "timeout")
    (string_of_field (member "variant" projection.error_detail));
  check
    bool
    "phase is null, not a guess"
    true
    (match member "timeout_phase" projection.error_detail with
     | Some `Null -> true
     | Some _ | None -> false)

let () =
  run "keeper_execution_join"
    [ ( "join_table"
      , [ test_case "record/take roundtrip" `Quick test_record_take_roundtrip
        ; test_case "blank tool_use_id joins by invocation" `Quick
            test_blank_tool_use_id_joins_by_invocation
        ; test_case "missing entry is None" `Quick test_missing_entry_is_none
        ; test_case "repeated ids keep distinct occurrences" `Quick
            test_distinct_occurrences_with_repeated_id_do_not_overwrite
        ; test_case "cancelled invocation releases abandoned join" `Quick
            test_abandoned_join_is_released_with_invocation
        ] )
    ; ( "bridge_stamping"
      , [ test_case "tool_called carries tool_use_id" `Quick
            test_tool_called_carries_tool_use_id
        ; test_case "tool_completed stamps execution_id" `Quick
            test_tool_completed_stamps_execution_id
        ; test_case "non-keeper completion omits execution_id" `Quick
            test_tool_completed_without_entry_omits_execution_id
        ; test_case "tool approval preserves exact occurrence" `Quick
            test_tool_approval_completed_preserves_exact_occurrence
        ; test_case "empty tool_use_id omitted" `Quick
            test_empty_tool_use_id_omitted_from_payload
        ; test_case "non-terminal outcomes keep distinct wire types" `Quick
            test_non_terminal_agent_outcomes_keep_distinct_wire_types
        ; test_case "agent_failed keeps canonical envelope" `Quick
            test_agent_failed_keeps_canonical_envelope_and_typed_error
        ; test_case "publish to bridge preserves producer identity" `Quick
            test_publish_to_bridge_preserves_one_producer_identity
        ; test_case "terminal agent failures redact raw detail" `Quick
            test_terminal_agent_failure_projection_redacts_detail
        ; test_case "authorization errors have typed projection" `Quick
            test_authorization_errors_have_typed_projection
        ; test_case "request body size preserves typed bounds" `Quick
            test_request_body_too_large_projection_preserves_bounds
        ; test_case "provider request body refusal preserves status" `Quick
            test_provider_request_body_refusal_projection_preserves_status
        ; test_case "input capacity preserves typed evidence" `Quick
            test_input_capacity_projection_preserves_evidence
        ; test_case "timeout preserves typed phase" `Quick
            test_timeout_projection_preserves_phase
        ; test_case "unattributed timeout reports null phase" `Quick
            test_timeout_projection_without_phase_reports_null
        ] )
    ]
