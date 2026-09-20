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
  ; evidence_images = []
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

let review_with (req : AR.review_request) () =
  AR.review
    ~question:
      { AR.completion_contract = None
      ; required_evidence = []
      ; evidence_posture = AR.Note_only
      ; few_shot_block = ""
      }
    ~lookup:AR.No_lookup_surface
    ~base_path:(Filename.get_temp_dir_name ())
    req
;;

let review () = review_with request ()

(* A reviewer that answers per slot and records the attempt order. *)
let recording_reviewer calls behaviors =
  fun ~base_path:_ ?sw:_ ~evaluator_runtime ~prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~on_runtime_attempt_error:_ () ->
    calls := !calls @ [ evaluator_runtime ];
    match List.assoc_opt evaluator_runtime behaviors with
    | Some behavior -> Result.map
        (fun verdict -> {AR.selected_runtime_id=evaluator_runtime;verdict}) behavior
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
           ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_
           ~on_runtime_attempt_error () ->
         on_runtime_attempt_error
           ~runtime_id:"glm.test-model"
           ~attempt:0
           ~dispatch:Masc.Keeper_attempt_dispatch.Dispatched
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

(* RFC-0436 §4.3: recorded images ride to the reviewer as attached blocks
   after the prompt text. An imageless request sends no blocks at all — the
   prompt string stays the whole goal, as before this channel existed. *)
let image_request =
  { request with
    evidence_images =
      [ { AR.image_reference = "artifact:shot.png"
        ; image_sha256 = "e3b0c442"
        ; image_bytes = 3
        ; image_media_type = "image/png"
        ; image_body_base64 = "aGk="
        }
      ]
  }
;;

let test_recorded_images_ride_to_the_reviewer_as_blocks () =
  let received = ref None in
  with_lane_and_reviewer
    ~slots:(fun () -> Ok [ "slot-a" ])
    ~reviewer:
      (fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~prompt:_ ?goal_blocks
           ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_
           ~on_runtime_attempt_error:_ () ->
         received := goal_blocks;
         Ok {AR.selected_runtime_id="slot-a";verdict=Some (AR.Approve "")})
    (fun () ->
       ignore (review_with image_request ());
       (match !received with
        | Some
            [ Agent_core.Types.Text prompt
            ; Agent_core.Types.Image { media_type; data; _ } ] ->
          Alcotest.(check string)
            "the image block carries the recorded media type" "image/png"
            media_type;
          Alcotest.(check string)
            "the image block carries the base64 body" "aGk=" data;
          Alcotest.(check bool) "the prompt text rides as the first block" true
            (String.length prompt > 0)
        | blocks ->
          Alcotest.failf "expected the prompt text and one image block, got %s"
            (match blocks with
             | None -> "no blocks"
             | Some blocks ->
               Printf.sprintf "%d blocks" (List.length blocks)));
       ignore (review ());
       Alcotest.(check bool) "an imageless review sends no blocks" true
         (!received = None))
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
           ~question:
             { AR.completion_contract = None
             ; required_evidence = []
             ; evidence_posture = AR.Note_only
             ; few_shot_block = ""
             }
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

let with_configured_verifier_cli f =
  let saved = Runtime.For_testing.snapshot () in
  let path = Filename.temp_file "verifier-cli-runtime-" ".toml" in
  Fun.protect ~finally:(fun () -> Runtime.For_testing.restore saved; Sys.remove path) (fun () ->
    Out_channel.with_open_bin path (fun out -> output_string out {|[providers.official]
protocol = "claude-code"
command = "fixture-not-executed"
is-non-interactive = true
[models.verifier]
api-name = "verifier-fixture"
max-context = 400000
tools-support = true
[official.verifier]
[runtime]
default = "official.verifier"
|});
    (match Runtime.init_default ~config_path:path with
     | Ok () -> () | Error detail -> Alcotest.fail detail);
    f ())
;;

let test_lane_resolution_preserves_frozen_order_and_drops_rejected_slots () =
  with_configured_verifier_cli @@ fun () ->
  let snapshot = load_verifier_snapshot () in
  (match
     Runtime.publish_exact_output_registry
       ~lanes:
         [ { Runtime_schema.id = "verifier_exact"
           ; slot_ids = [ "verifier-b"; "verifier-missing"; "verifier-a" ]
           ; cli_slot_ids = [ "official.verifier" ]
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
      [ "verifier-b"; "verifier-a"; "official.verifier" ]
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

(* ------------------------------------------------------------ *)
(* A cli slot that cannot judge (#37179)                        *)
(* ------------------------------------------------------------ *)

(* [verifier_exact] dispatches each slot as a judge, so a cli slot naming a
   client that cannot suppress native tools is unusable there. It used to load
   and then fail every review with Evaluator_unavailable, one per attempt,
   because the first rejected id failed the whole lane — and first-run setup
   in v0.35.15-20 wrote exactly such a slot. *)
let mixed_client_config =
  {|[providers.official]
protocol = "claude-code"
command = "fixture-not-executed"
is-non-interactive = true
[providers.native_only]
protocol = "codex-app-server"
command = "fixture-not-executed"
is-non-interactive = true
[models.verifier]
api-name = "verifier-fixture"
max-context = 400000
tools-support = true
[official.verifier]
[native_only.verifier]
[runtime]
default = "official.verifier"
|}
;;

let judging_client = "official.verifier"
let native_only_client = "native_only.verifier"

let with_mixed_verifier_clients ?(config = mixed_client_config) f =
  let saved = Runtime.For_testing.snapshot () in
  let path = Filename.temp_file "verifier-mixed-clients-" ".toml" in
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore saved;
      Sys.remove path)
    (fun () ->
       Out_channel.with_open_bin path (fun out -> output_string out config);
       (match Runtime.init_default ~config_path:path with
        | Ok () -> ()
        | Error detail -> Alcotest.fail detail);
       f path)
;;

let publish_verifier_lane ~slot_ids ~cli_slot_ids =
  match
    Runtime.publish_exact_output_registry
      ~lanes:[ { Runtime_schema.id = "verifier_exact"; slot_ids; cli_slot_ids } ]
      (load_verifier_snapshot ())
  with
  | Ok _ -> ()
  | Error detail -> Alcotest.failf "lane publication failed: %s" detail
;;

(* The Lanes projection an operator reads. Going through [snapshot_json] keeps
   the assertion on the surface that is actually served. *)
let verifier_lane_projection () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Server_standalone_lane_projection.snapshot_json ()
  |> Yojson.Safe.Util.member "lanes"
  |> Yojson.Safe.Util.to_list
  |> List.find (fun lane ->
    String.equal
      (Yojson.Safe.Util.(lane |> member "lane_id" |> to_string))
      Runtime.verifier_exact_lane_id)
;;

let projected_strings lane key =
  Yojson.Safe.Util.(lane |> member key |> to_list |> List.map to_string)
;;

let test_rejected_cli_slot_leaves_the_lane_usable () =
  with_mixed_verifier_clients
  @@ fun _path ->
  publish_verifier_lane
    ~slot_ids:[ "verifier-a" ]
    ~cli_slot_ids:[ native_only_client; judging_client ];
  (match Runtime.verifier_exact_lane_slot_ids () with
   | Error detail ->
     Alcotest.failf "one unusable cli slot must not fail the lane: %s" detail
   | Ok slots ->
     Alcotest.(check (list string))
       "the lane keeps its catalog slot and the cli slot that can judge"
       [ "verifier-a"; judging_client ]
       slots);
  let lane = verifier_lane_projection () in
  Alcotest.(check (list string))
    "the projection shows only the cli slot that can judge"
    [ judging_client ]
    (projected_strings lane "cli_slots");
  Alcotest.(check (list string))
    "the unusable cli slot is shown as dropped"
    [ native_only_client ]
    (projected_strings lane "dropped_slots");
  Alcotest.(check string)
    "a lane with a usable slot stays ready"
    "ready"
    Yojson.Safe.Util.(lane |> member "configuration_state" |> to_string)
;;

let test_readiness_names_the_cli_slot_that_cannot_judge () =
  with_mixed_verifier_clients
  @@ fun _path ->
  publish_verifier_lane
    ~slot_ids:[ "verifier-a" ]
    ~cli_slot_ids:[ native_only_client; judging_client ];
  match Runtime.verifier_exact_lane_readiness () with
  | Error detail ->
    Alcotest.failf "readiness refused a lane that still has a judge: %s" detail
  | Ok [] -> Alcotest.fail "readiness hid the cli slot the lane cannot judge through"
  | Ok [ rejection ] ->
    Alcotest.(check string)
      "readiness names the slot"
      native_only_client
      rejection.Runtime.slot_id;
    Alcotest.(check int)
      "the position counts across the whole lane declaration"
      2
      rejection.Runtime.position;
    Alcotest.(check bool)
      "the reason names native-tool suppression"
      true
      (String_util.contains_substring
         rejection.Runtime.detail
         "native-tool suppression")
  | Ok rejections ->
    Alcotest.failf "expected one rejection, got %d" (List.length rejections)
;;

let test_lane_with_no_judge_refuses_before_dispatch () =
  with_mixed_verifier_clients
  @@ fun _path ->
  publish_verifier_lane ~slot_ids:[] ~cli_slot_ids:[ native_only_client ];
  (match Runtime.verifier_exact_lane_slot_ids () with
   | Ok slots ->
     Alcotest.failf
       "a lane with no judge must not hand out slots: %s"
       (String.concat ", " slots)
   | Error detail ->
     Alcotest.(check bool)
       "the refusal names the slot that cannot judge"
       true
       (String_util.contains_substring detail native_only_client));
  (match Runtime.verifier_exact_lane_readiness () with
   | Ok _ -> Alcotest.fail "readiness accepted a lane with no judge"
   | Error _ -> ());
  let lane = verifier_lane_projection () in
  Alcotest.(check (list string))
    "no cli slot survives"
    []
    (projected_strings lane "cli_slots");
  Alcotest.(check (list string))
    "the declared slot is shown as dropped"
    [ native_only_client ]
    (projected_strings lane "dropped_slots");
  Alcotest.(check string)
    "the lane reads as degraded"
    "degraded"
    Yojson.Safe.Util.(lane |> member "configuration_state" |> to_string);
  Alcotest.(check bool)
    "the projection says why"
    true
    (match Yojson.Safe.Util.(lane |> member "admission_error") with
     | `String detail -> String_util.contains_substring detail native_only_client
     | `Null
     | `Bool _
     | `Int _
     | `Float _
     | `List _
     | `Assoc _
     | `Intlit _ -> false)
;;

(* First-run setup used to write the chosen client into every lane that takes
   a cli tail. For a Codex-only or Antigravity-only install that wrote a
   verifier_exact the operator could not repair from inside MASC. *)
let setup_config =
  mixed_client_config
  ^ Printf.sprintf
      "[runtime.exact_output_lanes.verifier_exact]\nslots = [%S, %S]\ncli_slots = []\n"
      judging_client
      native_only_client
;;

let test_setup_never_writes_a_verifier_slot_that_cannot_judge () =
  with_mixed_verifier_clients ~config:setup_config
  @@ fun path ->
  (match
     Runtime.set_first_run_runtime ~runtime_config_path:path ~runtime_id:native_only_client ()
   with
   | Ok _ -> ()
   | Error detail -> Alcotest.failf "first-run setup failed: %s" detail);
  match Runtime_toml.parse_file path with
  | Error _ -> Alcotest.fail "the config setup wrote must still parse"
  | Ok (config : Runtime_schema.config) ->
    (match
       List.find_opt
         (fun (lane : Runtime_schema.exact_output_lane_decl) ->
            String.equal lane.id Runtime.verifier_exact_lane_id)
         config.exact_output_lane_decls
     with
     | None -> Alcotest.fail "setup dropped the verifier_exact lane declaration"
     | Some lane ->
       Alcotest.(check (list string))
         "the client that cannot judge is not written as a cli slot"
         []
         lane.cli_slot_ids;
       Alcotest.(check (list string))
         "the declared slots keep only what can judge"
         [ judging_client ]
         lane.slot_ids)
;;

(* [--setup-lanes] also runs against a copy of an operator's existing config
   (Runtime_setup_batch), not only a fresh install. The live shape declares a
   working Claude Code cli slot; selecting a Codex runtime must not delete it. *)
let setup_config_with_declared_cli_slots =
  mixed_client_config
  ^ Printf.sprintf
      "[runtime.exact_output_lanes.verifier_exact]\nslots = []\ncli_slots = [%S, %S]\n"
      native_only_client
      judging_client
;;

let test_setup_keeps_a_declared_cli_slot_that_can_judge () =
  with_mixed_verifier_clients ~config:setup_config_with_declared_cli_slots
  @@ fun path ->
  (match
     Runtime.set_first_run_runtime ~runtime_config_path:path ~runtime_id:native_only_client ()
   with
   | Ok _ -> ()
   | Error detail -> Alcotest.failf "first-run setup failed: %s" detail);
  match Runtime_toml.parse_file path with
  | Error _ -> Alcotest.fail "the config setup wrote must still parse"
  | Ok (config : Runtime_schema.config) ->
    (match
       List.find_opt
         (fun (lane : Runtime_schema.exact_output_lane_decl) ->
            String.equal lane.id Runtime.verifier_exact_lane_id)
         config.exact_output_lane_decls
     with
     | None -> Alcotest.fail "setup erased a verifier lane that still had a judge"
     | Some lane ->
       Alcotest.(check (list string))
         "the declared cli slot that can judge survives; the other does not"
         [ judging_client ]
         lane.cli_slot_ids;
       Alcotest.(check (list string)) "no HTTP slot is invented" [] lane.slot_ids)
;;

(* The registry numbers cli slots after the DECLARED catalog slots, so a
   catalog slot it rejected still occupies its position. A projection that
   counted only the admitted ones would print a position that names a
   different line of runtime.toml than the boot report does. *)
let test_positions_count_catalog_slots_the_registry_rejected () =
  with_mixed_verifier_clients
  @@ fun _path ->
  publish_verifier_lane
    ~slot_ids:[ "verifier-a"; "verifier-missing" ]
    ~cli_slot_ids:[ native_only_client; judging_client ];
  (match Runtime.verifier_exact_lane_readiness () with
   | Error detail -> Alcotest.failf "readiness refused a lane that still has a judge: %s" detail
   | Ok [ rejection ] ->
     Alcotest.(check string)
       "readiness names the slot"
       native_only_client
       rejection.Runtime.slot_id;
     Alcotest.(check int)
       "the rejected catalog slot still holds its position"
       3
       rejection.Runtime.position
   | Ok rejections ->
     Alcotest.failf "expected one rejection, got %d" (List.length rejections));
  let lane = verifier_lane_projection () in
  Alcotest.(check (list string))
    "both the catalog slot the registry dropped and the cli slot that cannot judge"
    [ "verifier-missing"; native_only_client ]
    (projected_strings lane "dropped_slots")
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
            "recorded images ride to the reviewer as blocks"
            `Quick
            test_recorded_images_ride_to_the_reviewer_as_blocks
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
    ; ( "cli slots that cannot judge"
      , [ Alcotest.test_case
            "one unusable cli slot leaves the rest of the lane usable"
            `Quick
            test_rejected_cli_slot_leaves_the_lane_usable
        ; Alcotest.test_case
            "readiness names the cli slot that cannot judge"
            `Quick
            test_readiness_names_the_cli_slot_that_cannot_judge
        ; Alcotest.test_case
            "a lane with no judge refuses before dispatch"
            `Quick
            test_lane_with_no_judge_refuses_before_dispatch
        ; Alcotest.test_case
            "positions count catalog slots the registry rejected"
            `Quick
            test_positions_count_catalog_slots_the_registry_rejected
        ; Alcotest.test_case
            "first-run setup never writes a verifier slot that cannot judge"
            `Quick
            test_setup_never_writes_a_verifier_slot_that_cannot_judge
        ; Alcotest.test_case
            "setup keeps a declared cli slot that can judge"
            `Quick
            test_setup_keeps_a_declared_cli_slot_that_can_judge
        ] )
    ]
;;
