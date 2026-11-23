open Alcotest

(* CLI lane-slot fallback for librarian_exact:
   the classified exact-output pass walks the declared cli slots only after
   the catalog reports provider exhaustion, applies the working-context
   contract to each cli answer, and advances after a domain-invalid one.
   The runtime table is the fusion panel fixture (command /usr/bin/true)
   so [is_official_client] admits the cli ids without spawning a client. *)

module Librarian = Masc.Keeper_librarian
module Runtime = Masc.Keeper_librarian_runtime
module Current = Masc.Keeper_memory_os_current
module Cli = Masc.Keeper_lane_cli_oneshot
module Fixture = Exact_output_fixture

let served_slot =
  testable
    (fun fmt -> function
       | Runtime.Api_slot id -> Format.fprintf fmt "Api_slot %s" id
       | Runtime.Cli_slot id -> Format.fprintf fmt "Cli_slot %s" id)
    ( = )

let () = Masc.Prompt_defaults.init ()
;;

let input () : Librarian.input =
  { turn_ref = Ids.Turn_ref.make ~trace_id:"trace-cli-lane" ~absolute_turn:7
  ; goal_context = Masc.Keeper_librarian.No_task
  ; keeper_id = Masc_test_deps.keeper_id_fixture "cli-lane-keeper"
  ; keeper_instructions = "You are the cli-lane keeper."
  ; working_context = Masc.Keeper_librarian_context.empty
  }
;;

let valid_working_context_json =
  `Assoc [ Librarian.wire_field_working_contexts, `List [] ]
;;

let publish_unreachable_lane ?(cli_only = false) ?(projection_refused = false)
      ~cli_slot_ids ~source () =
  ignore
    (Fixture.publish_registry
       ~cli_slot_ids
       ~lane_id:"librarian_exact"
       ~slot_ids:(if cli_only then [] else [ "librarian-cli-unreachable" ])
       (Fixture.resolver_snapshot
          ~source
          ~enable_thinkings:(if projection_refused
            then [ "librarian-cli-unreachable", true ] else [])
          [ { Fixture.id = "librarian-cli-unreachable"
            ; base_url = "http://127.0.0.1:1"
            }
          ])
      : Runtime_exact_output_registry.t)
;;

let execute ~net ~clock ~base_path ~runner =
  let selected_input = input () in
  match Runtime.working_context_messages selected_input with
  | Error detail -> failf "librarian render failed: %s" detail
  | Ok messages ->
    Runtime.For_testing.execute_working_context_classified
      ~cli_runner:runner
      ~clock
      ~net
      ~base_path
      ~keeper_id:"librarian-cli-test"
      ~selected_input
      ~messages
      ()
;;

let with_eio f =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  Eio_context.with_test_env
    ~net:(Eio.Stdenv.net env)
    ~clock:(Eio.Stdenv.clock env)
    ~mono_clock:(Eio.Stdenv.mono_clock env)
    ~sw
  @@ fun () ->
  let base_path = Filename.temp_dir "librarian-cli-lane" "" in
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree base_path);
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key (Some base_path)
  @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key
    (Some (Filename.concat base_path "config"))
  @@ fun () ->
  f ~sw ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env) ~base_path
;;

let projection_failure =
  "request projection refused by all API slots: librarian-cli-unreachable: wire_admission_rejected:target_request_rejected"
;;

let test_execution_failure_names_cli_slot_once () =
  let runtime_id = "codex-cli-fixture" in
  let check_once cause =
    let detail = Cli.failure_to_string (Cli.Execution_failed { runtime_id; cause }) in
    (match Astring.String.cut ~sep:runtime_id detail with
     | None -> fail "the execution failure omitted its CLI slot"
     | Some (_, tail) ->
       check bool "the CLI slot is named once" false
         (Astring.String.is_infix ~affix:runtime_id tail));
    check bool "the adapter cause is retained" true
      (Astring.String.is_infix ~affix:"synthetic failure" detail)
  in
  check_once
    (Masc.Fusion_official_client.Codex_failure
       (Runtime_codex_app_server.Invalid_config "synthetic failure"));
  check_once
    (Masc.Fusion_official_client.Setup_failure "synthetic failure")
;;

let invalid_domain_failure () =
  match Librarian.working_contexts_of_json_result (input ()) (`Assoc []) with
  | Ok _ -> fail "empty object must fail the real Librarian decoder"
  | Error error -> Cli.Invalid_domain_output
      { runtime_id = Fixture.cli_primary_runtime
      ; detail = Librarian.parse_error_to_string error }
;;

let check_detail ?api_failure ?cli_failure detail =
  Option.iter (fun expected ->
    check bool "original API failure remains visible" true
      (Astring.String.is_infix ~affix:expected detail)) api_failure;
  Option.iter (fun failure ->
    check bool "CLI failure remains visible" true
      (Astring.String.is_infix ~affix:(Cli.failure_to_string failure) detail)) cli_failure
;;

let test_cli_slot_answers_after_catalog_exhaustion ?(cli_only = false) () =
  with_eio
  @@ fun ~sw:_ ~net ~clock ~base_path ->
  Fixture.with_official_client_runtimes
  @@ fun () ->
  publish_unreachable_lane ~cli_only
    ~cli_slot_ids:[ Fixture.cli_primary_runtime ]
    ~source:"librarian cli fallback" ();
  let seen = ref None in
  let runner ~runtime:{Runtime_instance.id=runtime_id;_} ~system_prompt:_ ~output_schema:_ ~prompt =
    seen := Some runtime_id;
    check bool
      "the cli prompt is the fitted librarian prompt"
      true
      (String.length prompt > 0);
    Ok (Yojson.Safe.to_string valid_working_context_json)
  in
  match execute ~net ~clock ~base_path ~runner with
  | Error error ->
    failf
      "the cli slot must answer: %s"
      (Runtime.For_testing.classified_error_detail error)
  | Ok ((_pockets, output), selected_slot) ->
    check (option string)
      "the declared cli slot ran"
      (Some Fixture.cli_primary_runtime)
      !seen;
    check served_slot
      "the answering slot is the cli runtime id"
      (Runtime.Cli_slot Fixture.cli_primary_runtime)
      selected_slot;
    check bool
      "the accepted output is the cli answer"
      true
      (Yojson.Safe.equal output valid_working_context_json)
;;

let test_domain_invalid_cli_answer_keeps_the_terminal () =
  with_eio
  @@ fun ~sw:_ ~net ~clock ~base_path ->
  Fixture.with_official_client_runtimes
  @@ fun () ->
  publish_unreachable_lane
    ~cli_slot_ids:[ Fixture.cli_primary_runtime; Fixture.cli_secondary_runtime ]
    ~source:"librarian cli invalid" ();
  let attempts = ref [] in
  let runner ~runtime:{Runtime_instance.id=runtime_id;_} ~system_prompt:_ ~output_schema:_ ~prompt:_ =
    attempts := !attempts @ [ runtime_id ];
    Ok "{}" (* valid JSON, invalid working-context domain *)
  in
  (match execute ~net ~clock ~base_path ~runner with
   | Ok _ -> fail "a domain-invalid cli answer must not be accepted"
   | Error error ->
     check bool
       "the catalog terminal survives the failed fallback"
       true
       (Astring.String.is_infix
          ~affix:"exact execution failed"
          (Runtime.For_testing.classified_error_detail error)));
  check
    (list string)
    "every declared slot is checked before preserving the terminal"
    [ Fixture.cli_primary_runtime; Fixture.cli_secondary_runtime ]
    !attempts
;;

let test_domain_invalid_cli_answer_advances_to_valid_selection () =
  with_eio @@ fun ~sw:_ ~net ~clock ~base_path ->
  Fixture.with_official_client_runtimes @@ fun () ->
  publish_unreachable_lane
    ~cli_slot_ids:[ Fixture.cli_primary_runtime; Fixture.cli_secondary_runtime ]
    ~source:"librarian cli domain failover" ();
  let attempts = ref [] in
  let runner ~runtime:{Runtime_instance.id=runtime_id;_} ~system_prompt:_ ~output_schema:_ ~prompt:_ =
    attempts := !attempts @ [ runtime_id ];
    if String.equal runtime_id Fixture.cli_primary_runtime then Ok "{}"
    else Ok (Yojson.Safe.to_string valid_working_context_json)
  in
  match execute ~net ~clock ~base_path ~runner with
  | Error error -> fail (Runtime.For_testing.classified_error_detail error)
  | Ok ((_pockets, output), slot) ->
    check (list string) "domain rejection advances once"
      [ Fixture.cli_primary_runtime; Fixture.cli_secondary_runtime ] !attempts;
    check served_slot "accepted slot owns working contexts"
      (Runtime.Cli_slot Fixture.cli_secondary_runtime) slot;
    check bool "accepted domain output is preserved" true
      (Yojson.Safe.equal output valid_working_context_json)
;;

let test_projection_refusal_tries_cli_slots () =
  with_eio @@ fun ~sw:_ ~net ~clock ~base_path ->
  Fixture.with_official_client_runtimes @@ fun () ->
  publish_unreachable_lane ~projection_refused:true
    ~cli_slot_ids:[ Fixture.cli_primary_runtime; Fixture.cli_secondary_runtime ]
    ~source:"librarian projection refusal" ();
  let attempts = ref [] in
  let runner ~runtime:{Runtime_instance.id=runtime_id;_} ~system_prompt:_ ~output_schema:_ ~prompt:_ =
    attempts := !attempts @ [ runtime_id ];
    if String.equal runtime_id Fixture.cli_primary_runtime then Ok "{}"
    else Ok (Yojson.Safe.to_string valid_working_context_json)
  in
  match execute ~net ~clock ~base_path ~runner with
  | Error error -> fail (Runtime.For_testing.classified_error_detail error)
  | Ok ((pockets, output), slot) ->
    check (list string) "projection refusal still walks declared CLI slots"
      [ Fixture.cli_primary_runtime; Fixture.cli_secondary_runtime ] !attempts;
    check served_slot "the valid CLI answer owns the result"
      (Runtime.Cli_slot Fixture.cli_secondary_runtime) slot;
    check int "empty working context returns zero pockets" 0 (List.length pockets);
    check bool "the accepted output remains observable" true
      (Yojson.Safe.equal output valid_working_context_json)
;;

let test_projection_refusal_survives_failed_cli_slots () =
  with_eio @@ fun ~sw:_ ~net ~clock ~base_path ->
  Fixture.with_official_client_runtimes @@ fun () ->
  publish_unreachable_lane ~projection_refused:true
    ~cli_slot_ids:[ Fixture.cli_primary_runtime ]
    ~source:"librarian projection refusal without a valid CLI answer" ();
  let attempts = ref [] in
  let runner ~runtime:{Runtime_instance.id=runtime_id;_} ~system_prompt:_ ~output_schema:_ ~prompt:_ =
    attempts := runtime_id :: !attempts;
    Ok "{}"
  in
  (match execute ~net ~clock ~base_path ~runner with
   | Ok _ -> fail "a domain-invalid CLI answer must not be accepted"
   | Error error ->
     let detail = Runtime.For_testing.classified_error_detail error in
     check_detail ~api_failure:projection_failure
       ~cli_failure:(invalid_domain_failure ()) detail;
     (match Astring.String.cut ~sep:"librarian-cli-unreachable" detail with
      | None -> fail "the rejected API slot is missing"
      | Some (_, tail) ->
        check bool "the API slot is named once" false
          (Astring.String.is_infix ~affix:"librarian-cli-unreachable" tail)));
  check (list string) "the declared CLI slot was attempted"
    [ Fixture.cli_primary_runtime ] !attempts
;;

let test_domain_failure_kind_survives_failed_cli_slot () =
  with_eio @@ fun ~sw ~net ~clock ~base_path ->
  Fixture.with_official_client_runtimes @@ fun () ->
  let server =
    Fixture.start_server
      ~sw
      ~net
      ~clock
      (Fixture.Reply (Fixture.openai_response (`Assoc [])))
  in
  ignore
    (Fixture.publish_registry
       ~cli_slot_ids:[ Fixture.cli_primary_runtime ]
       ~lane_id:"librarian_exact"
       ~slot_ids:[ "librarian-domain-invalid" ]
       (Fixture.resolver_snapshot
          ~source:"librarian domain failure kind"
          [ { Fixture.id = "librarian-domain-invalid"; base_url = server.base_url } ])
      : Runtime_exact_output_registry.t);
  let attempts = ref 0 in
  let runner ~runtime:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ =
    incr attempts;
    Error (Masc.Fusion_official_client.Setup_failure "synthetic bridge failure")
  in
  match execute ~net ~clock ~base_path ~runner with
  | Ok _ -> fail "domain-invalid API and failed CLI unexpectedly produced output"
  | Error error ->
    check int "the declared CLI slot was attempted" 1 !attempts;
    check bool
      "the journal classifier keeps the API domain failure"
      true
      (Runtime.For_testing.classified_error_kind error = Runtime.Domain_output_invalid);
    check_detail
      ~api_failure:"domain output invalid"
      ~cli_failure:
        (Cli.Execution_failed
           { runtime_id = Fixture.cli_primary_runtime
           ; cause = Masc.Fusion_official_client.Setup_failure "synthetic bridge failure"
           })
      (Runtime.For_testing.classified_error_detail error)
;;

let test_invalid_provider_response_runs_cli ?(requires_token_measurement = false) () =
  with_eio @@ fun ~sw ~net ~clock ~base_path ->
  Fixture.with_official_client_runtimes @@ fun () ->
  let server =
    Fixture.start_server ~sw ~net ~clock (Fixture.Reply "not-provider-json")
  in
  ignore
    (Fixture.publish_registry
       ~cli_slot_ids:[ Fixture.cli_primary_runtime ]
       ~lane_id:"librarian_exact"
       ~slot_ids:[ "librarian-invalid-provider-response" ]
       (Fixture.resolver_snapshot
          ~requires_token_measurement
          ~source:"librarian invalid provider response"
          [ { Fixture.id = "librarian-invalid-provider-response"
            ; base_url = server.base_url
            } ])
      : Runtime_exact_output_registry.t);
  let cli_calls = ref 0 in
  let runner ~runtime:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ =
    incr cli_calls;
    Ok (Yojson.Safe.to_string valid_working_context_json)
  in
  let result = execute ~net ~clock ~base_path ~runner in
  check int "provider response came from one HTTP request" 1 (Fixture.post_count server);
  if requires_token_measurement then
    check (list string) "only token measurement reached HTTP; generation did not start"
      [ "/v1/messages/count_tokens" ] (Fixture.request_paths server);
  check int "the CLI slot runs once" 1 !cli_calls;
  match result with
  | Error error ->
    failf
      "the cli slot must answer: %s"
      (Runtime.For_testing.classified_error_detail error)
  | Ok ((_pockets, output), selected_slot) ->
    check served_slot
      "the answering slot is the cli runtime id"
      (Runtime.Cli_slot Fixture.cli_primary_runtime)
      selected_slot;
    check bool
      "the accepted output is the cli answer"
      true
      (Yojson.Safe.equal output valid_working_context_json)
;;

let test_a_walk_that_sent_before_it_failed_reports_the_send () =
  with_eio @@ fun ~sw ~net ~clock ~base_path ->
  Fixture.with_official_client_runtimes @@ fun () ->
  let refusing =
    Fixture.start_server ~sw ~net ~clock
      (Fixture.Reply_with (fun _ _ -> `Internal_server_error, "{}"))
  in
  ignore
    (Fixture.publish_registry
       ~lane_id:"librarian_exact"
       ~slot_ids:[ "librarian-sent-then-refused"; "librarian-never-connected" ]
       (Fixture.resolver_snapshot
          ~source:"librarian walk sent before it failed"
          [ { Fixture.id = "librarian-sent-then-refused"; base_url = refusing.base_url }
          ; { Fixture.id = "librarian-never-connected"; base_url = "http://127.0.0.1:1" }
          ])
      : Runtime_exact_output_registry.t);
  let runner ~runtime:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ =
    fail "no CLI slot is declared, so none may run"
  in
  let result = execute ~net ~clock ~base_path ~runner in
  check int "the first slot's request reached its server" 1 (Fixture.post_count refusing);
  match result with
  | Ok _ -> fail "a walk whose slots all failed must not succeed"
  | Error error ->
    let detail = Runtime.For_testing.classified_error_detail error in
    check bool ("the walk's send is reported: " ^ detail) true
      (Astring.String.is_infix ~affix:"outward_effect=started" detail)
;;

let test_cli_prompt_drift_is_not_reported_as_no_cli_declaration () =
  with_eio
  @@ fun ~sw:_ ~net ~clock ~base_path ->
  Fixture.with_official_client_runtimes
  @@ fun () ->
  publish_unreachable_lane
    ~cli_only:true
    ~cli_slot_ids:[ Fixture.cli_primary_runtime ]
    ~source:"librarian cli prompt drift"
    ();
  let calls = ref 0 in
  let runner ~runtime:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ =
    incr calls;
    Error (Masc.Fusion_official_client.Setup_failure "must not run")
  in
  match
    Runtime.For_testing.execute_working_context_classified
      ~cli_runner:runner
      ~clock
      ~net
      ~base_path
      ~keeper_id:"librarian-cli-test"
      ~selected_input:(input ())
      ~messages:[]
      ()
  with
  | Ok _ -> fail "a missing fitted prompt must not produce working contexts"
  | Error error ->
    check int "prompt drift does not call the CLI runner" 0 !calls;
    check bool
      "prompt drift keeps its own terminal reason"
      true
      (Astring.String.is_infix
         ~affix:"fallback skipped: fitted prompt is not one text message"
         (Runtime.For_testing.classified_error_detail error))
;;

let test_complete_domain_rejection_reaches_http_successor () =
  with_eio @@ fun ~sw ~net ~clock ~base_path ->
  Fixture.with_official_client_runtimes @@ fun () ->
  let first = Fixture.start_server ~sw ~net ~clock
    (Fixture.Reply (Fixture.openai_response (`Assoc []))) in
  let second = Fixture.start_server ~sw ~net ~clock
    (Fixture.Reply (Fixture.openai_response valid_working_context_json)) in
  ignore (Fixture.publish_registry
    ~cli_slot_ids:[ Fixture.cli_primary_runtime ] ~lane_id:"librarian_exact"
    ~slot_ids:[ "librarian-domain-rejection"; "librarian-http-successor" ]
    (Fixture.resolver_snapshot ~source:"librarian HTTP successor control"
       ~body_timeouts:[ "librarian-domain-rejection", 1.0 ]
       [ { Fixture.id = "librarian-domain-rejection"; base_url = first.base_url }
       ; { Fixture.id = "librarian-http-successor"; base_url = second.base_url } ])
    : Runtime_exact_output_registry.t);
  let cli_calls = ref 0 in
  let runner ~runtime:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ =
    incr cli_calls;
    Ok (Yojson.Safe.to_string valid_working_context_json)
  in
  let result = execute ~net ~clock ~base_path ~runner in
  check int "control API1 returned a complete invalid domain answer" 1
    (Fixture.post_count first);
  check int "control API2 actually received the successor request" 1
    (Fixture.post_count second);
  check int "control accepted HTTP output before CLI" 0 !cli_calls;
  match result with
  | Ok ((_pockets, output), slot) ->
    check served_slot "control selected the second HTTP candidate"
      (Runtime.Api_slot "librarian-http-successor") slot;
    check bool "control HTTP answer passed the Librarian domain validator"
      true (Yojson.Safe.equal output valid_working_context_json)
  | Error error -> fail (Runtime.For_testing.classified_error_detail error)
;;

let test_incomplete_reply_exposes_typed_body_deadline () =
  with_eio @@ fun ~sw ~net ~clock ~base_path:_ ->
  let first = Fixture.start_server ~sw ~net ~clock
    (Fixture.Incomplete_reply {|{"choices":[|}) in
  let module Http = Agent_core.Llm_provider.Http_client in
  let result = Http.post_sync_once_with_evidence ~net ~clock
    ~connect_timeout_s:Fixture.fixture_post_connect_timeout_seconds
    ~body_timeout_s:1.0
    ~url:(first.base_url ^ "/v1/chat/completions")
    ~headers:[ "content-type", "application/json" ] ~body:"{}" () in
  check int "typed transport control sent one POST" 1 (Fixture.post_count first);
  match result with
  | Error (Http.Response_received_error
             { status = 200; error = Http.TimeoutError { phase = Http.Wall_clock; _ } }) -> ()
  | Ok _ | Error _ -> fail "expected HTTP200 headers followed by typed total body deadline"
;;

let () =
  run
    "keeper_librarian_cli_lane"
    [ ( "cli lane slots"
      , [ test_case "a CLI execution failure names its slot once" `Quick
            test_execution_failure_names_cli_slot_once
        ; test_case "CLI-only librarian organizes working contexts without an HTTP attempt" `Quick
            (fun () -> test_cli_slot_answers_after_catalog_exhaustion ~cli_only:true ())
        ; test_case "complete domain rejection reaches the same HTTP successor" `Quick
            test_complete_domain_rejection_reaches_http_successor
        ; test_case "incomplete HTTP reply exposes a typed body deadline" `Quick
            test_incomplete_reply_exposes_typed_body_deadline
        ; test_case "API projection refusal advances through CLI slots" `Quick
            test_projection_refusal_tries_cli_slots
        ; test_case "failed CLI slots preserve the API projection failure" `Quick
            test_projection_refusal_survives_failed_cli_slots
        ; test_case "domain-invalid CLI output advances to a valid selection" `Quick
            test_domain_invalid_cli_answer_advances_to_valid_selection
        ; test_case "a cli slot answers after catalog exhaustion" `Quick
            (fun () -> test_cli_slot_answers_after_catalog_exhaustion ())
        ; test_case "a domain-invalid cli answer keeps the terminal" `Quick
            test_domain_invalid_cli_answer_keeps_the_terminal
        ; test_case "API domain failure kind survives failed CLI fallback" `Quick
            test_domain_failure_kind_survives_failed_cli_slot
        ; test_case "an invalid provider response runs the CLI slot" `Quick
            (fun () -> test_invalid_provider_response_runs_cli ())
        ; test_case "a walk that sent before it failed reports the send" `Quick
            test_a_walk_that_sent_before_it_failed_reports_the_send
        ; test_case "a dispatched measurement failure runs the CLI slot" `Quick
            (fun () -> test_invalid_provider_response_runs_cli ~requires_token_measurement:true ())
        ; test_case "CLI prompt drift remains distinct from no CLI declaration" `Quick
            test_cli_prompt_drift_is_not_reported_as_no_cli_declaration
        ] )
    ]
;;
