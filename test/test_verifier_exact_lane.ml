(* RFC-0361 D7(a) — the completion-authority judgement call runs on the
   dedicated [verifier_exact] exact-output lane: lane resolution returns the
   admitted slots in frozen declaration order, and [review] fails over in that
   order when a slot produces no usable verdict. *)

module AR = Masc.Task.Anti_rationalization
module Exact_output = Agent_core.Exact_output

let request : AR.review_request =
  { agent_name = "test-keeper"
  ; task_title = "finish concrete task"
  ; task_description = "Implement and verify a concrete task."
  ; completion_notes = "Implemented the change and ran the focused test."
  ; task_id = "test-task"
  ; evidence_refs = []
  }
;;

let configure_prompt_registry () =
  Prompt_registry.set_markdown_dir
    (Filename.concat (Masc_test_deps.find_project_root ()) "config/prompts")
;;

let with_lane_and_reviewer ~slots ~reviewer f =
  let saved_slots = Atomic.get Workspace_hooks.get_verifier_exact_lane_slot_ids_fn in
  let saved_reviewer = Atomic.get AR.run_llm_reviewer_fn in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Workspace_hooks.get_verifier_exact_lane_slot_ids_fn saved_slots;
      Atomic.set AR.run_llm_reviewer_fn saved_reviewer)
    (fun () ->
       Atomic.set Workspace_hooks.get_verifier_exact_lane_slot_ids_fn slots;
       Atomic.set AR.run_llm_reviewer_fn reviewer;
       f ())
;;

let review () =
  AR.review
    ~lookup:AR.No_lookup_surface
    ~base_path:(Filename.get_temp_dir_name ())
    request
;;

(* A reviewer that answers per slot and records the attempt order. *)
let recording_reviewer calls behaviors =
  fun ~base_path:_ ?sw:_ ~evaluator_runtime ~prompt:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~on_runtime_attempt_error:_ () ->
    calls := !calls @ [ evaluator_runtime ];
    match List.assoc_opt evaluator_runtime behaviors with
    | Some behavior -> behavior
    | None ->
      Error
        (Agent_core.Error.Internal
           ("unexpected evaluator slot " ^ evaluator_runtime))
;;

let rate_limited =
  Error
    (Agent_core.Error.Api
       (Agent_core.Error.Retry.RateLimited
          { retry_after = None; message = "rate limited" }))
;;

let budget_refusal =
  Error
    (Agent_core.Error.Agent
       (Agent_core.Error.HookExecutionFailed
          { hook_name = "model_input_projection"
          ; stage = "turn:parse"
          ; tool_name = None
          ; tool_use_id = None
          ; detail = "newest conversation atom does not fit the model input budget"
          }))
;;

let test_failover_follows_declared_slot_order () =
  let calls = ref [] in
  with_lane_and_reviewer
    ~slots:(fun () -> Ok [ "slot-a"; "slot-b"; "slot-c" ])
    ~reviewer:
      (recording_reviewer
         calls
         [ "slot-a", rate_limited; "slot-b", Ok (Some (AR.Approve "")) ])
    (fun () ->
       let result = review () in
       Alcotest.(check (list string))
         "attempts follow the declared slot order and stop at the first verdict"
         [ "slot-a"; "slot-b" ]
         !calls;
       Alcotest.(check string)
         "gate"
         "structured_tool"
         (AR.gate_to_string result.AR.gate);
       Alcotest.(check string)
         "the winning slot is the recorded evaluator runtime"
         "slot-b"
         result.evaluator_runtime;
       match result.verdict with
       | Some (AR.Approve _) -> ()
       | Some (AR.Reject reason) -> Alcotest.failf "unexpected reject: %s" reason
       | None -> Alcotest.fail "failover lost the second slot's verdict")
;;

let test_first_slot_success_never_fails_over () =
  let calls = ref [] in
  with_lane_and_reviewer
    ~slots:(fun () -> Ok [ "slot-a"; "slot-b" ])
    ~reviewer:(recording_reviewer calls [ "slot-a", Ok (Some (AR.Approve "")) ])
    (fun () ->
       let result = review () in
       Alcotest.(check (list string)) "one attempt only" [ "slot-a" ] !calls;
       Alcotest.(check string) "evaluator runtime" "slot-a" result.evaluator_runtime)
;;

let test_invalid_verdict_fails_over () =
  let calls = ref [] in
  with_lane_and_reviewer
    ~slots:(fun () -> Ok [ "slot-a"; "slot-b" ])
    ~reviewer:
      (recording_reviewer
         calls
         [ "slot-a", Ok None; "slot-b", Ok (Some (AR.Reject "missing evidence")) ])
    (fun () ->
       let result = review () in
       Alcotest.(check (list string))
         "a reply without a verdict tool call yields to the next slot"
         [ "slot-a"; "slot-b" ]
         !calls;
       Alcotest.(check string) "evaluator runtime" "slot-b" result.evaluator_runtime;
       match result.verdict with
       | Some (AR.Reject reason) ->
         Alcotest.(check string) "reason" "missing evidence" reason
       | Some (AR.Approve _) -> Alcotest.fail "unexpected approve"
       | None -> Alcotest.fail "failover lost the second slot's verdict")
;;

let test_exhaustion_preserves_any_retryable_attempt () =
  let calls = ref [] in
  with_lane_and_reviewer
    ~slots:(fun () -> Ok [ "slot-a"; "slot-b" ])
    ~reviewer:
      (recording_reviewer calls [ "slot-a", rate_limited; "slot-b", budget_refusal ])
    (fun () ->
       let result = review () in
       Alcotest.(check (list string)) "both slots tried" [ "slot-a"; "slot-b" ] !calls;
       Alcotest.(check string)
         "gate"
         "evaluator_unavailable"
         (AR.gate_to_string result.AR.gate);
       Alcotest.(check string)
         "the last attempted slot is the reported evaluator runtime"
         "slot-b"
         result.evaluator_runtime;
       Alcotest.(check (option bool))
         "a transient slot is not masked by a later non-retryable fallback"
         (Some true)
         result.evaluator_error_retryable;
       Alcotest.(check bool) "no fabricated verdict" true (Option.is_none result.verdict))
;;

let test_nested_runtime_retryable_attempt_survives_terminal_error () =
  with_lane_and_reviewer
    ~slots:(fun () -> Ok [ "slot-a" ])
    ~reviewer:
      (fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~prompt:_
           ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_
           ~on_runtime_attempt_error () ->
         on_runtime_attempt_error
           ~runtime_id:"glm.test-model"
           ~attempt:0
           (Agent_core.Error.Api
              (Agent_core.Error.Retry.RateLimited
                 { retry_after = None; message = "rate limited" }));
         budget_refusal)
    (fun () ->
       let result = review () in
       Alcotest.(check (option bool))
         "a nested transient candidate is not masked by its terminal fallback"
         (Some true)
         result.evaluator_error_retryable;
       Alcotest.(check string)
         "terminal fallback remains the reported reason"
         (match budget_refusal with
          | Error error -> Agent_core.Error.to_string error
          | Ok _ -> Alcotest.fail "budget refusal fixture must be an error")
         (Option.value result.fallback_reason ~default:""))
;;

let test_exhaustion_reports_all_nonretryable_attempts () =
  let calls = ref [] in
  with_lane_and_reviewer
    ~slots:(fun () -> Ok [ "slot-a"; "slot-b" ])
    ~reviewer:
      (recording_reviewer
         calls
         [ "slot-a", budget_refusal; "slot-b", budget_refusal ])
    (fun () ->
       let result = review () in
       Alcotest.(check (list string)) "both slots tried" [ "slot-a"; "slot-b" ] !calls;
       Alcotest.(check (option bool))
         "all typed evaluator errors are non-retryable"
         (Some false)
         result.evaluator_error_retryable)
;;

let test_unconfigured_lane_is_unavailable_not_rerouted () =
  with_lane_and_reviewer
    ~slots:
      (fun () ->
         Error
           "exact-output lane \"verifier_exact\" is not configured")
    ~reviewer:(recording_reviewer (ref []) [])
    (fun () ->
       let result = review () in
       Alcotest.(check string)
         "gate"
         "evaluator_unavailable"
         (AR.gate_to_string result.AR.gate);
       Alcotest.(check string)
         "no runtime is invented for a missing lane"
         "unresolved"
         result.evaluator_runtime;
       (* An unconfigured lane produces no evaluator call, so there is no
          typed error to classify. That is [None], not "retry": the lane is
          missing from configuration and repeating the review on a timer
          would not add it. *)
       Alcotest.(check (option bool))
         "no evaluator error to classify"
         None
         result.evaluator_error_retryable;
       match result.fallback_reason with
       | Some detail ->
         Alcotest.(check bool)
           "the deferral names the lane"
           true
           (String_util.contains_substring detail "verifier_exact")
       | None -> Alcotest.fail "unconfigured lane must carry a reason")
;;

let test_explicit_override_never_consults_the_lane () =
  let calls = ref [] in
  with_lane_and_reviewer
    ~slots:(fun () -> Error "lane must not be consulted")
    ~reviewer:(recording_reviewer calls [ "explicit-runtime", Ok (Some (AR.Approve "")) ])
    (fun () ->
       let result =
         AR.review
           ~evaluator_runtime:"explicit-runtime"
           ~lookup:AR.No_lookup_surface
           ~base_path:(Filename.get_temp_dir_name ())
           request
       in
       Alcotest.(check (list string)) "single attempt" [ "explicit-runtime" ] !calls;
       Alcotest.(check string)
         "evaluator runtime"
         "explicit-runtime"
         result.evaluator_runtime)
;;

(* ------------------------------------------------------------ *)
(* Lane resolution through the published exact-output registry  *)
(* ------------------------------------------------------------ *)

let verifier_catalog =
  {|
[[providers]]
id = "verifier_provider"
kind = "openai_compat"
base_url = "http://127.0.0.1:1"
request_path = "/v1/chat/completions"
api_key_env = ""
capabilities_base = "openai_chat_extended"

[[models]]
id_prefix = "verifier-model"
provider_name = "verifier_provider"
max_context_tokens = 8192
max_output_tokens = 1024
supports_response_format_json = true
supports_structured_output = false
input_per_million = 1.0

[[targets]]
id = "verifier-a"
provider_ref = "verifier_provider"
model_id = "verifier-model"

[[targets]]
id = "verifier-b"
provider_ref = "verifier_provider"
model_id = "verifier-model"
|}
;;

let load_verifier_snapshot () =
  let io : Exact_output.resolver_io = { getenv = (fun _ -> Ok None) } in
  match
    Exact_output.load_resolver_snapshot
      ~io
      ~target_binding_policy:Exact_output.Exclude_unbound_targets
      ~catalog:
        (Exact_output.Full_replacement
           { source = "test-verifier-lane"; contents = verifier_catalog })
      ()
  with
  | Ok snapshot -> snapshot
  | Error _ -> Alcotest.fail "verifier lane test catalog should load"
;;

(* Runs before any publication below: with no registry the judgement path
   defers loudly instead of inventing a runtime. *)
let test_unpublished_registry_is_an_explicit_error () =
  match Runtime.verifier_exact_lane_slot_ids () with
  | Error detail ->
    Alcotest.(check bool)
      "error explains the registry is not published"
      true
      (String_util.contains_substring detail "not been published")
  | Ok slots ->
    Alcotest.failf "unexpected slots without a published registry: %s"
      (String.concat ", " slots)
;;

let test_lane_resolution_preserves_frozen_order_and_drops_rejected_slots () =
  let snapshot = load_verifier_snapshot () in
  (match
     Runtime.publish_exact_output_registry
       ~lanes:
         [ { Runtime_schema.id = "verifier_exact"
           ; slot_ids = [ "verifier-b"; "verifier-missing"; "verifier-a" ]
           ; cli_slot_ids = []
           }
         ; { Runtime_schema.id = "auxiliary_exact"; slot_ids = [ "verifier-a" ]; cli_slot_ids = [] }
         ]
       snapshot
   with
   | Ok _ -> ()
   | Error detail -> Alcotest.failf "lane publication failed: %s" detail);
  match Runtime.verifier_exact_lane_slot_ids () with
  | Error detail -> Alcotest.failf "verifier_exact lane should resolve: %s" detail
  | Ok slots ->
    Alcotest.(check (list string))
      "admitted slots keep declaration order; the catalog-missing slot is dropped"
      [ "verifier-b"; "verifier-a" ]
      slots
;;

(* verifier_exact, 2026-09-02: an operator put the keeper-turn runtime id
   ollama_cloud.ollama-cloud-deepseek-v4-flash-0731 in the lane, and the boot
   report said the catalog had moved on. The diagnosis has to say which of
   the two registries the id belongs to. *)
let test_rejected_slot_diagnosis_names_a_runtime_id () =
  let slot : Runtime_exact_output_registry.rejected_slot =
    { lane_id = "verifier_exact"
    ; position = 2
    ; slot_id = "ollama_cloud.ollama-cloud-deepseek-v4-flash-0731"
    }
  in
  let as_runtime id =
    if String.equal id slot.slot_id then Some ("ollama_cloud", "deepseek-v4-flash:0731") else None
  in
  let classify ~declared_target_rejected ~configured_runtime =
    Runtime_exact_output_registry.For_testing.classify_rejected_slot
      slot
      ~declared_target_rejected
      ~configured_runtime
  in
  (match classify ~declared_target_rejected:(fun _ -> false) ~configured_runtime:as_runtime with
   | Runtime_exact_output_registry.Configured_runtime_only { provider_id; api_name } ->
     Alcotest.(check string) "provider" "ollama_cloud" provider_id;
     Alcotest.(check string) "api-name" "deepseek-v4-flash:0731" api_name
   | Runtime_exact_output_registry.Declared_target_binding_rejected
   | Runtime_exact_output_registry.Unknown_to_both_registries ->
     Alcotest.fail "a slot that is a configured runtime id must be diagnosed as one");
  (* A declared target whose binding was rejected wins over the runtime
     lookup even when the same string is also a runtime id. *)
  (match classify ~declared_target_rejected:(fun _ -> true) ~configured_runtime:as_runtime with
   | Runtime_exact_output_registry.Declared_target_binding_rejected -> ()
   | Runtime_exact_output_registry.Configured_runtime_only _
   | Runtime_exact_output_registry.Unknown_to_both_registries ->
     Alcotest.fail "a declared target with a rejected binding must be named as such");
  (match classify ~declared_target_rejected:(fun _ -> false) ~configured_runtime:(fun _ -> None) with
   | Runtime_exact_output_registry.Unknown_to_both_registries -> ()
   | Runtime_exact_output_registry.Configured_runtime_only _
   | Runtime_exact_output_registry.Declared_target_binding_rejected ->
     Alcotest.fail "an id no registry knows is unknown to both");
  (* Through a published registry: the fixture snapshot rejects no binding,
     so the verdict comes from the runtime lookup alone. *)
  let snapshot = load_verifier_snapshot () in
  (match
     Runtime.publish_exact_output_registry
       ~lanes:
         [ { Runtime_schema.id = "verifier_exact"
           ; slot_ids = [ "verifier-a"; "verifier-missing" ]
           ; cli_slot_ids = []
           }
         ]
       snapshot
   with
   | Ok _ -> ()
   | Error detail -> Alcotest.failf "lane publication failed: %s" detail);
  match Runtime_exact_output_registry.current () with
  | Error error ->
    Alcotest.failf
      "registry should be published: %s"
      (Runtime_exact_output_registry.publication_error_to_string error)
  | Ok registry ->
    (match Runtime_exact_output_registry.rejected_slots registry with
     | [ rejected ] ->
       Alcotest.(check string) "rejected slot" "verifier-missing" rejected.slot_id;
       (match
          Runtime_exact_output_registry.diagnose_rejected_slot
            registry
            rejected
            ~configured_runtime:(fun _ -> None)
        with
        | Runtime_exact_output_registry.Unknown_to_both_registries -> ()
        | Runtime_exact_output_registry.Configured_runtime_only _
        | Runtime_exact_output_registry.Declared_target_binding_rejected ->
          Alcotest.fail "a slot no registry knows is unknown to both");
       (match
          Runtime_exact_output_registry.diagnose_rejected_slot
            registry
            rejected
            ~configured_runtime:(fun _ -> Some ("ollama_cloud", "deepseek-v4-flash:0731"))
        with
        | Runtime_exact_output_registry.Configured_runtime_only _ -> ()
        | Runtime_exact_output_registry.Unknown_to_both_registries
        | Runtime_exact_output_registry.Declared_target_binding_rejected ->
          Alcotest.fail "a runtime id with no same-id target is Configured_runtime_only")
     | slots ->
       Alcotest.failf "expected one rejected slot, got %d" (List.length slots))
;;

let () =
  configure_prompt_registry ();
  Alcotest.run
    "verifier_exact_lane"
    [ ( "frozen-order failover"
      , [ Alcotest.test_case
            "failover follows declared slot order"
            `Quick
            test_failover_follows_declared_slot_order
        ; Alcotest.test_case
            "first slot success never fails over"
            `Quick
            test_first_slot_success_never_fails_over
        ; Alcotest.test_case
            "invalid verdict fails over"
            `Quick
            test_invalid_verdict_fails_over
        ; Alcotest.test_case
            "exhaustion preserves any retryable attempt"
            `Quick
            test_exhaustion_preserves_any_retryable_attempt
        ; Alcotest.test_case
            "exhaustion reports all non-retryable attempts"
            `Quick
            test_exhaustion_reports_all_nonretryable_attempts
        ; Alcotest.test_case
            "nested runtime retryable attempt survives terminal error"
            `Quick
            test_nested_runtime_retryable_attempt_survives_terminal_error
        ; Alcotest.test_case
            "unconfigured lane is unavailable, not rerouted"
            `Quick
            test_unconfigured_lane_is_unavailable_not_rerouted
        ; Alcotest.test_case
            "explicit override never consults the lane"
            `Quick
            test_explicit_override_never_consults_the_lane
        ] )
    ; ( "lane resolution"
      , [ Alcotest.test_case
            "unpublished registry is an explicit error"
            `Quick
            test_unpublished_registry_is_an_explicit_error
        ; Alcotest.test_case
            "resolution preserves frozen order and drops rejected slots"
            `Quick
            test_lane_resolution_preserves_frozen_order_and_drops_rejected_slots
        ; Alcotest.test_case
            "rejected slot diagnosis names a runtime id"
            `Quick
            test_rejected_slot_diagnosis_names_a_runtime_id
        ] )
    ]
;;
