module AR = Masc.Task.Anti_rationalization

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

(* Every review is handed a lookup surface; these tests stub the reviewer, so
   the surface is only carried, never dispatched, except where a test says so. *)
let lookup : AR.lookup_surface =
  { schemas =
      [ { Types_core.name = "keeper_read_file"
        ; description = "read evidence"
        ; input_schema = `Assoc []
        }
      ]
  ; dispatch =
      (fun ~name ~args:_ ->
         Tool_result.make_ok
           ~tool_name:name
           ~start_time:(Tool_timing.start ())
           ~data:(`String "artifact body")
           ~content_blocks:[ Llm_provider.Types.Text "artifact body" ]
           ())
  }
;;

let lookup_root = AR.Producer_tree [ "repo" ]

let with_reviewer reviewer f =
  let saved = Atomic.get AR.run_llm_reviewer_fn in
  Fun.protect
    ~finally:(fun () -> Atomic.set AR.run_llm_reviewer_fn saved)
    (fun () ->
       Atomic.set AR.run_llm_reviewer_fn reviewer;
       f ())
;;

let review () =
  AR.review
    ~evaluator_runtime:"task-reviewer"
    ~question:
      { AR.completion_contract = None
      ; required_evidence = []
      ; evidence_posture = AR.Note_only
      ; few_shot_block = ""
      }
    ~lookup
    ~lookup_root
    ~provider_rest:Masc.Verification_retry.provider_rest
    ~base_path:(Filename.get_temp_dir_name ())
    request

let test_explicit_base_path_reaches_reviewer () =
  let expected =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-review-base-%d" (Unix.getpid ()))
  in
  let received = ref None in
  with_reviewer
    (fun ~base_path ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_ ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
       received := Some base_path;
       Ok {AR.selected_runtime_id="task-reviewer"; evaluator_execution = None;verdict=None})
    (fun () ->
       ignore
         (AR.review ~evaluator_runtime:"task-reviewer"
            ~question:
              { AR.completion_contract = None
              ; required_evidence = []
              ; evidence_posture = AR.Note_only
              ; few_shot_block = ""
              }
            ~lookup ~lookup_root ~provider_rest:Masc.Verification_retry.provider_rest
            ~base_path:expected request);
       match !received with
       | Some actual ->
         Alcotest.(check string) "review uses the caller BasePath" expected actual
       | None -> Alcotest.fail "reviewer callback was not called")
;;

let configure_prompt_registry () =
  let prompt_dir =
    Filename.concat (Masc_test_deps.find_project_root ()) "config/prompts"
  in
  Prompt_registry.set_markdown_dir prompt_dir;
  (* Prompts live in config/prompts as group files; slot keys such as
     verification.lookup.producer_tree only register when the directory is loaded
     (#32780). A set without load leaves every slot key missing and the
     review gate falls to evaluator_unavailable before any reviewer runs.
     Matches the other prompt-rendering tests. *)
  Prompt_registry.load_prompts_from_directory prompt_dir
;;

let test_structured_tool_is_the_only_semantic_verdict () =
  with_reviewer
    (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_ ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
       Ok {AR.selected_runtime_id="task-reviewer";evaluator_execution=None;verdict=Some (AR.Approve "")})
    (fun () ->
       let result = review () in
       Alcotest.(check string)
         "gate"
         "structured_tool"
         (AR.gate_to_string result.gate);
       match result.verdict with
       | Some (AR.Approve _) -> ()
       | Some (AR.Reject reason) -> Alcotest.failf "unexpected reject: %s" reason
       | None -> Alcotest.fail "structured verdict was lost")
;;

let test_exact_verdict_response_identity_survives_projection () =
  let identity = match Runtime_response_identity.make ~execution_id:"judge-execution"
    ~actor:"completion-review" ~runtime_id:"actual-winner" ~response_id:"verdict-response"
    ~provider_id:"actual-provider" ~model_id:"reported-model" ~tool_use_id:"accepted-verdict"
    ~provider_turn:2 ~source_tool_use_ordinal:0 with
    | Ok identity -> identity | Error detail -> Alcotest.fail detail in
  with_reviewer
    (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_ ?system_prompt:_ ?goal_blocks:_
      ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
      Ok { AR.selected_runtime_id = "actual-winner"; verdict = Some (AR.Approve "checked")
        ; evaluator_execution = Some identity })
    (fun () ->
      let result = review () in
      Alcotest.(check string) "the winning runtime survives a requested-slot difference"
        "actual-winner" result.evaluator_runtime;
      Alcotest.(check bool) "the accepted verdict invocation is retained exactly" true
        (result.evaluator_execution = Some identity))
;;

let test_response_text_is_never_parsed_as_verdict () =
  with_reviewer
    (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_ ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
       Ok {AR.selected_runtime_id="task-reviewer";evaluator_execution=None;verdict=None})
    (fun () ->
       let result = review () in
       Alcotest.(check string)
         "gate"
         "invalid_verdict"
         (AR.gate_to_string result.gate);
       Alcotest.(check bool) "no semantic verdict" true (Option.is_none result.verdict))
;;

let test_evaluator_failure_is_unavailable_not_reject () =
  with_reviewer
    (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_ ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
       Error (Agent_core.Error.Internal "review transport unavailable"))
    (fun () ->
       let result = review () in
       Alcotest.(check string)
         "gate"
         "evaluator_unavailable"
         (AR.gate_to_string result.gate);
       Alcotest.(check bool) "no fabricated reject" true (Option.is_none result.verdict))
;;

(* The retry policy this exists for: a review whose single seed message
   already exceeds the target's whole budget cannot be fixed by trying again
   with the same request, so [Agent_core.Error.is_retryable] already reports
   [false] for it (it is an [Agent (HookExecutionFailed _)]). [review] must
   name no candidate that could review again, so nothing arms a retry. *)
let test_structural_budget_failure_is_not_retryable () =
  with_reviewer
    (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_ ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
       Error
         (Agent_core.Error.Agent
            (Agent_core.Error.HookExecutionFailed
               { hook_name = "model_input_projection"
               ; stage = "turn:parse"
               ; tool_name = None
               ; tool_use_id = None
               ; detail =
                   "newest conversation atom does not fit the model input budget: \
                    available_bytes=233931 newest_atom_bytes=294670"
               })))
    (fun () ->
       let result = review () in
       Alcotest.(check string)
         "gate"
         "evaluator_unavailable"
         (AR.gate_to_string result.gate);
       Alcotest.(check (list string))
         "classified non-retryable"
         []
         result.retryable_runtimes)
;;

(* Contrast case: a rate limit is exactly the kind of failure retrying is
   supposed to absorb ([Agent_core.Error.is_retryable] reports [true] for
   [Api (RateLimited _)]), so the slot is named as able to review again. *)
let test_rate_limit_failure_stays_retryable () =
  with_reviewer
    (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_ ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
       Error
         (Agent_core.Error.Api
            (Agent_core.Error.Retry.RateLimited
               { retry_after = None; message = "rate limited" })))
    (fun () ->
       let result = review () in
       Alcotest.(check string)
         "gate"
         "evaluator_unavailable"
         (AR.gate_to_string result.gate);
       Alcotest.(check (list string))
         "classified retryable"
         [ "task-reviewer" ]
         result.retryable_runtimes)
;;

let test_reject_without_reason_is_malformed () =
  let malformed =
    [ `Assoc [ "verdict", `String "REJECT" ]
    ; `Assoc [ "verdict", `String "REJECT"; "reason", `String "   " ]
    ; `Assoc [ "verdict", `String "REJECT"; "reason", `Null ]
    ]
  in
  List.iter
    (fun args ->
       match AR.parse_review_verdict_from_json args with
       | Error _ -> ()
       | Ok (AR.Approve _) -> Alcotest.fail "malformed REJECT became APPROVE"
       | Ok (AR.Reject reason) ->
         Alcotest.failf "malformed REJECT fabricated a reason: %s" reason)
    malformed
;;

let test_reject_reason_is_preserved () =
  match
    AR.parse_review_verdict_from_json
      (`Assoc
          [ "verdict", `String "REJECT"
          ; "reason", `String " evidence is incomplete "
          ])
  with
  | Ok (AR.Reject reason) ->
    Alcotest.(check string) "rejection reason is not rewritten" " evidence is incomplete " reason
  | Ok (AR.Approve _) -> Alcotest.fail "REJECT became APPROVE"
  | Error detail -> Alcotest.fail detail
;;

(* An approval keeps the reviewer's stated reason too. The parser used to read
   [reason] and hand back a nullary [Approve], so what the reviewer said it
   checked never left this function. An omitted reason stays empty: only REJECT
   is refused without one, and failing an approval for a missing sentence would
   be a new gate. *)
let test_approve_reason_is_preserved () =
  (match
     AR.parse_review_verdict_from_json
       (`Assoc
           [ "verdict", `String "APPROVE"
           ; "reason", `String "ran the suite in the sandbox: 9355/9355"
           ])
   with
   | Ok (AR.Approve reason) ->
     Alcotest.(check string)
       "approval reason is not rewritten"
       "ran the suite in the sandbox: 9355/9355"
       reason
   | Ok (AR.Reject _) -> Alcotest.fail "APPROVE became REJECT"
   | Error detail -> Alcotest.fail detail);
  match AR.parse_review_verdict_from_json (`Assoc [ "verdict", `String "APPROVE" ]) with
  | Ok (AR.Approve reason) ->
    Alcotest.(check string) "a silent approval stays silent" "" reason
  | Ok (AR.Reject _) -> Alcotest.fail "APPROVE became REJECT"
  | Error detail -> Alcotest.fail detail
;;

let test_evidence_text_is_not_classified_before_llm_review () =
  Alcotest.(check (list string))
    "only blank values are removed"
    [ "n/a"; "tbd" ]
    (Masc.Task.Completion_review.non_empty_trimmed_strings
       [ " tbd "; ""; " n/a "; "   " ])
;;

(* RFC prompts-and-tool-definitions-outside-ocaml §2.2: the schema handed to
   the reviewer is read from [config/tools/report_review_verdict.toml], whose
   verdict enum is a literal. The variant owns the vocabulary; this mirror
   (the [test_agent_card_action_mirror] idiom) catches drift between the
   literal and [valid_verdict_strings]. *)
let test_verdict_enum_mirrors_valid_verdict_strings () =
  let received = ref None in
  with_reviewer
    (fun ~base_path:_
      ?sw:_
      ?execution_owner:_
      ~evaluator_runtime:_ ~candidate_kind:_
      ~prompt:_
      ?system_prompt:_ ?goal_blocks:_
      ~report_tool_schema
      ~lookup:_
      ~on_tool_result:_
      ~attempt_continuation:_ ~on_runtime_attempt_error:_
      () ->
       received := Some report_tool_schema;
       Ok {AR.selected_runtime_id="task-reviewer"; evaluator_execution = None;verdict=None})
    (fun () ->
       ignore (review ());
       match !received with
       | None -> Alcotest.fail "reviewer callback was not called"
       | Some schema ->
         Alcotest.(check string) "tool name" "report_review_verdict" schema.name;
         let verdict_property =
           match schema.input_schema with
           | `Assoc fields ->
             (match List.assoc_opt "properties" fields with
              | Some (`Assoc properties) ->
                (match List.assoc_opt "verdict" properties with
                 | Some verdict -> verdict
                 | None -> Alcotest.fail "properties.verdict missing")
              | _ -> Alcotest.fail "input_schema.properties missing")
           | _ -> Alcotest.fail "input_schema is not an object"
         in
         (match verdict_property with
          | `Assoc fields ->
            (match List.assoc_opt "enum" fields with
             | Some (`List items) ->
               let enum_strings =
                 List.filter_map
                   (function
                     | `String s -> Some s
                     | _ -> None)
                   items
               in
               Alcotest.(check (list string))
                 "verdict enum mirrors valid_verdict_strings"
                 AR.valid_verdict_strings
                 enum_strings
             | _ -> Alcotest.fail "properties.verdict.enum missing")
          | _ -> Alcotest.fail "properties.verdict is not an object"))
;;

(* RFC-0417 section 4.3: evidence posture changes the judge's question, not the
   verdict after the judge answers. A controlled judge approval therefore
   remains an approval even when the submitted snapshot is note-only. *)
let test_note_only_verdict_is_owned_by_the_reviewer () =
  with_reviewer
    (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_ ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
       Ok {AR.selected_runtime_id="task-reviewer";evaluator_execution=None;verdict=Some (AR.Approve "everything looks fine")})
    (fun () ->
       let result = review () in
       Alcotest.(check string)
         "gate"
         "structured_tool"
         (AR.gate_to_string result.gate);
       match result.verdict with
       | Some (AR.Approve reason) ->
         Alcotest.(check string) "reviewer reason" "everything looks fine" reason
       | Some (AR.Reject reason) -> Alcotest.failf "unexpected reject: %s" reason
       | None -> Alcotest.fail "the reviewer verdict was overwritten")
;;

(* A completed lookup is exposed to the judge as typed JSON. This lets the
   prompt begin with [evidence_lookup_succeeded=false] and lets an actual
   successful tool result move that fact to [true], without a local counter or
   a post-hoc verdict override. *)
let test_successful_lookup_is_exposed_to_the_reviewer () =
  let saw_success = ref false in
  with_reviewer
    (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_ ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup ~on_tool_result:_ ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
       (let { AR.dispatch; _ } = lookup in
          let result = dispatch ~name:"keeper_read_file" ~args:(`Assoc []) in
          let data_exposes_success =
            match Tool_result.data result with
            | `Assoc fields ->
              List.assoc_opt "evidence_lookup_succeeded" fields = Some (`Bool true)
              && List.assoc_opt "lookup_result" fields = Some (`String "artifact body")
            | _ -> false
          in
          let blocks_expose_success =
            match result with
            | Tool_result.Completed
                { content_blocks =
                    Some
                      (Llm_provider.Types.Text
                         {|{"evidence_lookup_succeeded":true}|}
                       :: Llm_provider.Types.Text "artifact body" :: _)
                ; _
                } ->
              true
            | Tool_result.Completed _
            | Tool_result.Deferred _
            | Tool_result.Failed _ ->
              false
          in
          saw_success := data_exposes_success && blocks_expose_success);
       Ok
         { AR.selected_runtime_id = "task-reviewer"
         ; evaluator_execution = None; verdict = Some (AR.Approve "checked the lookup result")
         })
    (fun () ->
       let result =
         AR.review
           ~evaluator_runtime:"task-reviewer"
           ~question:
             { AR.completion_contract = None
             ; required_evidence = []
             ; evidence_posture = AR.Note_only
             ; few_shot_block = ""
             }
           ~lookup
           ~lookup_root
           ~provider_rest:Masc.Verification_retry.provider_rest
           ~base_path:(Filename.get_temp_dir_name ())
           request
       in
       Alcotest.(check bool)
         "completed lookup carries the success observation"
         true
         !saw_success;
       Alcotest.(check string)
         "gate"
         "structured_tool"
         (AR.gate_to_string result.gate);
       match result.verdict with
       | Some (AR.Approve _) -> ()
       | Some (AR.Reject reason) -> Alcotest.failf "unexpected reject: %s" reason
       | None -> Alcotest.fail "structured verdict was lost")
;;

(* The verdict calls of one review, driven through the same transition the
   reviewer hook runs. A REJECT refused for its missing reason and resent with
   one is the verdict; a resend that flips the decision, or follows a refusal
   whose decision cannot be read, stays a protocol violation. *)
let verdict_json ?reason verdict =
  `Assoc
    (("verdict", `String verdict)
     :: (match reason with Some r -> [ "reason", `String r ] | None -> []))

let run_verdict_calls calls =
  List.fold_left
    (fun call args -> fst (AR.step_verdict_call call args))
    AR.empty_verdict_call
    calls

let test_resent_reject_with_reason_is_the_verdict () =
  let call = run_verdict_calls [ verdict_json "REJECT"; verdict_json ~reason:"no test" "REJECT" ] in
  Alcotest.(check bool) "no violation remains" true (Option.is_none call.violation);
  match call.recorded with
  | Some (AR.Reject "no test") -> ()
  | _ -> Alcotest.fail "the resent REJECT must be the recorded verdict"

let test_resend_that_flips_the_decision_stays_a_violation () =
  let call = run_verdict_calls [ verdict_json "REJECT"; verdict_json ~reason:"fine" "APPROVE" ] in
  Alcotest.(check bool) "a REJECT refused and resent as APPROVE is a violation" true
    (Option.is_some call.violation)

let test_resend_after_unreadable_refusal_stays_a_violation () =
  let call = run_verdict_calls [ verdict_json "MAYBE"; verdict_json ~reason:"fine" "APPROVE" ] in
  Alcotest.(check bool) "a decision that could not be read cannot be matched" true
    (Option.is_some call.violation)

let test_only_the_latest_refusal_counts () =
  let unreadable_then_reject =
    run_verdict_calls
      [ verdict_json "MAYBE"; verdict_json "REJECT"; verdict_json ~reason:"no test" "REJECT" ]
  in
  Alcotest.(check bool) "a REJECT refusal after an unreadable one is answered by the resend"
    true (Option.is_none unreadable_then_reject.violation);
  let reject_then_unreadable =
    run_verdict_calls
      [ verdict_json "REJECT"; verdict_json "MAYBE"; verdict_json ~reason:"no test" "REJECT" ]
  in
  Alcotest.(check bool) "a resend after an unreadable latest refusal stays a violation"
    true (Option.is_some reject_then_unreadable.violation)

let test_flip_to_reasonless_approve_stays_a_violation () =
  let call = run_verdict_calls [ verdict_json "REJECT"; verdict_json "APPROVE" ] in
  Alcotest.(check bool) "an APPROVE without a reason after a refused REJECT is a violation"
    true (Option.is_some call.violation)

let test_second_call_after_a_verdict_is_a_violation () =
  let call =
    run_verdict_calls
      [ verdict_json ~reason:"ok" "APPROVE"; verdict_json ~reason:"no" "REJECT" ]
  in
  Alcotest.(check bool) "a second call is a violation" true (Option.is_some call.violation);
  match call.recorded with
  | Some (AR.Approve "ok") -> ()
  | _ -> Alcotest.fail "the first recorded verdict stands"

(* A tool's lookup media is a provider block; once a review holds it, it is
   a history block naming the same bytes. *)
let wire_image data =
  Llm_provider.Types.Image
    { media_type = "image/png"; source = Llm_provider.Types.Base64 (Base64.encode_string data) }

let history_image data =
  Agent_core.Types.Image
    { media_type = "image/png"
    ; source = Agent_core.Types.Stored (Agent_core.History.stored_of_raw data) }

let history_of_wire block =
  match Agent_core.History.of_wire_block (Agent_core.History.Memory_store.create ()) block with
  | Ok block -> block
  | Error error -> Alcotest.fail (Agent_core.Error.to_string (Agent_core.Error.Media error))

let actual_inline_review_view ~base_path result =
  let refusal = ref None in
  let projected = Masc.Tool_bridge.to_agent_core_typed_result ~base_path
      ~model_projection:(Tool_output.Inline_up_to
        { maximum_bytes = Tool_shard_limits.verification_evidence_max_bytes })
      ~on_externalization_error:(fun error -> refusal := Some error) result in
  let model_result, media = match projected with
    | Ok output ->
      `Assoc ["content", `String output.Agent_core.Types.content; "is_error", `Bool false],
      Option.value output.content_blocks ~default:[]
    | Error error ->
      `Assoc ["content", `String error.Agent_core.Types.message; "is_error", `Bool true
             ; "recoverable", `Bool error.recoverable
             ; "error_class", Option.fold ~none:`Null
                 ~some:Agent_core.Types.tool_error_class_to_yojson error.error_class], []
  in
  model_result, media, !refusal
;;

(* Actual [AR.run] slot traversal with an injected evaluator callback. No
   provider transport runs here; the callback dispatches the real supplied
   lookup surface before returning typed candidate failures. *)
let test_lookup_evidence_survives_slot_failover_but_not_a_new_review () =
  let module T = Agent_core.Types in
  let slots = ["evidence-small"; "evidence-second"; "evidence-large"] in
  let saved_slots = Atomic.get Workspace_hooks.get_verifier_exact_lane_slots_fn in
  Fun.protect
    ~finally:(fun () -> Atomic.set Workspace_hooks.get_verifier_exact_lane_slots_fn saved_slots)
    (fun () ->
      Atomic.set Workspace_hooks.get_verifier_exact_lane_slots_fn
        (fun () -> Ok (List.map (fun slot -> slot, Types_core.Catalog_slot) slots));
      let prompt = "Review the original submission without discarding evidence." in
      let attachment = history_image "submitted-original-image" in
      let original = [T.Text prompt; attachment] in
      let args = `Assoc ["path", `String "repo/evidence.json"; "include_image", `Bool true] in
      let old_body = String.make 32768 'a' and new_body = String.make 32768 'b' in
      let block_image index = if index = 0 then "lookup-first-image" else "lookup-changed-image" in
      let json_entry = function
        | T.Text text ->
          (try
             match Yojson.Safe.from_string text with
             | `Assoc ["prior_review_lookup", entry] -> Some entry
             | _ -> None
           with Yojson.Json_error _ -> None)
        | T.Thinking _ | T.RedactedThinking _ | T.ReasoningDetails _
        | T.ToolUse _ | T.ToolResult _ | T.Image _ | T.Document _ | T.Audio _ -> None
      in
      let run_review () =
        let reads = ref 0 and calls = ref [] and results = ref [] and views = ref [] in
        let source_lookup : AR.lookup_surface =
          { lookup with dispatch = (fun ~name ~args:actual ->
              Alcotest.(check string) "actual requested lookup name" "keeper_read_file" name;
              Alcotest.(check bool) "actual requested lookup arguments" true (actual = args);
              let index = !reads in
              incr reads;
              let body = if index = 0 then old_body else new_body in
              let result = Tool_result.make_ok ~tool_name:name ~start_time:(Tool_timing.start ())
                  ~data:(`Assoc ["original_body", `String body])
                  ~content_blocks:[Llm_provider.Types.Text body; wire_image (block_image index)] () in
              results := !results @ [result];
              views := !views @ [actual_inline_review_view ~base_path:(Filename.get_temp_dir_name ()) result];
              result) }
        in
        with_reviewer
          (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime ~candidate_kind:_ ~prompt:actual_prompt
              ?system_prompt:_ ?goal_blocks ~report_tool_schema:_ ~lookup:offered_lookup
              ~on_tool_result:_ ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
            let index = List.length !calls in
            calls := !calls @ [evaluator_runtime];
            Alcotest.(check string) "every candidate retains the original prompt" prompt actual_prompt;
            let blocks = match goal_blocks with
              | Some blocks -> blocks | None -> Alcotest.fail "submitted media disappeared" in
            Alcotest.(check bool) "original prompt and attachment remain the leading blocks" true
              (List.take (List.length original) blocks = original);
            let entries = List.filter_map json_entry blocks in
            Alcotest.(check int) "only this invocation's earlier observations are attached" index (List.length entries);
            List.iteri (fun prior entry ->
              let member = Yojson.Safe.Util.member in
              Alcotest.(check bool) "lookup keeps its originating evaluator slot" true
                (member "evaluator_slot" entry = `String (List.nth slots prior));
              Alcotest.(check bool) "lookup name is retained" true
                (member "tool_name" entry = `String "keeper_read_file");
              Alcotest.(check bool) "lookup arguments are retained" true (member "arguments" entry = args);
              let model_result, media, refusal = List.nth !views prior in
              Alcotest.(check bool) "normal fixture is accepted by the actual full bridge" true
                (refusal = None);
              Alcotest.(check bool) "lookup disposition is preserved independently of its model projection" true
                (member "disposition" entry = `String (Tool_result.string_of_disposition (List.nth !results prior)));
              Alcotest.(check bool) "only the original actual bridge model view is retained" true
                (member "result" entry = model_result);
              Alcotest.(check bool) "every actual bridge media block remains native" true
                (List.for_all (fun block -> List.mem (history_of_wire block) blocks) media);
              Alcotest.(check bool) "original lookup media remains a native media block" true
                (List.mem (history_image (block_image prior)) blocks)) entries;
            if index < 2 then begin
              let fresh = offered_lookup.dispatch ~name:"keeper_read_file" ~args in
              Alcotest.(check bool) "a new slot performs its own lookup, retaining its changed result" true
                (fresh = List.nth !results index);
              if index = 1 then begin
                Alcotest.(check bool) "a changed fresh read cannot replace the earlier source view" true
                  (Tool_result.to_json (List.nth !results 0) <> Tool_result.to_json fresh);
                Alcotest.(check bool) "the earlier observation remains in this slot's immutable input" true
                  (let model_result, _, _ = List.hd !views in
                   Yojson.Safe.Util.member "result" (List.hd entries) = model_result)
              end;
              Error (Agent_core.Error.Api
                (if index = 0 then Agent_core.Retry.InvalidRequest
                   { message = "fixture provider body-size refusal"
                   ; reason = Agent_core.Retry.Request_body_refused_by_provider { status = 413 } }
                 else Agent_core.Retry.ContextOverflow { message = "fixture context overflow"; limit = None }))
            end else Ok { AR.selected_runtime_id = evaluator_runtime; evaluator_execution = None; verdict = Some (AR.Approve "checked") })
          (fun () ->
            let result = AR.run ~log_info:ignore ~log_warn:ignore
                ~render_prompt:(fun () -> Ok prompt) ~goal_blocks:[attachment]
                ~lookup:source_lookup ~provider_rest:(fun _ -> AR.No_stated_rest)
                ~base_path:(Filename.get_temp_dir_name ()) () in
            Alcotest.(check (list string)) "declared slot order remains intact" slots !calls;
            Alcotest.(check int) "each failed slot performed a fresh lookup" 2 !reads;
            match result.verdict with
            | Some (AR.Approve "checked") -> ()
            | Some (AR.Approve _) | Some (AR.Reject _) | None -> Alcotest.fail "later evaluator lost its verdict")
      in
      run_review ();
      (* First-candidate input is checked empty of prior observations again. *)
      run_review ())
;;

let test_oversized_lookup_handoff_preserves_the_inline_refusal () =
  let module T = Agent_core.Types in
  let saved_slots = Atomic.get Workspace_hooks.get_verifier_exact_lane_slots_fn in
  Fun.protect
    ~finally:(fun () -> Atomic.set Workspace_hooks.get_verifier_exact_lane_slots_fn saved_slots)
    (fun () ->
      Atomic.set Workspace_hooks.get_verifier_exact_lane_slots_fn
        (fun () -> Ok ["refused-source", Types_core.Catalog_slot; "next-reviewer", Types_core.Catalog_slot]);
      let prompt = "Review the submitted evidence without bypassing its explicit inline guard." in
      let attachment = history_image "submitted-original-image" in
      let rejected_media = wire_image "oversized-lookup-image" in
      let body = String.make (Tool_shard_limits.verification_evidence_max_bytes + 1) 'z' in
      let arguments = `Assoc ["path", `String "repo/oversized-evidence.json"] in
      let raw = Tool_result.make_ok ~tool_name:"keeper_read_file" ~start_time:(Tool_timing.start ())
          ~data:(`String body) ~content_blocks:[Llm_provider.Types.Text body; rejected_media] () in
      let _, _, actual_refusal = actual_inline_review_view
          ~base_path:(Filename.get_temp_dir_name ()) raw in
      let refusal_message = match actual_refusal with
        | Some { Masc.Tool_bridge.kind = Inline_budget_exceeded; message } -> message
        | Some { Masc.Tool_bridge.kind = Artifact_storage_failure; _ } -> Alcotest.fail "inline guard attempted storage"
        | None -> Alcotest.fail "the full bridge must refuse the SSOT limit-plus-one fixture"
      in
      let reads = ref 0 and calls = ref [] in
      let source_lookup : AR.lookup_surface = { lookup with dispatch = (fun ~name ~args ->
        incr reads;
        Alcotest.(check string) "actual oversized lookup name" "keeper_read_file" name;
        Alcotest.(check bool) "actual oversized lookup arguments" true (args = arguments);
        raw) } in
      with_reviewer
        (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime ~candidate_kind:_ ~prompt:actual_prompt
            ?system_prompt:_ ?goal_blocks ~report_tool_schema:_ ~lookup:offered_lookup
            ~on_tool_result:_ ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
          let first = !calls = [] in
          calls := !calls @ [evaluator_runtime];
          Alcotest.(check string) "the original prompt remains unchanged" prompt actual_prompt;
          let blocks = match goal_blocks with
            | Some blocks -> blocks | None -> Alcotest.fail "original attachment was lost" in
          Alcotest.(check bool) "submitted prompt and attachment remain intact" true
            (List.take 2 blocks = [T.Text prompt; attachment]);
          if first then begin
            ignore (offered_lookup.dispatch ~name:"keeper_read_file" ~args:arguments);
            Error (Agent_core.Error.Api (Agent_core.Retry.InvalidRequest
              { message = "fixture body-size refusal"
              ; reason = Agent_core.Retry.Request_body_refused_by_provider { status = 413 } }))
          end else begin
            let entry = match List.drop 2 blocks with
              | [T.Text text] ->
                Yojson.Safe.Util.member "prior_review_lookup" (Yojson.Safe.from_string text)
              | _ -> Alcotest.fail "refused handoff must carry one diagnostic and no rejected media" in
            let member = Yojson.Safe.Util.member in
            Alcotest.(check bool) "refusal retains the original slot relation" true
              (member "evaluator_slot" entry = `String "refused-source");
            Alcotest.(check bool) "refusal retains the actual lookup name" true
              (member "tool_name" entry = `String "keeper_read_file");
            Alcotest.(check bool) "refusal retains actual lookup arguments" true
              (member "arguments" entry = arguments);
            Alcotest.(check bool) "a completed raw lookup keeps its disposition even when projection fails" true
              (member "disposition" entry = `String (Tool_result.string_of_disposition raw));
            Alcotest.(check bool) "raw rejected Tool_result is not handed to the next slot" true
              (member "result" entry = `Null);
            let refusal = member "projection_refusal" entry in
            Alcotest.(check bool) "typed inline refusal survives failover" true
              (member "kind" refusal = `String "inline_budget_exceeded");
            Alcotest.(check bool) "the actual shared guard message survives failover" true
              (member "message" refusal = `String refusal_message);
            Alcotest.(check bool) "rejected lookup media is absent" false
              (List.mem (history_image "oversized-lookup-image") blocks);
            Alcotest.(check bool) "rejected raw bytes are absent from every text block" false
              (List.exists (function T.Text text -> String_util.contains_substring text body
                | T.Thinking _ | T.RedactedThinking _ | T.ReasoningDetails _
                | T.ToolUse _ | T.ToolResult _ | T.Image _ | T.Document _ | T.Audio _ -> false) blocks);
            Ok { AR.selected_runtime_id = evaluator_runtime; evaluator_execution = None; verdict = Some (AR.Approve "checked refusal") }
          end)
        (fun () ->
          let result = AR.run ~log_info:ignore ~log_warn:ignore
              ~render_prompt:(fun () -> Ok prompt) ~goal_blocks:[attachment]
              ~lookup:source_lookup ~provider_rest:(fun _ -> AR.No_stated_rest)
              ~base_path:(Filename.get_temp_dir_name ()) () in
          Alcotest.(check (list string)) "next declared slot was reached" ["refused-source"; "next-reviewer"] !calls;
          Alcotest.(check int) "one actual supplied lookup dispatch" 1 !reads;
          match result.verdict with
          | Some (AR.Approve "checked refusal") -> ()
          | Some (AR.Approve _) | Some (AR.Reject _) | None -> Alcotest.fail "refusal erased the next evaluator's verdict"))
;;

let test_failed_lookup_handoff_uses_the_full_bridge_envelope () =
  let module T = Agent_core.Types in
  let maximum_bytes = Tool_shard_limits.verification_evidence_max_bytes in
  let payload = String.make (maximum_bytes + 1) 'm' in
  let failed ?data ?metadata () =
    Tool_result.make_err ~tool_name:"keeper_read_file" ~class_:Tool_result.Policy_rejection
      ~start_time:(Tool_timing.start ()) ?data ?metadata "short read failure" in
  let cases =
    [ "large failure metadata", failed ~metadata:(`Assoc ["large_metadata", `String payload]) (), true
    ; "large explicit failure data", failed ~data:(`Assoc ["large_data", `String payload]) (), true
    ; "small failure envelope", failed ~metadata:(`Assoc ["reason", `String "permission denied"]) (), false
    ] in
  List.iter (fun (label, raw, must_refuse) ->
    Alcotest.(check bool) (label ^ ": raw message alone misses the envelope") true
      (String.length (Tool_result.message raw) < maximum_bytes);
    let model_result, media, actual_refusal = actual_inline_review_view
        ~base_path:(Filename.get_temp_dir_name ()) raw in
    Alcotest.(check bool) (label ^ ": actual full bridge owns inline admission") must_refuse
      (Option.is_some actual_refusal);
    Alcotest.(check bool) (label ^ ": failed projection has no success media") true (media = []);
    let saved_slots = Atomic.get Workspace_hooks.get_verifier_exact_lane_slots_fn in
    Fun.protect
      ~finally:(fun () -> Atomic.set Workspace_hooks.get_verifier_exact_lane_slots_fn saved_slots)
      (fun () ->
        Atomic.set Workspace_hooks.get_verifier_exact_lane_slots_fn
          (fun () -> Ok ["failed-lookup-source", Types_core.Catalog_slot; "failed-lookup-next", Types_core.Catalog_slot]);
        let prompt = "Review this source while retaining its tool failure accurately." in
        let attachment = history_image "submitted-original-image" in
        let args = `Assoc ["path", `String "repo/failing-evidence.json"] in
        let reads = ref 0 and calls = ref [] in
        let source_lookup : AR.lookup_surface = { lookup with dispatch = (fun ~name ~args:actual ->
          incr reads;
          Alcotest.(check string) "actual failed lookup name" "keeper_read_file" name;
          Alcotest.(check bool) "actual failed lookup arguments" true (actual = args);
          raw) } in
        with_reviewer
          (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime ~candidate_kind:_ ~prompt:actual_prompt
              ?system_prompt:_ ?goal_blocks ~report_tool_schema:_ ~lookup:offered_lookup
              ~on_tool_result:_ ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
            let first = !calls = [] in
            calls := !calls @ [evaluator_runtime];
            Alcotest.(check string) "failure does not replace the original prompt" prompt actual_prompt;
            let blocks = match goal_blocks with
              | Some blocks -> blocks | None -> Alcotest.fail "original failure-review attachment disappeared" in
            Alcotest.(check bool) "original evidence survives a failed lookup" true
              (List.take 2 blocks = [T.Text prompt; attachment]);
            if first then begin
              ignore (offered_lookup.dispatch ~name:"keeper_read_file" ~args);
              Error (Agent_core.Error.Api (Agent_core.Retry.InvalidRequest
                { message = "fixture candidate body refusal"
                ; reason = Agent_core.Retry.Request_body_refused_by_provider { status = 413 } }))
            end else begin
              let entry = match List.drop 2 blocks with
                | [T.Text text] -> Yojson.Safe.Util.member "prior_review_lookup" (Yojson.Safe.from_string text)
                | _ -> Alcotest.fail "failed lookup handoff must contain only its one model-view record" in
              let member = Yojson.Safe.Util.member in
              Alcotest.(check bool) "failure retains the original slot" true
                (member "evaluator_slot" entry = `String "failed-lookup-source");
              Alcotest.(check bool) "failure retains the original lookup name" true
                (member "tool_name" entry = `String "keeper_read_file");
              Alcotest.(check bool) "failure retains actual lookup arguments" true (member "arguments" entry = args);
              Alcotest.(check bool) "failure disposition remains authoritative" true
                (member "disposition" entry = `String (Tool_result.string_of_disposition raw));
              (match actual_refusal with
               | Some { Masc.Tool_bridge.kind; message } ->
                 let wire_kind = match kind with
                   | Masc.Tool_bridge.Inline_budget_exceeded -> "inline_budget_exceeded"
                   | Masc.Tool_bridge.Artifact_storage_failure -> "artifact_storage_failure" in
                 Alcotest.(check bool) "a rejected full failure envelope cannot be smuggled as raw result" true
                   (member "result" entry = `Null);
                 Alcotest.(check bool) "failure handoff carries the actual bridge refusal" true
                   (member "projection_refusal" entry
                    = `Assoc ["kind", `String wire_kind; "message", `String message])
               | None ->
                 Alcotest.(check bool) "small failure preserves actual content/is_error/recoverable/error_class" true
                   (member "result" entry = model_result);
                 Alcotest.(check bool) "an accepted failure has no invented projection refusal" true
                   (member "projection_refusal" entry = `Null));
              Alcotest.(check bool) "large metadata/data payload never enters any handoff text" false
                (List.exists (function T.Text text -> String_util.contains_substring text payload
                  | T.Thinking _ | T.RedactedThinking _ | T.ReasoningDetails _
                  | T.ToolUse _ | T.ToolResult _ | T.Image _ | T.Document _ | T.Audio _ -> false) blocks);
              Ok { AR.selected_runtime_id = evaluator_runtime; evaluator_execution = None; verdict = Some (AR.Approve "checked failure view") }
            end)
          (fun () ->
            let result = AR.run ~log_info:ignore ~log_warn:ignore ~render_prompt:(fun () -> Ok prompt)
                ~goal_blocks:[attachment] ~lookup:source_lookup ~provider_rest:(fun _ -> AR.No_stated_rest)
                ~base_path:(Filename.get_temp_dir_name ()) () in
            Alcotest.(check (list string)) "failure proceeds in declared slot order"
              ["failed-lookup-source"; "failed-lookup-next"] !calls;
            Alcotest.(check int) "one actual supplied failed lookup" 1 !reads;
            match result.verdict with
            | Some (AR.Approve "checked failure view") -> ()
            | Some (AR.Approve _) | Some (AR.Reject _) | None -> Alcotest.fail "failure handoff lost the later verdict"))) cases
;;

let () =
  configure_prompt_registry ();
  Alcotest.run
    "anti_rationalization_structured_only"
    [ ( "review boundary"
      , [ Alcotest.test_case "the accepted verdict response identity survives projection" `Quick
            test_exact_verdict_response_identity_survives_projection
        ; Alcotest.test_case "failed lookup handoff uses the full bridge envelope" `Quick
            test_failed_lookup_handoff_uses_the_full_bridge_envelope
        ; Alcotest.test_case "oversized lookup handoff retains the inline refusal" `Quick
            test_oversized_lookup_handoff_preserves_the_inline_refusal
        ; Alcotest.test_case "lookup evidence survives failover only within this review" `Quick
            test_lookup_evidence_survives_slot_failover_but_not_a_new_review
        ; Alcotest.test_case
            "structured tool verdict"
            `Quick
            test_structured_tool_is_the_only_semantic_verdict
        ; Alcotest.test_case
            "explicit BasePath reaches reviewer"
            `Quick
            test_explicit_base_path_reaches_reviewer
        ; Alcotest.test_case
            "response text ignored"
            `Quick
            test_response_text_is_never_parsed_as_verdict
        ; Alcotest.test_case
            "provider failure unavailable"
            `Quick
            test_evaluator_failure_is_unavailable_not_reject
        ; Alcotest.test_case
            "structural budget failure is not retryable"
            `Quick
            test_structural_budget_failure_is_not_retryable
        ; Alcotest.test_case
            "rate limit failure stays retryable"
            `Quick
            test_rate_limit_failure_stays_retryable
        ; Alcotest.test_case
            "reject without reason is malformed"
            `Quick
            test_reject_without_reason_is_malformed
        ; Alcotest.test_case
            "reject reason is preserved"
            `Quick
            test_reject_reason_is_preserved
        ; Alcotest.test_case
            "approve reason is preserved"
            `Quick
            test_approve_reason_is_preserved
        ; Alcotest.test_case
            "evidence meaning stays with reviewer"
            `Quick
            test_evidence_text_is_not_classified_before_llm_review
        ; Alcotest.test_case
            "verdict enum mirrors valid_verdict_strings"
            `Quick
            test_verdict_enum_mirrors_valid_verdict_strings
        ; Alcotest.test_case
            "note-only verdict stays with the reviewer"
            `Quick
            test_note_only_verdict_is_owned_by_the_reviewer
        ; Alcotest.test_case
            "successful lookup is exposed to the reviewer"
            `Quick
            test_successful_lookup_is_exposed_to_the_reviewer
        ; Alcotest.test_case
            "a REJECT resent with its reason is the verdict"
            `Quick
            test_resent_reject_with_reason_is_the_verdict
        ; Alcotest.test_case
            "a resend that flips the decision stays a violation"
            `Quick
            test_resend_that_flips_the_decision_stays_a_violation
        ; Alcotest.test_case
            "a resend after an unreadable refusal stays a violation"
            `Quick
            test_resend_after_unreadable_refusal_stays_a_violation
        ; Alcotest.test_case
            "a second call after a verdict is a violation"
            `Quick
            test_second_call_after_a_verdict_is_a_violation
        ; Alcotest.test_case
            "only the latest refusal counts"
            `Quick
            test_only_the_latest_refusal_counts
        ; Alcotest.test_case
            "a flip to a reasonless APPROVE stays a violation"
            `Quick
            test_flip_to_reasonless_approve_stays_a_violation
        ] )
    ]
