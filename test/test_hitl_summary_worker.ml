open Alcotest

module EO = Agent_sdk.Exact_output
module F = Compaction_exact_output_fixture
module Q = Masc.Keeper_approval_queue
module Registry = Masc.Runtime_exact_output_registry
module Schema = Masc.Keeper_structured_output_schema
module Worker = Masc.Hitl_summary_worker

let yojson = testable Yojson.Safe.pretty_print Yojson.Safe.equal

let judgment_json judgment =
  `Assoc
    [ "context_summary", `String "The exact action matches visible context."
    ; "key_questions", `List [ `String "Is the target current?" ]
    ; "judgment", `String judgment
    ; "rationale", `String "The visible evidence supports this judgment."
    ]
;;

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Unix.unlink path
;;

let with_temp_dir prefix f =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> rm_rf path) (fun () -> f path)
;;

let install_queue base_path =
  Q.For_testing.reset_runtime_state ();
  match Q.install_persistence ~base_path with
  | Ok _ -> ()
  | Error error -> fail (Q.install_error_to_string error)
;;

let pending_entry ~base_path =
  let request_context =
    `Assoc
      [ ( "initial"
        , `Assoc
            [ "history_messages", `List [ `String "older turn" ]
            ; "base_system_prompt", `String "base policy"
            ; "turn_system_prompt", `String "turn policy"
            ; "user_message", `String "inspect the exact requested operation"
            ; "dynamic_context", `String "current context"
            ; "runtime_id", `String "opaque"
            ] )
      ; "completed_tool_calls", `List []
      ]
  in
  let id =
    match
      Q.submit_pending
        ~keeper_name:"keeper"
        ~tool_name:"external-effect"
        ~input:(`Assoc [ "target", `String "document"; "body", `String "hello" ])
        ~base_path
        ~request_context
        ()
    with
    | Ok id -> id
    | Error error -> fail (Q.storage_error_to_string error)
  in
  (match Q.mark_summary_pending ~id with
   | Ok true -> ()
   | Ok false -> fail "summary did not enter pending state"
   | Error error -> fail (Q.summary_transition_error_to_string error));
  match Q.get_pending_entry ~id with
  | Some entry -> entry
  | None -> fail "pending approval disappeared"
;;

let publish_lane slot_ids snapshot =
  match
    Registry.publish
      ~lanes:[ { Masc.Runtime_schema.id = Worker.For_testing.lane_id; slot_ids } ]
      snapshot
  with
  | Ok _ -> ()
  | Error error -> fail (Registry.publication_error_to_string error)
;;

let run_eio f =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  f
    ~sw
    ~net:(Eio.Stdenv.net env)
    ~clock:(Eio.Stdenv.clock env)
;;

let prepare_exn entry =
  match Worker.For_testing.prepare_flow ~entry with
  | Ok prepared -> prepared
  | Error detail -> fail detail
;;

let test_parse_typed_judgments () =
  List.iter
    (fun (wire, expected) ->
       let summary =
         match
           Worker.For_testing.parse_summary
             ~generated_at:1780587600.0
             ~model_run_id:"run"
             (judgment_json wire)
         with
         | Ok summary -> summary
         | Error reason -> fail reason
       in
       check bool wire true (summary.judgment = expected))
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

let test_context_bundle_is_exact () =
  with_temp_dir "hitl-context" @@ fun base_path ->
  install_queue base_path;
  let entry = pending_entry ~base_path in
  match Worker.For_testing.build_context_bundle ~entry with
  | Error error -> fail (Worker.For_testing.context_bundle_error_to_string error)
  | Ok bundle ->
    let open Yojson.Safe.Util in
    check yojson "exact input" entry.input (bundle |> member "input");
    check yojson
      "exact outer-turn context"
      (Option.get entry.request_context)
      (bundle |> member "request_context");
    check yojson "no derived classification" `Null (bundle |> member "classification")
;;

let test_missing_context_is_terminal_before_admission () =
  with_temp_dir "hitl-missing-context" @@ fun base_path ->
  install_queue base_path;
  let entry = pending_entry ~base_path in
  match
    Worker.For_testing.prepare_flow
      ~entry:{ entry with request_context = None }
  with
  | Ok _ -> fail "missing exact context admitted an OAS flow"
  | Error detail ->
    check string
      "stable failure"
      "HITL summary: exact outer-turn request context is unavailable"
      detail
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

let admission_id = function
  | EO.Candidate_admitted candidate -> candidate.identity.candidate_id
  | EO.Candidate_rejected { identity; _ } -> identity.candidate_id
;;

let test_flow_order_completion_and_replay () =
  run_eio @@ fun ~sw ~net ~clock ->
  with_temp_dir "hitl-flow" @@ fun base_path ->
  Fun.protect
    ~finally:Q.For_testing.reset_runtime_state
    (fun () ->
       install_queue base_path;
       Prompt_registry.set_markdown_dir
         (Masc_test_deps.source_path "config/prompts");
       let first =
         F.start_server
           ~sw
           ~net
           ~clock
           (F.Reply (F.openai_response (judgment_json "approve")))
       in
       let second =
         F.start_server
           ~sw
           ~net
           ~clock
           (F.Reply (F.openai_response (judgment_json "deny")))
       in
       let fixtures : F.target_fixture list =
         [ { id = "hitl-first"; base_url = first.base_url }
         ; { id = "hitl-second"; base_url = second.base_url }
         ]
       in
       let snapshot =
         F.resolver_snapshot ~source:"hitl-flow-order" fixtures
       in
       publish_lane [ "hitl-first"; "hitl-second" ] snapshot;
       let entry = pending_entry ~base_path in
       let prepared = prepare_exn entry in
       let evidence = Worker.For_testing.flow_evidence prepared in
       check
         (list string)
         "immutable admission order"
         [ "hitl-first"; "hitl-second" ]
         (List.map admission_id evidence.admissions);
       let delivered = ref None in
       Worker.For_testing.execute_prepared_flow
         ~net
         ~clock
         ~on_summary:(fun summary -> delivered := Some summary)
         prepared;
       check int "first candidate posted once" 1 (F.post_count first);
       check int "second candidate not used" 0 (F.post_count second);
       (match Q.get_pending_entry ~id:entry.id with
        | Some
            { exact_attempt =
                Q.Exact_bound
                  { slot_id = "hitl-first"; status = Q.Exact_completed; _ }
            ; summary_status = Q.Summary_available _
            ; _
            } ->
          ()
        | _ -> fail "successful flow did not durably complete its exact binding");
       check bool "validated summary delivered" true (Option.is_some !delivered);
       Worker.For_testing.execute_prepared_flow
         ~net
         ~clock
         ~on_summary:(fun _ -> fail "replay delivered a second summary")
         prepared;
       check int "replay made no second POST" 1 (F.post_count first))
;;

let test_predispatch_failure_advances_only_to_oas_successor () =
  run_eio @@ fun ~sw ~net ~clock ->
  with_temp_dir "hitl-flow-failover" @@ fun base_path ->
  Fun.protect
    ~finally:Q.For_testing.reset_runtime_state
    (fun () ->
       install_queue base_path;
       Prompt_registry.set_markdown_dir
         (Masc_test_deps.source_path "config/prompts");
       let successor =
         F.start_server
           ~sw
           ~net
           ~clock
           (F.Reply (F.openai_response (judgment_json "require_human")))
       in
       let fixtures : F.target_fixture list =
         [ { id = "hitl-unreachable"; base_url = "http://127.0.0.1:1" }
         ; { id = "hitl-successor"; base_url = successor.base_url }
         ]
       in
       publish_lane
         [ "hitl-unreachable"; "hitl-successor" ]
         (F.resolver_snapshot ~source:"hitl-flow-failover" fixtures);
       let entry = pending_entry ~base_path in
       Worker.For_testing.execute_prepared_flow
         ~net
         ~clock
         ~on_summary:(fun _ -> ())
         (prepare_exn entry);
       check int "OAS-selected successor posted once" 1 (F.post_count successor);
       match Q.get_pending_entry ~id:entry.id with
       | Some
           { exact_attempt =
               Q.Exact_bound
                 { slot_id = "hitl-successor"; status = Q.Exact_completed; _ }
           ; _
           } ->
         ()
       | _ -> fail "pre-dispatch failover did not complete the predetermined successor")
;;

let incapable_snapshot base_url =
  let contents =
    Printf.sprintf
      "[[providers]]\n\
       id = \"hitl-incapable-provider\"\n\
       kind = \"openai_compat\"\n\
       base_url = %S\n\
       request_path = \"/v1/chat/completions\"\n\
       api_key_env = \"\"\n\n\
       [[models]]\n\
       id_prefix = \"hitl-incapable-model\"\n\
       provider_name = \"hitl-incapable-provider\"\n\
       max_context_tokens = 8192\n\
       max_output_tokens = 1024\n\
       supports_response_format_json = false\n\
       supports_structured_output = false\n\n\
       [[targets]]\n\
       id = \"hitl-incapable\"\n\
       provider_ref = \"hitl-incapable-provider\"\n\
       model_id = \"hitl-incapable-model\"\n"
      base_url
  in
  let io : EO.resolver_io = { getenv = (fun _ -> Ok None) } in
  match
    EO.load_resolver_snapshot
      ~io
      ~catalog:(EO.Embedded_with_overlay { source = "hitl-incapable"; contents })
      ()
  with
  | Ok snapshot -> snapshot
  | Error _ -> fail "incapable resolver snapshot did not load"
;;

let test_all_candidates_rejected_before_network () =
  with_temp_dir "hitl-all-rejected" @@ fun base_path ->
  Fun.protect
    ~finally:Q.For_testing.reset_runtime_state
    (fun () ->
       install_queue base_path;
       Prompt_registry.set_markdown_dir
         (Masc_test_deps.source_path "config/prompts");
       publish_lane
         [ "hitl-incapable" ]
         (incapable_snapshot "http://127.0.0.1:1");
       let entry = pending_entry ~base_path in
       match Worker.For_testing.prepare_flow ~entry with
       | Ok _ -> fail "incapable candidate unexpectedly admitted"
       | Error detail ->
         check bool "admission failure is explicit" true
           (Astring.String.is_infix ~affix:"admitted no candidates" detail);
         (match Q.get_pending_entry ~id:entry.id with
          | Some { exact_attempt = Q.Exact_unbound; _ } -> ()
          | _ -> fail "admission failure mutated the exact queue binding"))
;;

let test_gate_judgment_prompt_comes_from_registry () =
  Prompt_registry.set_markdown_dir
    (Masc_test_deps.source_path "config/prompts");
  match Worker.For_testing.system_prompt () with
  | Error detail -> fail ("Gate judgment prompt unavailable: " ^ detail)
  | Ok prompt -> check bool "prompt is non-empty" true (String.trim prompt <> "")
;;

let () =
  run
    "Hitl_summary_worker"
    [ ( "domain"
      , [ test_case "typed judgments" `Quick test_parse_typed_judgments
        ; test_case "invalid judgment fails loud" `Quick test_invalid_judgment_fails_loud
        ; test_case "exact context bundle" `Quick test_context_bundle_is_exact
        ; test_case
            "missing context fails before admission"
            `Quick
            test_missing_context_is_terminal_before_admission
        ; test_case
            "closed nonhierarchical schema"
            `Quick
            test_schema_is_closed_nonhierarchical_contract
        ; test_case
            "prompt is registry-owned"
            `Quick
            test_gate_judgment_prompt_comes_from_registry
        ] )
    ; ( "production exact flow"
      , [ test_case
            "order completion and replay"
            `Quick
            test_flow_order_completion_and_replay
        ; test_case
            "pre-dispatch failure advances to OAS successor"
            `Quick
            test_predispatch_failure_advances_only_to_oas_successor
        ; test_case
            "all candidates reject before network"
            `Quick
            test_all_candidates_rejected_before_network
        ] )
    ]
;;
