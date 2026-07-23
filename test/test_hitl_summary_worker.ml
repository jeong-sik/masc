open Alcotest

module EO = Agent_sdk.Exact_output
module F = Compaction_exact_output_fixture
module Gate = Masc.Keeper_gate
module Q = Masc.Keeper_approval_queue
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

let pending_entry
      ?(input_tag = "default")
      ?(keeper_name = "keeper")
      ~base_path
      ()
  =
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
        ~keeper_name
        ~tool_name:"external-effect"
        ~input:
          (`Assoc
             [ "target", `String "document"
             ; "body", `String "hello"
             ; "input_tag", `String input_tag
             ])
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
    Runtime.publish_exact_output_registry
      ~lanes:[ { Runtime_schema.id = Worker.For_testing.lane_id; slot_ids } ]
      snapshot
  with
  | Ok _ -> ()
  | Error detail -> fail detail
;;

let run_eio f =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio_context.with_test_env
    ~net
    ~clock
    ~mono_clock:(Eio.Stdenv.mono_clock env)
    ~sw
  @@ fun () -> f ~sw ~net ~clock
;;

let run_eio_without_context f =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  f
    ~sw
    ~net:(Eio.Stdenv.net env)
    ~clock:(Eio.Stdenv.clock env)
    ~mono_clock:(Eio.Stdenv.mono_clock env)
;;

let prepare_exn entry =
  match Worker.For_testing.prepare_flow ~entry with
  | Ok prepared -> prepared
  | Error detail -> fail detail
;;

let visible_after_rename_writer path body =
  match Fs_compat.save_file_atomic path body with
  | Error reason -> failf "visible writer could not replace %s: %s" path reason
  | Ok () ->
    Error
      { Fs_compat.path
      ; stage = Fs_compat.After_rename
      ; exception_ = Failure "injected parent-directory sync failure"
      ; backtrace = Printexc.get_raw_backtrace ()
      }
;;

exception Unknown_writer_failure
exception Cancel_after_request_arrived

let unknown_writer _path _body = raise Unknown_writer_failure

let rec await_condition ~clock ~remaining ~failure predicate =
  if predicate ()
  then ()
  else if remaining = 0
  then fail failure
  else (
    Eio.Time.sleep clock 0.01;
    await_condition ~clock ~remaining:(remaining - 1) ~failure predicate)
;;

let select_auto_judge_mode base_path =
  match
    Masc.Keeper_gate_mode.set
      (Masc.Workspace.default_config base_path)
      ~actor:"test"
      Masc.Keeper_gate_mode.Auto_judge
  with
  | Ok _ -> ()
  | Error detail -> fail ("failed to select Auto Judge mode: " ^ detail)
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
  let entry = pending_entry ~base_path () in
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
  let entry = pending_entry ~base_path () in
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

let test_json_mode_request_carries_canonical_domain_schema () =
  run_eio @@ fun ~sw ~net ~clock ->
  with_temp_dir "hitl-json-mode-contract" @@ fun base_path ->
  Fun.protect
    ~finally:Q.For_testing.reset_runtime_state
    (fun () ->
       install_queue base_path;
       Prompt_registry.set_markdown_dir
         (Masc_test_deps.source_path "config/prompts");
       let server =
         F.start_server
           ~sw
           ~net
           ~clock
           (F.Reply (F.openai_response (judgment_json "approve")))
       in
       publish_lane
         [ "hitl-json-mode-contract" ]
         (F.resolver_snapshot
            ~supports_structured_output:false
            ~source:"hitl-json-mode-contract"
            [ { id = "hitl-json-mode-contract"; base_url = server.base_url } ]);
       let entry = pending_entry ~base_path () in
       Worker.For_testing.execute_prepared_flow
         ~net
         ~clock
         ~on_summary:(fun _ -> ())
         (prepare_exn entry);
       let request_body =
         match F.request_bodies server with
         | [ body ] -> Yojson.Safe.from_string body
         | bodies ->
           failf "expected one JSON-mode request, got %d" (List.length bodies)
       in
       let open Yojson.Safe.Util in
       check
         string
         "JSON-only target receives JsonMode"
         "json_object"
         (request_body |> member "response_format" |> member "type" |> to_string);
       let message_text =
         request_body
         |> member "messages"
         |> to_list
         |> List.map (fun message -> message |> member "content" |> to_string)
         |> String.concat "\n"
       in
       List.iter
         (fun field ->
            check bool
              ("request contains canonical field " ^ field)
              true
              (Astring.String.is_infix ~affix:field message_text))
         [ "context_summary"; "key_questions"; "judgment"; "rationale" ];
       check bool
         "request contains closed-schema constraint"
         true
         (Astring.String.is_infix
            ~affix:{|"additionalProperties":false|}
            message_text))
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
       let entry = pending_entry ~base_path () in
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
       let entry = pending_entry ~base_path () in
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
       let entry = pending_entry ~base_path () in
       match Worker.For_testing.prepare_flow ~entry with
       | Ok _ -> fail "incapable candidate unexpectedly admitted"
       | Error detail ->
         check bool "admission failure is explicit" true
           (Astring.String.is_infix ~affix:"admitted no candidates" detail);
         (match Q.get_pending_entry ~id:entry.id with
          | Some { exact_attempt = Q.Exact_unbound; _ } -> ()
          | _ -> fail "admission failure mutated the exact queue binding"))
;;

let test_visible_bind_blocks_dispatch () =
  run_eio @@ fun ~sw ~net ~clock ->
  with_temp_dir "hitl-visible-bind" @@ fun base_path ->
  Fun.protect
    ~finally:Q.For_testing.reset_runtime_state
    (fun () ->
       install_queue base_path;
       Prompt_registry.set_markdown_dir
         (Masc_test_deps.source_path "config/prompts");
       let server =
         F.start_server
           ~sw
           ~net
           ~clock
           (F.Reply (F.openai_response (judgment_json "approve")))
       in
       publish_lane
         [ "hitl-visible-bind" ]
         (F.resolver_snapshot
            ~source:"hitl-visible-bind"
            [ { id = "hitl-visible-bind"; base_url = server.base_url } ]);
       let entry = pending_entry ~base_path () in
       Worker.For_testing.execute_prepared_flow_with_writers
         ~bind_writer:visible_after_rename_writer
         ~net
         ~clock
         ~on_summary:(fun _ -> fail "unconfirmed bind delivered a summary")
         (prepare_exn entry);
       check int "unconfirmed bind forbids POST" 0 (F.post_count server);
       match Q.get_pending_entry ~id:entry.id with
       | Some
           { exact_attempt =
               Q.Exact_bound
                 { status =
                     Q.Exact_quarantined Q.Exact_terminal_persistence_failure
                 ; _
                 }
           ; _
           } ->
         ()
       | _ -> fail "unconfirmed bind was not terminally quarantined")
;;

let test_visible_advance_blocks_successor () =
  run_eio @@ fun ~sw ~net ~clock ->
  with_temp_dir "hitl-visible-advance" @@ fun base_path ->
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
           (F.Reply (F.openai_response (judgment_json "approve")))
       in
       let fixtures : F.target_fixture list =
         [ { id = "hitl-advance-unreachable"; base_url = "http://127.0.0.1:1" }
         ; { id = "hitl-advance-successor"; base_url = successor.base_url }
         ]
       in
       publish_lane
         [ "hitl-advance-unreachable"; "hitl-advance-successor" ]
         (F.resolver_snapshot ~source:"hitl-visible-advance" fixtures);
       let entry = pending_entry ~base_path () in
       Worker.For_testing.execute_prepared_flow_with_writers
         ~release_writer:visible_after_rename_writer
         ~net
         ~clock
         ~on_summary:(fun _ -> fail "unconfirmed release advanced the flow")
         (prepare_exn entry);
       check int "unconfirmed release forbids successor POST" 0 (F.post_count successor);
       match Q.get_pending_entry ~id:entry.id with
       | Some
           { exact_attempt =
               Q.Exact_bound
                 { status =
                     Q.Exact_quarantined Q.Exact_terminal_persistence_failure
                 ; _
                 }
           ; _
           } ->
         ()
       | _ -> fail "unconfirmed release was not terminally quarantined")
;;

let test_visible_completion_blocks_gate_delivery () =
  run_eio @@ fun ~sw ~net ~clock ->
  with_temp_dir "hitl-visible-completion" @@ fun base_path ->
  Fun.protect
    ~finally:Q.For_testing.reset_runtime_state
    (fun () ->
       install_queue base_path;
       Prompt_registry.set_markdown_dir
         (Masc_test_deps.source_path "config/prompts");
       let server =
         F.start_server
           ~sw
           ~net
           ~clock
           (F.Reply (F.openai_response (judgment_json "approve")))
       in
       publish_lane
         [ "hitl-visible-completion" ]
         (F.resolver_snapshot
            ~source:"hitl-visible-completion"
            [ { id = "hitl-visible-completion"; base_url = server.base_url } ]);
       select_auto_judge_mode base_path;
       let entry = pending_entry ~base_path () in
       let successor = pending_entry ~input_tag:"successor" ~base_path () in
       let delivered = ref false in
       (match
          Worker.For_testing.execute_prepared_flow_with_writers
            ~complete_writer:visible_after_rename_writer
            ~net
            ~clock
            ~on_summary:(fun _ -> delivered := true)
            (prepare_exn entry)
        with
        | exception Worker.Exact_terminalization_persistence_failed _ -> ()
        | () -> fail "visible completion did not signal persistence uncertainty");
       check int "provider completed once" 1 (F.post_count server);
       check bool "unconfirmed completion forbids Gate delivery" false !delivered;
       (match Q.get_pending_entry ~id:entry.id with
       | Some
           { exact_attempt =
               Q.Exact_bound { status = Q.Exact_completed; _ }
           ; summary_status = Q.Summary_available _
           ; _
           } ->
         ()
       | _ -> fail "visible completion did not retain recoverable completed state");
       install_queue base_path;
       let recovery = Gate.resume_persisted_auto_judges ~base_path in
       check
         (list string)
         "restart finalizes only the uncertain oldest entry"
         [ entry.id ]
         recovery.finalized_ids;
       check
         (list string)
         "restart does not cross the finalization barrier"
         []
         recovery.started_ids;
       check int "restart did not dispatch successor" 1 (F.post_count server);
       (match Q.get_pending_entry ~id:successor.id with
        | Some
            { exact_attempt = Q.Exact_unbound
            ; summary_status = Q.Summary_pending
            ; _
            } ->
          ()
        | _ -> fail "restart skipped the oldest finalization barrier"))
;;

let test_flow_execution_failure_quarantines_and_blocks_owner () =
  run_eio @@ fun ~sw ~net ~clock ->
  with_temp_dir "hitl-flow-failure" @@ fun base_path ->
  Fun.protect
    ~finally:Q.For_testing.reset_runtime_state
    (fun () ->
       install_queue base_path;
       Prompt_registry.set_markdown_dir
         (Masc_test_deps.source_path "config/prompts");
       let failed = F.start_server ~sw ~net ~clock F.Abort_after_request in
       let fixtures : F.target_fixture list =
         [ { id = "hitl-flow-failed"; base_url = failed.base_url } ]
       in
       publish_lane
         [ "hitl-flow-failed" ]
         (F.resolver_snapshot ~source:"hitl-flow-failure" fixtures);
       select_auto_judge_mode base_path;
       let entry = pending_entry ~input_tag:"failed" ~base_path () in
       let successor = pending_entry ~input_tag:"successor" ~base_path () in
       Worker.For_testing.execute_prepared_flow
         ~net
         ~clock
         ~on_summary:(fun _ -> fail "flow execution failure delivered a summary")
         (prepare_exn entry);
       check int "failed candidate dispatched once" 1 (F.post_count failed);
       (match Q.get_pending_entry ~id:entry.id with
        | Some
            { input_hash
            ; sequence
            ; summary_status =
                Q.Summary_failed { reason; retryable = false }
            ; exact_attempt =
                Q.Exact_bound
                  { slot_id
                  ; call_id
                  ; plan_fingerprint
                  ; request_body_sha256
                  ; status = Q.Exact_quarantined Q.Exact_flow_execution_failed
                  ; _
                  }
            ; _
            } ->
          check
            string
            "terminal summary reason"
            "Auto Judge exact attempt quarantined: flow_execution_failed"
            reason;
          check string "quarantine input identity" entry.input_hash input_hash;
          check int "quarantine sequence identity" entry.sequence sequence;
          check string "quarantine opaque slot identity" "hitl-flow-failed" slot_id;
          check bool "quarantine call identity" true (String.length call_id > 0);
          check bool
            "quarantine plan identity"
            true
            (String.length plan_fingerprint > 0);
          check bool
            "quarantine request identity"
            true
            (String.length request_body_sha256 > 0)
        | _ -> fail "flow execution failure was not terminally quarantined");
       let blocked = Gate.resume_persisted_auto_judges ~base_path in
       check
         (list string)
         "quarantined owner starts no successor worker"
         []
         blocked.started_ids;
       check int "quarantined owner dispatches no successor" 1 (F.post_count failed);
       match Q.get_pending_entry ~id:successor.id with
       | Some
           { exact_attempt = Q.Exact_unbound
           ; summary_status = Q.Summary_pending
           ; _
           } ->
         ()
       | _ -> fail "quarantined owner did not preserve its unbound successor")
;;

let test_manual_resolution_race_is_conclusive () =
  run_eio @@ fun ~sw ~net ~clock ->
  with_temp_dir "hitl-manual-resolution-race" @@ fun base_path ->
  Fun.protect
    ~finally:Q.For_testing.reset_runtime_state
    (fun () ->
       install_queue base_path;
       Prompt_registry.set_markdown_dir
         (Masc_test_deps.source_path "config/prompts");
       let in_flight_entry : Q.pending_approval option ref = ref None in
       let server =
         F.start_server
           ~on_request_before_reply:(fun () ->
             match !in_flight_entry with
             | None -> fail "manual resolution raced before entry publication"
             | Some entry ->
               (match
                  Q.resolve_with_policy
                    ~base_path
                    ~id:entry.id
                    ~decision:(Q.Decision.Reject "manual operator resolution")
                    ()
                with
                | Ok _ -> ()
                | Error error -> fail (Q.resolve_error_to_string error)))
           ~sw
           ~net
           ~clock
           (F.Reply (F.openai_response (judgment_json "approve")))
       in
       publish_lane
         [ "hitl-manual-resolution-race" ]
         (F.resolver_snapshot
            ~source:"hitl-manual-resolution-race"
            [ { id = "hitl-manual-resolution-race"; base_url = server.base_url } ]);
       let entry = pending_entry ~base_path () in
       in_flight_entry := Some entry;
       let delivered = ref false in
       let finish_outcome = ref None in
       (match
          Worker.For_testing.spawn_with_writers
            ~sw
            ~entry
            ~on_summary:(fun _ -> delivered := true)
            ~on_finish:(fun outcome -> finish_outcome := Some outcome)
            ()
        with
        | Ok () -> ()
        | Error detail -> fail detail);
       await_condition
         ~clock
         ~remaining:100
         ~failure:"manual resolution race did not finish"
         (fun () -> Option.is_some !finish_outcome);
       check int "in-flight request dispatched exactly once" 1 (F.post_count server);
       check bool "late Auto Judge summary was not delivered" false !delivered;
       check bool
         "manual resolution is conclusive for owner cleanup"
         true
         (match !finish_outcome with
          | Some Worker.Conclusive_terminalization -> true
          | Some Worker.Terminalization_persistence_uncertain | None -> false);
       check bool
         "manually resolved source left pending queue"
         true
         (Option.is_none (Q.get_pending_entry ~id:entry.id)))
;;

let test_cancellation_after_dispatch_is_terminal () =
  run_eio @@ fun ~sw ~net ~clock ->
  with_temp_dir "hitl-cancellation" @@ fun base_path ->
  Fun.protect
    ~finally:Q.For_testing.reset_runtime_state
    (fun () ->
       install_queue base_path;
       Prompt_registry.set_markdown_dir
         (Masc_test_deps.source_path "config/prompts");
       let server =
         F.start_server
           ~sw
           ~net
           ~clock
           (F.Delay_then_reply
              (60.0, F.openai_response (judgment_json "approve")))
       in
       publish_lane
         [ "hitl-cancelled" ]
         (F.resolver_snapshot
            ~source:"hitl-cancellation"
            [ { id = "hitl-cancelled"; base_url = server.base_url } ]);
       let entry = pending_entry ~base_path () in
       (match
          Eio.Fiber.first
            (fun () ->
               Worker.For_testing.execute_prepared_flow
                 ~net
                 ~clock
                 ~on_summary:(fun _ -> fail "cancelled flow delivered a summary")
                 (prepare_exn entry))
            (fun () ->
               F.await_first_request server;
               raise Cancel_after_request_arrived)
        with
        | exception Cancel_after_request_arrived -> ()
        | () -> fail "cancellation trigger did not win");
       match Q.get_pending_entry ~id:entry.id with
       | Some
           { exact_attempt =
               Q.Exact_bound
                 { status = Q.Exact_quarantined Q.Exact_cancellation; _ }
           ; _
           } ->
         ()
       | _ -> fail "post-dispatch cancellation was not terminally quarantined")
;;

let test_pre_worker_start_failure_is_retryable () =
  run_eio @@ fun ~sw:_ ~net:_ ~clock:_ ->
  with_temp_dir "hitl-pre-worker-start-failure" @@ fun base_path ->
  Fun.protect
    ~finally:Q.For_testing.reset_runtime_state
    (fun () ->
       install_queue base_path;
       select_auto_judge_mode base_path;
       let entry = pending_entry ~base_path () in
       let successor = pending_entry ~input_tag:"successor" ~base_path () in
       (match
          Gate.For_testing.spawn_auto_judge_entry_with_worker
            ~spawn_worker:
              (fun ~sw:_ ~entry:_ ~on_summary:_ ~on_finish:_ () ->
                 Error "no usable exact-output lane slots")
            entry
        with
        | Error detail ->
          check
            string
            "pre-worker failure is returned"
            "no usable exact-output lane slots"
            detail
        | Ok _ -> fail "pre-worker failure was reported as a successful start");
       match Q.get_pending_entry ~id:entry.id with
       | Some
           { exact_attempt = Q.Exact_unbound
           ; summary_status = Q.Summary_failed { reason; retryable = true }
           ; _
           } ->
         check
           string
           "retryable failure reason is durable"
           "no usable exact-output lane slots"
           reason
       | _ -> fail "pre-worker failure was not durably retryable")
       ;
       check
         bool
         "pre-worker failure releases the owner claim"
         true
         (Gate.For_testing.claim_auto_judge successor);
       Gate.For_testing.release_auto_judge successor
;;

let test_visible_uncertainty_withholds_production_drain () =
  run_eio_without_context @@ fun ~sw ~net ~clock ~mono_clock ->
  with_temp_dir "hitl-uncertain-lifecycle" @@ fun base_path ->
  Fun.protect
    ~finally:Q.For_testing.reset_runtime_state
    (fun () ->
       install_queue base_path;
       Prompt_registry.set_markdown_dir
         (Masc_test_deps.source_path "config/prompts");
       let server =
         F.start_server
           ~sw
           ~net
           ~clock
           (F.Reply (F.openai_response (judgment_json "approve")))
       in
       publish_lane
         [ "hitl-uncertain-lifecycle" ]
         (F.resolver_snapshot
            ~source:"hitl-uncertain-lifecycle"
            [ { id = "hitl-uncertain-lifecycle"; base_url = server.base_url } ]);
       select_auto_judge_mode base_path;
       let uncertain = pending_entry ~input_tag:"uncertain" ~base_path () in
       let successor = pending_entry ~input_tag:"successor" ~base_path () in
       let writer_reached, resolve_writer_reached = Eio.Promise.create () in
       let visible_writer path body =
         let outcome = visible_after_rename_writer path body in
         ignore (Eio.Promise.try_resolve resolve_writer_reached ());
         outcome
       in
       let supervisor_observed_uncertainty =
         match
           Eio.Switch.run
           @@ fun worker_sw ->
           Eio_context.with_test_env
             ~net
             ~clock
             ~mono_clock
             ~sw:worker_sw
           @@ fun () ->
           (match
              Gate.For_testing.spawn_auto_judge_entry_with_worker
                ~spawn_worker:
            (fun ~sw ~entry ~on_summary ~on_finish () ->
                     Worker.For_testing.spawn_with_writers
                       ~complete_writer:visible_writer
                       ~sw
                       ~entry
                       ~on_summary
                       ~on_finish
                       ())
                uncertain
            with
            | Ok true -> ()
            | Ok false -> fail "production Gate chain did not claim oldest work"
            | Error detail -> fail detail);
           Eio.Promise.await writer_reached;
           false
         with
         | exception Worker.Exact_terminalization_persistence_failed _ -> true
         | observed -> observed
       in
       check bool
         "typed persistence uncertainty reached the worker supervisor"
         true
         supervisor_observed_uncertainty;
       check int "only the uncertain entry dispatched" 1 (F.post_count server);
       (match Q.get_pending_entry ~id:uncertain.id with
       | Some
           { exact_attempt =
               Q.Exact_bound { status = Q.Exact_completed; _ }
           ; summary_status = Q.Summary_available _
           ; _
           } ->
         ()
       | _ -> fail "uncertain completion did not remain durably visible");
       (match Q.get_pending_entry ~id:successor.id with
        | Some
            { exact_attempt = Q.Exact_unbound
            ; summary_status = Q.Summary_pending
            ; _
            } ->
          ()
        | _ -> fail "uncertainty lifecycle dispatched the same-owner successor");
       check bool
         "uncertain lifecycle released the active-owner claim"
         true
         (Gate.For_testing.claim_auto_judge successor);
       Gate.For_testing.release_auto_judge successor)
;;

let test_owner_fifo_atomic_drain_is_nonsharing () =
  run_eio @@ fun ~sw ~net ~clock ->
  with_temp_dir "hitl-owner-fifo-drain" @@ fun base_path ->
  Fun.protect
    ~finally:Q.For_testing.reset_runtime_state
    (fun () ->
       install_queue base_path;
       Prompt_registry.set_markdown_dir
         (Masc_test_deps.source_path "config/prompts");
       let release_first, resolve_release_first = Eio.Promise.create () in
       let request_index = Atomic.make 0 in
       let server =
         F.start_server
           ~on_request_before_reply:(fun () ->
             if Atomic.fetch_and_add request_index 1 = 0
             then Eio.Promise.await release_first)
           ~sw
           ~net
           ~clock
           (F.Reply (F.openai_response (judgment_json "approve")))
       in
       publish_lane
         [ "hitl-owner-fifo-drain" ]
         (F.resolver_snapshot
            ~source:"hitl-owner-fifo-drain"
            [ { id = "hitl-owner-fifo-drain"; base_url = server.base_url } ]);
       select_auto_judge_mode base_path;
       let first = pending_entry ~input_tag:"first" ~base_path () in
       let second = pending_entry ~input_tag:"second" ~base_path () in
       let initial = Gate.resume_persisted_auto_judges ~base_path in
       check
         (list string)
         "production recovery claims the oldest owner entry"
         [ first.id ]
         initial.started_ids;
       F.await_first_request server;
       let concurrent = Gate.resume_persisted_auto_judges ~base_path in
       check
         (list string)
         "concurrent drain cannot claim the same owner"
         []
         concurrent.started_ids;
       Eio.Time.sleep clock 0.02;
       check int
         "later owner work is not dispatched concurrently"
         1
         (F.post_count server);
       (match Q.get_pending_entry ~id:second.id with
        | Some
            { exact_attempt = Q.Exact_unbound
            ; summary_status = Q.Summary_pending
            ; _
            } ->
          ()
        | _ -> fail "later owner work was mutated before the oldest completed");
       ignore (Eio.Promise.try_resolve resolve_release_first ());
       await_condition
         ~clock
         ~remaining:100
         ~failure:"owner drain did not dispatch the FIFO successor"
         (fun () -> F.post_count server = 2);
       await_condition
         ~clock
         ~remaining:100
         ~failure:"FIFO successor did not complete"
         (fun () -> Option.is_none (Q.get_pending_entry ~id:second.id));
       check int
         "each owner entry dispatches exactly once"
         2
         (F.post_count server))
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
            "JSON-mode request carries canonical schema"
            `Quick
            test_json_mode_request_carries_canonical_domain_schema
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
        ; test_case
            "visible bind blocks dispatch"
            `Quick
            test_visible_bind_blocks_dispatch
        ; test_case
            "visible advance blocks successor"
            `Quick
            test_visible_advance_blocks_successor
        ; test_case
            "visible completion blocks Gate delivery"
            `Quick
            test_visible_completion_blocks_gate_delivery
        ; test_case
            "flow execution failure quarantines and blocks owner"
            `Quick
            test_flow_execution_failure_quarantines_and_blocks_owner
        ; test_case
            "manual resolution race is conclusive"
            `Quick
            test_manual_resolution_race_is_conclusive
        ; test_case
            "post-dispatch cancellation is terminal"
            `Quick
            test_cancellation_after_dispatch_is_terminal
        ; test_case
            "pre-worker start failure is retryable"
            `Quick
            test_pre_worker_start_failure_is_retryable
        ; test_case
            "visible uncertainty withholds production drain"
            `Quick
            test_visible_uncertainty_withholds_production_drain
        ; test_case
            "owner FIFO atomic drain is non-sharing"
            `Quick
            test_owner_fifo_atomic_drain_is_nonsharing
        ] )
    ]
;;
