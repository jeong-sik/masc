open Alcotest

module Q = Masc.Keeper_approval_queue
module Worker = Masc.Hitl_summary_worker
module Schema = Masc.Keeper_structured_output_schema
module Fixture = Compaction_exact_output_fixture
module Exact_output = Agent_sdk.Exact_output

let yojson = testable Yojson.Safe.pretty_print Yojson.Safe.equal

let sample_entry : Q.pending_approval =
  { id = "approval-1"
  ; keeper_name = "keeper"
  ; tool_name = "external-effect"
  ; input_hash = "exact-input-hash"
  ; input =
      `Assoc
        [ "target", `String "document"
        ; "body", `String "hello"
        ; "api_key", `String "sk-test-secret"
        ]
  ; sequence = 1
  ; requested_at = 1780587600.0
  ; turn_id = None
  ; request_context =
      Some
        (`Assoc
           [ ( "initial"
             , `Assoc
                 [ "history_messages", `List [ `String "older turn" ]
                 ; "base_system_prompt", `String "base policy"
                 ; "turn_system_prompt", `String "turn policy"
                 ; "user_message", `String "inspect the exact requested operation"
                 ; "dynamic_context", `String "current context"
                 ; "runtime_id", `String "runtime"
                 ] )
           ; "completed_tool_calls", `List []
           ])
  ; task_id = None
  ; goal_id = None
  ; goal_ids = []
  ; continuation_channel = Keeper_continuation_channel.unrouted "test"
  ; audit_base_path = Filename.get_temp_dir_name ()
  ; summary_status = Q.Summary_not_requested
  ; exact_attempt = Q.Exact_unbound
  }
;;

let judgment_json judgment =
  `Assoc
    [ "context_summary", `String "The exact action matches visible context."
    ; "key_questions", `List [ `String "Is the target current?" ]
    ; "judgment", `String judgment
    ; "rationale", `String "The visible evidence supports this judgment."
    ]
;;

let test_parse_typed_judgments () =
  List.iter
    (fun (wire, expected) ->
       let summary =
         match
           Worker.For_testing.parse_summary
             ~generated_at:1780587600.0
             ~model_run_id:"exact-call-id"
             (judgment_json wire)
         with
         | Ok summary -> summary
         | Error reason -> fail reason
       in
       check bool wire true (summary.judgment = expected);
       check string "model_run_id is the exact call id" "exact-call-id" summary.model_run_id)
    [ "approve", Q.Approve; "deny", Q.Deny; "require_human", Q.Require_human ]
;;

let test_invalid_judgment_fails_loud () =
  match
    Worker.For_testing.parse_summary
      ~generated_at:1780587600.0
      ~model_run_id:"run"
      (judgment_json "maybe")
  with
  | Ok _ -> fail "unknown judgment unexpectedly parsed"
  | Error reason ->
    check bool "unknown judgment is explicit" true
      (Astring.String.is_infix ~affix:"maybe" reason)
;;

let test_judgment_parser_rejects_unknown_fields () =
  let json =
    match judgment_json "approve" with
    | `Assoc fields -> `Assoc (("unexpected", `String "retired") :: fields)
    | other -> other
  in
  match
    Worker.For_testing.parse_summary
      ~generated_at:1780587600.0
      ~model_run_id:"run"
      json
  with
  | Ok _ -> fail "unknown judgment field unexpectedly parsed"
  | Error reason ->
    check bool "unknown field is explicit" true
      (Astring.String.is_infix ~affix:"unexpected" reason)
;;

let test_schema_is_closed_nonhierarchical_contract () =
  let open Yojson.Safe.Util in
  let schema = Schema.hitl_context_summary_schema in
  let required = schema |> member "required" |> to_list |> List.map to_string in
  check
    (list string)
    "required fields"
    [ "context_summary"; "key_questions"; "judgment"; "rationale" ]
    required;
  check bool "additional properties disabled" false
    (schema |> member "additionalProperties" |> to_bool)
;;

let test_context_bundle_contains_exact_input_without_derived_classification () =
  let bundle =
    match Worker.For_testing.build_context_bundle ~entry:sample_entry with
    | Ok bundle -> bundle
    | Error error ->
      fail (Worker.For_testing.context_bundle_error_to_string error)
  in
  let open Yojson.Safe.Util in
  check yojson "exact input" sample_entry.input (bundle |> member "input");
  check yojson
    "exact outer-turn context"
    (Option.get sample_entry.request_context)
    (bundle |> member "request_context");
  let fields = bundle |> to_assoc in
  List.iter
    (fun field ->
       check bool ("does not reread " ^ field) false (List.mem_assoc field fields))
    [ "task"; "goals"; "chat_messages"; "partial_context"; "context_notes" ];
  check yojson "no derived classification" `Null (bundle |> member "classification");
  check yojson "no derived level" `Null (bundle |> member "level")
;;

let test_missing_request_context_is_terminal_before_admission () =
  match
    Worker.For_testing.build_context_bundle
      ~entry:{ sample_entry with request_context = None }
  with
  | Ok _ -> fail "missing exact request context produced an OAS payload"
  | Error Worker.For_testing.Exact_request_context_unavailable ->
    check string
      "failure is stable and explicit"
      "HITL summary: exact outer-turn request context is unavailable"
      (Worker.For_testing.context_bundle_error_to_string
         Worker.For_testing.Exact_request_context_unavailable)
;;

let test_gate_judgment_prompt_comes_from_registry () =
  Prompt_registry.set_markdown_dir
    (Masc_test_deps.source_path "config/prompts");
  match Worker.For_testing.system_prompt () with
  | Error detail -> fail ("Gate judgment prompt unavailable: " ^ detail)
  | Ok prompt -> check bool "prompt is non-empty" true (String.trim prompt <> "")
;;

let exact_registry () =
  let slot_ids = [ "hitl-slot-a"; "hitl-slot-b" ] in
  let fixtures : Fixture.target_fixture list =
    List.map
      (fun id -> { Fixture.id = id; base_url = "http://127.0.0.1:1" })
      slot_ids
  in
  let snapshot =
    Fixture.resolver_snapshot ~source:"hitl-worker-exact-fixture" fixtures
  in
  Fixture.publish_registry
    ~lane_id:Worker.For_testing.lane_id
    ~slot_ids
    snapshot
;;

let test_prepares_every_candidate_before_network () =
  Prompt_registry.set_markdown_dir
    (Masc_test_deps.source_path "config/prompts");
  let registry = exact_registry () in
  let prepared =
    match Worker.For_testing.prepare_lane ~registry ~entry:sample_entry with
    | Ok prepared -> prepared
    | Error error -> fail (Worker.For_testing.preparation_error_to_string error)
  in
  let observations = Worker.For_testing.observations prepared in
  check
    (list string)
    "lane order is preserved"
    [ "hitl-slot-a"; "hitl-slot-b" ]
    (List.map (fun observation -> observation.Worker.For_testing.slot_id) observations);
  List.iter
    (fun observation ->
       check bool "attempt is not dispatched" true
         (match observation.Worker.For_testing.phase with
          | Exact_output.Not_started -> true
          | Exact_output.Before_dispatch
          | Exact_output.Dispatch_started
          | Exact_output.Response_received
          | Exact_output.Terminal -> false);
       check int "dispatch count" 0 observation.dispatch_count)
    observations;
  check int "every attempt has a unique call id" (List.length observations)
    (observations
     |> List.map (fun (observation : Worker.For_testing.attempt_observation) -> observation.call_id)
     |> List.sort_uniq String.compare
     |> List.length);
  check int "one frozen catalog generation" 1
    (observations
     |> List.map (fun (observation : Worker.For_testing.attempt_observation) -> observation.catalog_generation_fingerprint)
     |> List.sort_uniq String.compare
     |> List.length);
  check int "one frozen catalog evidence document" 1
    (observations
     |> List.map (fun (observation : Worker.For_testing.attempt_observation) -> observation.catalog_evidence_sha256)
     |> List.sort_uniq String.compare
     |> List.length)
;;

let test_provenance_mismatch_matrix_fails_closed () =
  let expected : Worker.For_testing.provenance_evidence =
    { source_schema_fingerprint = "source-schema"
    ; effective_schema_fingerprint = Some "effective-schema"
    ; actual_assurance = Exact_output.Json_syntax_only
    ; catalog_generation_fingerprint = "catalog-generation"
    ; catalog_evidence_sha256 = "catalog-evidence"
    ; target_identity_fingerprint = "target-identity"
    }
  in
  check bool "identical provenance is accepted" true
    (Worker.For_testing.provenance_evidence_matches expected expected);
  let mismatches =
    [ ( "source schema fingerprint"
      , { expected with source_schema_fingerprint = "other-source-schema" } )
    ; ( "effective schema fingerprint"
      , { expected with effective_schema_fingerprint = None } )
    ; ( "actual assurance"
      , { expected with
          actual_assurance = Exact_output.Provider_schema_requested
        } )
    ; ( "catalog generation"
      , { expected with catalog_generation_fingerprint = "other-generation" } )
    ; ( "catalog evidence"
      , { expected with catalog_evidence_sha256 = "other-evidence" } )
    ; ( "target identity"
      , { expected with target_identity_fingerprint = "other-target" } )
    ]
  in
  List.iter
    (fun (dimension, actual) ->
       check bool dimension false
         (Worker.For_testing.provenance_evidence_matches expected actual))
    mismatches
;;

type lifecycle_observation =
  Worker.For_testing.attempt_observation

type lifecycle_probe =
  { execute_calls : string list ref
  ; release_calls : int ref
  ; gate_calls : int ref
  ; quarantines : Q.exact_attempt_quarantine_cause list ref
  }

let lifecycle_observation slot_id phase dispatch_count : lifecycle_observation =
  { slot_id
  ; call_id = "call-" ^ slot_id
  ; phase
  ; dispatch_count
  ; plan_fingerprint = "plan-" ^ slot_id
  ; request_body_sha256 = "body-" ^ slot_id
  ; catalog_generation_fingerprint = "catalog-generation"
  ; catalog_evidence_sha256 = "catalog-evidence"
  ; target_identity_fingerprint = "target-" ^ slot_id
  }
;;

let run_lifecycle_case
      ?(bind = fun _ -> Worker.For_testing.Lifecycle_fsync_completed)
      ?(release = fun _ -> Worker.For_testing.Lifecycle_fsync_completed)
      ?(fail = fun _ ~reason:_ -> Worker.For_testing.Lifecycle_fsync_completed)
      ?(quarantine =
        fun _ _ -> Worker.For_testing.Lifecycle_fsync_completed)
      ?(complete =
        fun _ _ -> Worker.For_testing.Lifecycle_fsync_completed)
      ~execute
      slot_ids
  =
  let execute_calls = ref [] in
  let release_calls = ref 0 in
  let gate_calls = ref 0 in
  let quarantines = ref [] in
  let effects : string Worker.For_testing.lifecycle_effects =
    { bind
    ; release =
        (fun observation ->
           incr release_calls;
           release observation)
    ; fail
    ; quarantine =
        (fun observation cause ->
           quarantines := !quarantines @ [ cause ];
           quarantine observation cause)
    ; complete
    ; execute =
        (fun slot_id ->
           execute_calls := !execute_calls @ [ slot_id ];
           execute slot_id)
    ; parse =
        (fun ~model_run_id output ->
           Worker.For_testing.parse_summary
             ~generated_at:1780587600.0
             ~model_run_id
             output)
    ; on_summary = (fun _ -> incr gate_calls)
    ; record_outcome = (fun _ -> ())
    ; protect = (fun action -> action ())
    ; report_write_issue = (fun ~operation:_ _ ~detail:_ -> ())
    }
  in
  let candidates =
    List.map
      (fun slot_id ->
         { Worker.For_testing.initial_observation =
             lifecycle_observation slot_id Exact_output.Not_started 0
         ; candidate = slot_id
         })
      slot_ids
  in
  let result = Worker.For_testing.run_lifecycle ~effects candidates in
  result, { execute_calls; release_calls; gate_calls; quarantines }
;;

let check_exact_cause label expected causes =
  let matches =
    match expected, causes with
    | Q.Exact_cancellation, [ Q.Exact_cancellation ]
    | Q.Exact_post_dispatch_failure, [ Q.Exact_post_dispatch_failure ]
    | Q.Exact_terminal_persistence_failure,
      [ Q.Exact_terminal_persistence_failure ] ->
      true
    | _ -> false
  in
  check bool label true matches
;;

let postdispatch slot_id =
  Worker.For_testing.Lifecycle_post_dispatch_failure
    (lifecycle_observation slot_id Exact_output.Terminal 1)
;;

let predispatch slot_id =
  Worker.For_testing.Lifecycle_before_dispatch_failure
    { observation =
        lifecycle_observation slot_id Exact_output.Before_dispatch 0
    ; reason = "typed pre-dispatch failure"
    }
;;

let exact_success slot_id =
  Worker.For_testing.Lifecycle_success
    { observation =
        lifecycle_observation slot_id Exact_output.Terminal 1
    ; output = judgment_json "approve"
    }
;;

let test_bind_fsync_allows_one_execute () =
  let _, probe =
    run_lifecycle_case
      ~execute:postdispatch
      [ "slot-a" ]
  in
  check (list string) "execute_once calls" [ "slot-a" ] !(probe.execute_calls)
;;

let test_bind_visible_forbids_execute () =
  let _, probe =
    run_lifecycle_case
      ~bind:(fun _ ->
        Worker.For_testing.Lifecycle_visible_unconfirmed "bind fsync unknown")
      ~execute:postdispatch
      [ "slot-a" ]
  in
  check (list string) "execute_once calls" [] !(probe.execute_calls)
;;

let test_predispatch_release_fsync_runs_next_slot () =
  let _, probe =
    run_lifecycle_case
      ~execute:(function
        | "slot-a" -> predispatch "slot-a"
        | slot_id -> postdispatch slot_id)
      [ "slot-a"; "slot-b" ]
  in
  check (list string)
    "ordered execute_once calls"
    [ "slot-a"; "slot-b" ]
    !(probe.execute_calls);
  check int "release count" 1 !(probe.release_calls)
;;

let test_release_visible_terminalizes_without_successor () =
  let _, probe =
    run_lifecycle_case
      ~release:(fun _ ->
        Worker.For_testing.Lifecycle_visible_unconfirmed "release fsync unknown")
      ~execute:predispatch
      [ "slot-a"; "slot-b" ]
  in
  check (list string) "successor was not executed" [ "slot-a" ] !(probe.execute_calls);
  check_exact_cause
    "release visibility is terminalized"
    Q.Exact_terminal_persistence_failure
    !(probe.quarantines)
;;

let test_postdispatch_failure_quarantines_without_failover () =
  let _, probe =
    run_lifecycle_case
      ~execute:postdispatch
      [ "slot-a"; "slot-b" ]
  in
  check (list string) "successor was not executed" [ "slot-a" ] !(probe.execute_calls);
  check_exact_cause
    "post-dispatch failure cause"
    Q.Exact_post_dispatch_failure
    !(probe.quarantines)
;;

let test_completion_visible_withholds_gate () =
  let _, probe =
    run_lifecycle_case
      ~complete:(fun _ _ ->
        Worker.For_testing.Lifecycle_visible_unconfirmed
          "completion fsync unknown")
      ~execute:exact_success
      [ "slot-a" ]
  in
  check int "Gate callbacks" 0 !(probe.gate_calls)
;;

let test_completion_fsync_calls_gate_once () =
  let _, probe =
    run_lifecycle_case
      ~execute:exact_success
      [ "slot-a" ]
  in
  check int "Gate callbacks" 1 !(probe.gate_calls)
;;

let test_cancellation_before_dispatch_is_terminal_without_failover () =
  let cancellation = Failure "caller cancelled" in
  let result, probe =
    run_lifecycle_case
      ~execute:(fun slot_id ->
        Worker.For_testing.Lifecycle_cancellation
          { observation =
              lifecycle_observation
                slot_id
                Exact_output.Before_dispatch
                0
          ; cancellation
          })
      [ "slot-a"; "slot-b" ]
  in
  check (list string) "successor was not executed" [ "slot-a" ] !(probe.execute_calls);
  check int "release count" 0 !(probe.release_calls);
  check bool "cancellation is returned for re-raise" true
    (Option.is_some result.cancellation);
  check_exact_cause
    "cancellation quarantine cause"
    Q.Exact_cancellation
    !(probe.quarantines)
;;

let test_readiness_resolves_exact_lane () =
  Prompt_registry.set_markdown_dir
    (Masc_test_deps.source_path "config/prompts");
  ignore (exact_registry () : Runtime_exact_output_registry.t);
  match Worker.readiness () with
  | Ok () -> ()
  | Error detail -> fail detail
;;

let test_readiness_fails_when_gate_prompt_is_missing () =
  let original_dir = Masc_test_deps.source_path "config/prompts" in
  let empty_dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      ("masc-hitl-prompt-readiness-" ^ string_of_int (Random.bits ()))
  in
  Unix.mkdir empty_dir 0o700;
  Fun.protect
    ~finally:(fun () ->
      Prompt_registry.set_markdown_dir original_dir;
      Unix.rmdir empty_dir)
    (fun () ->
       Prompt_registry.set_markdown_dir empty_dir;
       match Worker.readiness () with
       | Ok () -> fail "missing Gate prompt reported ready"
       | Error detail ->
         check bool "missing prompt is explicit" true
           (Astring.String.is_infix ~affix:"keeper.gate_judgment" detail))
;;

let () =
  run
    "Hitl_summary_worker"
    [ ( "exact judgment"
      , [ test_case "parse variants" `Quick test_parse_typed_judgments
        ; test_case "invalid judgment fails loud" `Quick test_invalid_judgment_fails_loud
        ; test_case
            "unknown judgment fields fail loud"
            `Quick
            test_judgment_parser_rejects_unknown_fields
        ; test_case
            "schema has no hierarchy"
            `Quick
            test_schema_is_closed_nonhierarchical_contract
        ; test_case
            "context carries exact input"
            `Quick
            test_context_bundle_contains_exact_input_without_derived_classification
        ; test_case
            "missing request context stops before admission"
            `Quick
            test_missing_request_context_is_terminal_before_admission
        ; test_case
            "Gate judgment prompt is registry-owned"
            `Quick
            test_gate_judgment_prompt_comes_from_registry
        ; test_case
            "all lane candidates are prepared before network"
            `Quick
            test_prepares_every_candidate_before_network
        ; test_case
            "all provenance mismatches fail closed"
            `Quick
            test_provenance_mismatch_matrix_fails_closed
        ; test_case
            "bind fsync allows one execute"
            `Quick
            test_bind_fsync_allows_one_execute
        ; test_case
            "bind visible forbids execute"
            `Quick
            test_bind_visible_forbids_execute
        ; test_case
            "predispatch release fsync runs next slot"
            `Quick
            test_predispatch_release_fsync_runs_next_slot
        ; test_case
            "release visible terminalizes without successor"
            `Quick
            test_release_visible_terminalizes_without_successor
        ; test_case
            "postdispatch failure quarantines without failover"
            `Quick
            test_postdispatch_failure_quarantines_without_failover
        ; test_case
            "completion visible withholds Gate"
            `Quick
            test_completion_visible_withholds_gate
        ; test_case
            "completion fsync calls Gate once"
            `Quick
            test_completion_fsync_calls_gate_once
        ; test_case
            "cancellation before dispatch is terminal"
            `Quick
            test_cancellation_before_dispatch_is_terminal_without_failover
        ; test_case
            "readiness resolves exact lane"
            `Quick
            test_readiness_resolves_exact_lane
        ; test_case
            "readiness fails when prompt is missing"
            `Quick
            test_readiness_fails_when_gate_prompt_is_missing
        ] )
    ]
;;
