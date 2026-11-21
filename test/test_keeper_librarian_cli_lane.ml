open Alcotest

(* CLI lane-slot fallback for librarian_exact:
   the classified exact-output pass walks the declared cli slots only after
   the catalog reports provider exhaustion, applies the same selection
   contract to each cli answer, and advances after a domain-invalid
   one. The runtime table is the fusion panel fixture (command /usr/bin/true)
   so [is_official_client] admits the cli ids without spawning a client. *)

module Librarian = Masc.Keeper_librarian
module Runtime = Masc.Keeper_librarian_runtime
module Memory = Masc.Keeper_memory_os_types
module Current = Masc.Keeper_memory_os_current
module Cli = Masc.Keeper_lane_cli_oneshot
module Exact_lane_run_registry = Masc.Exact_lane_run_registry
module Fixture = Exact_output_fixture

let served_slot =
  testable
    (fun fmt -> function
       | Runtime.Api_slot id -> Format.fprintf fmt "Api_slot %s" id
       | Runtime.Cli_slot id -> Format.fprintf fmt "Cli_slot %s" id)
    ( = )
module Ids = Ids

let () = Masc.Prompt_defaults.init ()
;;

let fact ~claim : Memory.fact =
  Memory.observed ~claim ~category:Memory.Fact ~now:1_000_000.
    ~origin:{ kind = Memory.Authored; trace_id = "" }
;;

let current_a = fact ~claim:"keep A"
let current_b = fact ~claim:"drop B"

let input () : Librarian.input =
  { turn_ref = Ids.Turn_ref.make ~trace_id:"trace-cli-lane" ~absolute_turn:7
  ; historical_task_contexts = []; goal_context = Masc.Keeper_librarian.No_task
  ; keeper_id = Masc_test_deps.keeper_id_fixture "cli-lane-keeper"
  ; keeper_instructions = "You are the cli-lane keeper."
  ; current = Some { Librarian.facts = [ current_a; current_b ] }
  ; messages =
      [ Agent_core.Types.make_message
          ~role:Agent_core.Types.User
          [ Agent_core.Types.Text "new conversation" ]
      ]
  ; tool_observations = []
  ; working_context = Masc.Keeper_librarian_context.empty
  ; counterpart_observations = []
  }
;;

(* Surrogate identities: m1 = current_a (retained), m2 = current_b (dropped)
   — the parser accepts an answer that names only what changes. *)
let valid_selection_json =
  `Assoc
    [ "working_contexts", `List []
    ; Librarian.wire_field_new_claims, `List []
    ; ( Librarian.wire_field_dropped
      , `List
          [ `Assoc
              [ Librarian.wire_field_memory_id, `String "m2"
              ; Librarian.wire_field_reason, `String "superseded by newer state"
              ]
          ] )
    ]
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
  match Runtime.messages_for_librarian ~source_lines:[] selected_input with
  | Error detail -> failf "librarian render failed: %s" detail
  | Ok messages ->
    Runtime.For_testing.execute_exact_output_classified ~continuity:None
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
  match Librarian.selection_of_json_result (input ()) (`Assoc []) with
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
    Ok (Yojson.Safe.to_string valid_selection_json)
  in
  match execute ~net ~clock ~base_path ~runner with
  | Error error ->
    failf
      "the cli slot must answer: %s"
      (Runtime.For_testing.classified_error_detail error)
  | Ok ((_selection, output), selected_slot) ->
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
      (Yojson.Safe.equal output valid_selection_json)
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
    Ok "{}" (* valid JSON, invalid selection domain *)
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
    attempts := !attempts @ [runtime_id];
    if String.equal runtime_id Fixture.cli_primary_runtime then Ok "{}"
    else Ok (Yojson.Safe.to_string valid_selection_json)
  in
  match execute ~net ~clock ~base_path ~runner with
  | Error error -> fail (Runtime.For_testing.classified_error_detail error)
  | Ok ((_selection, output), slot) ->
    check (list string) "domain rejection advances once"
      [Fixture.cli_primary_runtime; Fixture.cli_secondary_runtime] !attempts;
    check served_slot "accepted slot owns selection"
      (Runtime.Cli_slot Fixture.cli_secondary_runtime) slot;
    check bool "accepted domain output is preserved" true
      (Yojson.Safe.equal output valid_selection_json)
;;

let test_projection_refusal_tries_cli_slots () =
  with_eio @@ fun ~sw:_ ~net ~clock ~base_path ->
  Fixture.with_official_client_runtimes @@ fun () ->
  (* The catalog admits the target, but its model has no thinking capability.
     Enabling thinking makes request projection refuse it before any HTTP. *)
  publish_unreachable_lane ~projection_refused:true
    ~cli_slot_ids:[ Fixture.cli_primary_runtime; Fixture.cli_secondary_runtime ]
    ~source:"librarian projection refusal" ();
  let attempts = ref [] in
  let runner ~runtime:{Runtime_instance.id=runtime_id;_} ~system_prompt:_ ~output_schema:_ ~prompt:_ =
    attempts := !attempts @ [runtime_id];
    if String.equal runtime_id Fixture.cli_primary_runtime then Ok "{}"
    else Ok (Yojson.Safe.to_string valid_selection_json)
  in
  match execute ~net ~clock ~base_path ~runner with
  | Error error -> fail (Runtime.For_testing.classified_error_detail error)
  | Ok (({ Runtime.selection; _ }, output), slot) ->
    check (list string) "projection refusal still walks declared CLI slots"
      [Fixture.cli_primary_runtime; Fixture.cli_secondary_runtime] !attempts;
    check served_slot "the valid CLI answer owns the result"
      (Runtime.Cli_slot Fixture.cli_secondary_runtime) slot;
    check (list string) "the CLI answer changes memory through the same domain contract"
      [current_a.claim] (List.map (fun (fact : Memory.fact) -> fact.claim) selection.facts);
    check bool "the accepted output remains observable" true
      (Yojson.Safe.equal output valid_selection_json)
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
    [Fixture.cli_primary_runtime] !attempts
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
  | Ok _ -> fail "domain-invalid API and failed CLI unexpectedly produced a selection"
  | Error error ->
    check int "the declared CLI slot was attempted" 1 !attempts;
    check bool
      "the journal classifier keeps the API domain failure"
      true
      (Runtime.For_testing.classified_error_kind error = Current.Domain_output_invalid);
    check_detail
      ~api_failure:"domain output invalid"
      ~cli_failure:
        (Cli.Execution_failed
           { runtime_id = Fixture.cli_primary_runtime
           ; cause = Masc.Fusion_official_client.Setup_failure "synthetic bridge failure"
           })
      (Runtime.For_testing.classified_error_detail error)
;;

(* An unreadable provider body, or a count-tokens request that went out and
   failed, is the provider's failure, not masc's, so the pass walks on to the
   declared CLI slot (RFC-exact-lane-walks-one-slot-list Q1). *)
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
    Ok (Yojson.Safe.to_string valid_selection_json)
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
  | Ok ((_selection, output), selected_slot) ->
    check served_slot
      "the answering slot is the cli runtime id"
      (Runtime.Cli_slot Fixture.cli_primary_runtime)
      selected_slot;
    check bool
      "the accepted output is the cli answer"
      true
      (Yojson.Safe.equal output valid_selection_json)
;;

(* The first slot sends its request and is refused with a 5xx, which advances
   the walk; the second cannot connect, so the walk ends on a slot that sent
   nothing. The walk still sent a request, and the failure line says so: it
   read the slot that ended the walk only and wrote "none" (#38450). *)
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
    Runtime.For_testing.execute_exact_output_classified ~continuity:None
      ~cli_runner:runner
      ~clock
      ~net
      ~base_path
      ~keeper_id:"librarian-cli-test"
      ~selected_input:(input ())
      ~messages:[]
      ()
  with
  | Ok _ -> fail "a missing fitted prompt must not produce a selection"
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
    (Fixture.Reply (Fixture.openai_response valid_selection_json)) in
  ignore (Fixture.publish_registry
    ~cli_slot_ids:[Fixture.cli_primary_runtime] ~lane_id:"librarian_exact"
    ~slot_ids:["librarian-domain-rejection"; "librarian-http-successor"]
    (Fixture.resolver_snapshot ~source:"librarian HTTP successor control"
       ~body_timeouts:["librarian-domain-rejection", 1.0]
       [{ Fixture.id = "librarian-domain-rejection"; base_url = first.base_url };
        { Fixture.id = "librarian-http-successor"; base_url = second.base_url }])
    : Runtime_exact_output_registry.t);
  let cli_calls = ref 0 in
  let runner ~runtime:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ =
    incr cli_calls;
    Ok (Yojson.Safe.to_string valid_selection_json)
  in
  let result = execute ~net ~clock ~base_path ~runner in
  check int "control API1 returned a complete invalid domain answer" 1
    (Fixture.post_count first);
  check int "control API2 actually received the successor request" 1
    (Fixture.post_count second);
  check int "control accepted HTTP output before CLI" 0 !cli_calls;
  match result with
  | Ok ((_selection, output), slot) ->
    check served_slot "control selected the second HTTP candidate"
      (Runtime.Api_slot "librarian-http-successor") slot;
    check bool "control HTTP answer passed the Librarian domain validator"
      true (Yojson.Safe.equal output valid_selection_json);
    Printf.printf "HTTP_SUCCESSOR_CONTROL api1=1 api2=1 cli=0 selected=%s\n%!"
      (Runtime.served_slot_id slot)
  | Error error -> fail (Runtime.For_testing.classified_error_detail error)
;;

(* Separate transport control before Exact projects the named deadline cause.
   The Memory journal does not persist the typed HTTP status/timeout fields. *)
let test_incomplete_reply_exposes_typed_body_deadline () =
  with_eio @@ fun ~sw ~net ~clock ~base_path ->
  let first = Fixture.start_server ~sw ~net ~clock
    (Fixture.Incomplete_reply {|{"choices":[|}) in
  let module Http = Agent_core.Llm_provider.Http_client in
  let result = Http.post_sync_once_with_evidence ~net ~clock
    ~connect_timeout_s:Fixture.fixture_post_connect_timeout_seconds
    ~body_timeout_s:1.0
    ~url:(first.base_url ^ "/v1/chat/completions")
    ~headers:["content-type", "application/json"] ~body:"{}" () in
  check int "typed transport control sent one POST" 1 (Fixture.post_count first);
  match result with
  | Error (Http.Response_received_error
             { status = 200; error = Http.TimeoutError { phase = Http.Wall_clock; _ } }) ->
    Printf.printf "BODY_DEADLINE_CONTROL phase=response_received http_status=200 timeout_phase=wall_clock posts=1\n%!"
  | Ok _ | Error _ -> fail "expected HTTP200 headers followed by typed total body deadline"
;;

type native_capacity_source = Native_codex | Native_claude

let test_native_capacity_message_descent native () =
  with_eio @@ fun ~sw:_ ~net:_ ~clock:_ ~base_path ->
  Fixture.with_official_client_runtimes @@ fun () ->
  Masc_test_deps.with_typesafeai_policy
    {Runtime_schema.default_typesafeai with lane_enabled=false;absorb_gate=false} @@ fun () ->
  Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
  let capacity_answer = Error (match native with
    | Native_codex -> Masc.Fusion_official_client.Codex_failure
        (Runtime_codex_app_server.Context_window_exceeded
          {message="fixture native input refusal";tool_effect_attempted=false})
    | Native_claude -> Masc.Fusion_official_client.Claude_failure
        (Runtime_claude_code.Context_window_exceeded
          {message="fixture native input refusal";tool_effect_attempted=false;response_emitted=false})) in
  let keeper_id = "cli-lane-keeper" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let paths =
    [Current.path_for_keepers_dir ~keepers_dir ~keeper_id;
     Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id;
     Current.publication_receipt_path ~keepers_dir ~keeper_id;
     Current.durable_range_receipt_path ~keepers_dir ~keeper_id;
     Current.unread_ledger_path ~keepers_dir ~keeper_id;
     Masc.Keeper_librarian_context.path ~keepers_dir ~keeper_id] in
  let before = List.map Fs_compat.load_file_opt paths in
  let attempt answers expected_descent =
    publish_unreachable_lane ~cli_only:true ~cli_slot_ids:(List.map fst answers)
      ~source:"native Memory message descent fixture" ();
    let calls = ref [] in
    let runner ~runtime:{Runtime_instance.id=runtime_id;_} ~system_prompt:_ ~output_schema:_ ~prompt:_ =
      calls := runtime_id :: !calls;
      List.assoc runtime_id answers in
    (match Runtime.infer_memory_step ~cli_runner:runner ~base_path ~keepers_dir ~keeper_id
        ~previous_state:None ~unread_messages:[] (input ()) with
     | Runtime.Memory_inferred _ -> fail "a native failure became an accepted Memory decision"
     | Runtime.Memory_not_inferred failure ->
       check bool "the actual native walk retains a failure report" true (failure.reports<>[]);
       check bool "native failures never grant API-only unread-hole authority" true
         (failure.exhausted_input_refusals=None);
       check bool "actual native walk carries the closed message descent decision" true
         (List.for_all (fun (report : Runtime.not_committed) ->
           report.message_descent=expected_descent && not report.walk_shows_size) failure.reports);
       check bool "native capacity can descend only while invalid output is absent"
         (expected_descent=Runtime.Smaller_input_may_help)
         (Runtime.may_descend_messages failure.reports));
    check (list string) "every declared native slot is actually dispatched in order"
      (List.map fst answers) (List.rev !calls);
    check bool "failed native inference leaves every Memory store unchanged" true
      (before=List.map Fs_compat.load_file_opt paths) in
  attempt [Fixture.cli_primary_runtime,capacity_answer] Runtime.Smaller_input_may_help;
  List.iter (fun invalid ->
    attempt [Fixture.cli_primary_runtime,invalid;Fixture.cli_secondary_runtime,capacity_answer]
      Runtime.Invalid_output_blocks_descent;
    attempt [Fixture.cli_primary_runtime,capacity_answer;Fixture.cli_secondary_runtime,invalid]
      Runtime.Invalid_output_blocks_descent)
    [Ok "{}";Ok "not-json"]
;;

(* A Memory inference uses real parsing and gate policy but has no publication
   authority. Its captured source and typed decision remain process-local. *)
let inference_answer =
  `Assoc ["new_claims", `List [`Assoc
    ["claim", `String "A and revised B remain grounded in the original observations."
    ; "category", `String "fact"; "supersedes", `String "m2"
    ; "absorbs", `List [`String "m1"]; "evidence", `Assoc ["conversation",`List [];"tools",`List [];"counterpart",`Bool false;"task_contexts",`Bool false]]]
  ; "dropped", `List [`Assoc ["memory_id", `String "m2";
      "reason", `String "B was revised by the selected observation."]]
  ; "working_contexts", `List []; "working_state", `String "planned continuation"]

let inference_store_paths ~keepers_dir ~keeper_id =
  [ Current.path_for_keepers_dir ~keepers_dir ~keeper_id
  ; Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id
  ; Current.publication_receipt_path ~keepers_dir ~keeper_id
  ; Current.durable_range_receipt_path ~keepers_dir ~keeper_id
  ; Current.unread_ledger_path ~keepers_dir ~keeper_id
  ; Masc.Keeper_librarian_context.path ~keepers_dir ~keeper_id ]

let test_memory_inference_requires_counterpart_template () =
  with_eio @@ fun ~sw:_ ~net:_ ~clock:_ ~base_path ->
  Fixture.with_official_client_runtimes @@ fun () ->
  Masc_test_deps.with_typesafeai_policy
    {Runtime_schema.default_typesafeai with lane_enabled=false; absorb_gate=false} @@ fun () ->
  let require = function Ok value -> value | Error detail -> fail detail in
  Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
  publish_unreachable_lane ~cli_only:true ~cli_slot_ids:[Fixture.cli_primary_runtime]
    ~source:"counterpart Memory inference" ();
  let keeper_id = "cli-lane-keeper" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let counterpart : Masc.Keeper_counterpart_observation.t =
    {origin=Durable_chat;channel="direct";workspace_id=None;user_id=Some "speaker";
     user_name=Some "Speaker";authority=External;content="Original floor counterpart"} in
  let selected_input = {(input ()) with counterpart_observations=[counterpart]} in
  let paths = inference_store_paths ~keepers_dir ~keeper_id in
  let before = List.map Fs_compat.load_file_opt paths in
  let previous = (Prompt_registry.resolve_prompt Prompt_names.librarian).override_value in
  let restore () = match previous with
    | None -> Prompt_registry.clear_prompt_override Prompt_names.librarian
    | Some value -> Prompt_registry.set_override Prompt_names.librarian value |> require in
  Fun.protect ~finally:restore (fun () ->
    Prompt_registry.set_override Prompt_names.librarian "Summarize the input" |> require;
    let prompts = ref [] in
    let runner ~runtime:_ ~system_prompt:_ ~output_schema:_ ~prompt =
      prompts := prompt :: !prompts; Ok (Yojson.Safe.to_string inference_answer) in
    let infer input = Runtime.infer_memory_step ~cli_runner:runner ~base_path ~keepers_dir ~keeper_id
      ~previous_state:None ~unread_messages:[] input in
    (match infer selected_input with
     | Runtime.Memory_inferred _ -> fail "a missing counterpart substitution produced a Memory step"
     | Memory_not_inferred {reports;_} ->
       check bool "the refusal names the missing counterpart substitution" true
         (List.exists (fun (report : Runtime.not_committed) ->
           Astring.String.is_infix ~affix:"counterpart_observations" report.detail) reports));
    check int "the rejected question never reaches the provider" 0 (List.length !prompts);
    check bool "the rejected inference leaves its stores unchanged" true
      (before = List.map Fs_compat.load_file_opt paths);
    (match infer (input ()) with
     | Runtime.Memory_not_inferred _ -> fail "an empty counterpart input was refused"
     | Memory_inferred _ -> ());
    check int "an override may omit an empty counterpart" 1 (List.length !prompts);
    prompts := [];
    let state_runner ~runtime:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ =
      Ok {|{"working_state":"already-consumed context"}|} in
    (match (Runtime.infer_working_state ~cli_runner:state_runner ~base_path ~keepers_dir ~keeper_id
       ~previous_state:None ~unread_messages:[] selected_input).outcome with
     | Runtime.Inferred _ -> ()
     | Not_inferred _ -> fail "the separate context-only prompt was blocked");
    restore ();
    (match infer selected_input with
     | Runtime.Memory_not_inferred _ -> fail "the corrected counterpart question was refused"
     | Memory_inferred {step;_} ->
       check bool "the resulting step retains the original counterpart" true
         (step.source_input.counterpart_observations = [counterpart]));
    (match !prompts with
     | [prompt] -> check bool "the corrected prompt contains the original counterpart" true
         (Astring.String.is_infix ~affix:counterpart.content prompt)
     | _ -> fail "expected one corrected provider question");
    check bool "successful inference still does not publish Memory" true
      (before = List.map Fs_compat.load_file_opt paths))
;;

type inference_failure = Invalid_memory_answer | Gate_unavailable | Opaque_cli_failure | Cancelled_inference

let test_memory_inference_failure_keeps_pending_publication failure () =
  with_eio @@ fun ~sw:_ ~net:_ ~clock:_ ~base_path ->
  Fixture.with_official_client_runtimes @@ fun () ->
  Masc_test_deps.with_typesafeai_policy
    {Runtime_schema.default_typesafeai with lane_enabled=false;
      absorb_gate=(match failure with Gate_unavailable -> true
        | Invalid_memory_answer | Opaque_cli_failure | Cancelled_inference -> false)} @@ fun () ->
  Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
  publish_unreachable_lane ~cli_only:true ~cli_slot_ids:[Fixture.cli_primary_runtime]
    ~source:"pending-publication inference" ();
  let keeper_id = "cli-lane-keeper" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let write_snapshot path content =
    Fs_compat.Atomic_replace_for_testing.save_file_atomic_strict_staged
      ~sync_file:(fun _ -> ()) ~sync_parent:(fun _ -> failwith "after rename") path content in
  (match Current.For_testing.replace_with_publication_io
    ~write_snapshot ~sync_snapshot:(fun _ -> Error "durability unconfirmed")
    ~on_committed:(fun _ _ -> ()) ~before_journal:(fun () -> ())
    ~keepers_dir ~keeper_id ~now:(Time_compat.now ()) ~source:{Current.kind=Current.Explicit_write;trace_id="pending"}
    ~facts:[current_a;current_b] with
   | Error _ -> () | Ok _ -> fail "expected real staged publication failure");
  check bool "real recoverable publication is pending" true
    (Sys.file_exists (Current.publication_receipt_path ~keepers_dir ~keeper_id));
  let paths = inference_store_paths ~keepers_dir ~keeper_id in
  let before = List.map Fs_compat.load_file_opt paths in
  let wakes = ref 0 in
  let module Registry = Masc.Exact_lane_run_registry in
  let registry = Registry.global () in
  let prior_runs = List.map (fun (run : Registry.run) -> run.run_id) (Registry.list_runs registry) in
  let unsubscribe = Masc.Keeper_memory_commit_notifications.subscribe (fun _ -> incr wakes) in
  Fun.protect ~finally:unsubscribe @@ fun () ->
  let runner ~runtime:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ = match failure with
    | Invalid_memory_answer -> Ok {|{"working_state":"not a Memory decision"}|}
    | Gate_unavailable -> Ok (Yojson.Safe.to_string inference_answer)
    | Opaque_cli_failure -> Error (Masc.Fusion_official_client.Setup_failure "opaque inference failure")
    | Cancelled_inference -> raise (Eio.Cancel.Cancelled (Failure "cancel inference")) in
  (match Runtime.infer_memory_step ~cli_runner:runner ~base_path ~keepers_dir ~keeper_id
      ~previous_state:None ~unread_messages:[] (input ()) with
   | Runtime.Memory_inferred _ -> fail "a failed inference was accepted"
   | Runtime.Memory_not_inferred {reports;exhausted_input_refusals} ->
     check bool "classified failure remains observable" true (reports<>[]);
     check bool "a failed CLI inference grants no API exhaustion evidence" true
       (exhausted_input_refusals=None);
     (match failure with
      | Opaque_cli_failure -> check bool "opaque CLI grants no typed skip authority" true
          (List.for_all (fun (r : Runtime.not_committed) -> r.provider_input_refusals=[]) reports)
      | Invalid_memory_answer | Gate_unavailable -> ()
      | Cancelled_inference -> fail "cancellation was swallowed")
   | exception Eio.Cancel.Cancelled _ ->
     (match failure with Cancelled_inference -> ()
      | Invalid_memory_answer | Gate_unavailable | Opaque_cli_failure -> fail "unexpected cancellation"));
  check bool "failure leaves pending publication and all Memory bytes untouched" true
    (before = List.map Fs_compat.load_file_opt paths);
  check int "failure sends no Memory commit notification" 0 !wakes;
  let run = match Registry.list_runs registry
      |> List.filter (fun (run : Registry.run) -> not (List.mem run.run_id prior_runs)) with
    | [run] -> (match Registry.get registry ~run_id:run.run_id with
        | Some loaded -> loaded | None -> fail "failure run payload missing")
    | _ -> fail "expected one failed inference run" in
  let decoded = Masc.Tui_decode.decode_lane_run_detail
      (Fixture.lane_run_detail run) in
  let reading = match decoded with
    | Ok {lrd_librarian_preflight=Some reading;_} -> reading
    | Ok {lrd_librarian_preflight=None;_} -> fail "failed inference scope missing"
    | Error detail -> fail detail in
  check bool "failure and cancellation retain the inference scope" true
    (reading.lp_memory_scope = Masc.Tui_decode.Memory_inference_scope
      && reading.lp_memory_result=None)
;;

type memory_exhaustion_case =
  | Named_api_only
  | Named_and_unknown_api
  | Unknown_api_only
  | Domain_then_named_api
  | Invalid_json_then_named_api
  | Named_api_and_cli_tail
  | Local_projection_then_named_api
  | Local_connection_then_named_api

let test_memory_inference_exhaustion case () =
  with_eio @@ fun ~sw ~net ~clock ~base_path ->
  Fixture.with_official_client_runtimes @@ fun () ->
  Masc_test_deps.with_typesafeai_policy
    {Runtime_schema.default_typesafeai with lane_enabled=false; absorb_gate=false} @@ fun () ->
  Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
  let refuse status = Fixture.Reply_with (fun _ _ -> status,
    {|{"error":{"message":"fixture refusal","type":"invalid_request_error"}}|}) in
  let named = Fixture.start_server ~sw ~net ~clock (refuse `Request_entity_too_large) in
  let other_behavior = match case with
    | Domain_then_named_api -> Fixture.Reply (Fixture.openai_response (`Assoc []))
    | Invalid_json_then_named_api -> Fixture.Reply
        {|{"choices":[{"index":0,"message":{"role":"assistant","content":"not JSON"},"finish_reason":"stop"}]}|}
    | Named_api_only | Named_and_unknown_api | Unknown_api_only
    | Named_api_and_cli_tail | Local_projection_then_named_api
    | Local_connection_then_named_api -> refuse `Internal_server_error in
  let other = Fixture.start_server ~sw ~net ~clock other_behavior in
  let named_id = "memory-floor-named" and other_id = "memory-floor-other" in
  let slots, other_url, excluded, cli_slots, expected, named_posts, other_posts = match case with
    | Named_api_only -> [named_id], other.base_url, [], [], true, 1, 0
    | Named_and_unknown_api -> [named_id;other_id], other.base_url, [], [], true, 1, 1
    | Unknown_api_only -> [other_id], other.base_url, [], [], false, 0, 1
    | Domain_then_named_api | Invalid_json_then_named_api ->
      [other_id;named_id], other.base_url, [], [], false, 1, 1
    | Named_api_and_cli_tail ->
      [named_id], other.base_url, [], [Fixture.cli_primary_runtime], false, 1, 0
    | Local_projection_then_named_api ->
      [other_id;named_id], other.base_url, [other_id,true], [], false, 1, 0
    | Local_connection_then_named_api ->
      [other_id;named_id], "http://127.0.0.1:1", [], [], false, 1, 0 in
  ignore (Fixture.publish_registry ~cli_slot_ids:cli_slots
    ~lane_id:"librarian_exact" ~slot_ids:slots
    (Fixture.resolver_snapshot ~source:"Memory inference exhaustion evidence"
      ~enable_thinkings:excluded
      [{Fixture.id=named_id;base_url=named.base_url};
       {Fixture.id=other_id;base_url=other_url}]) : Runtime_exact_output_registry.t);
  let cli_calls = ref 0 in
  let runner ~runtime:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ =
    incr cli_calls;
    Error (Masc.Fusion_official_client.Setup_failure "opaque CLI tail") in
  let keeper_id = "memory-floor-evidence" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let paths = inference_store_paths ~keepers_dir ~keeper_id in
  let before = List.map Fs_compat.load_file_opt paths in
  (match Runtime.infer_memory_step ~cli_runner:runner ~base_path ~keepers_dir ~keeper_id
      ~previous_state:None ~unread_messages:[] (input ()) with
   | Memory_inferred _ -> fail "the failed provider walk was accepted as Memory"
   | Memory_not_inferred failure ->
     check bool "actual failure reports remain available" true (failure.reports<>[]);
     check bool "only a completely exhausted API walk grants floor evidence"
       expected (Option.is_some failure.exhausted_input_refusals);
     (match failure.exhausted_input_refusals with
      | None -> ()
      | Some refusals -> check bool "the exact named provider cause is preserved" true
          (refusals=[Masc.Keeper_librarian_input_refusal.Request_body_refused]));
     (match case with
      | Named_api_and_cli_tail ->
        check bool "CLI tail vetoes authority despite the earlier typed provider refusal" true
          (List.exists (fun (report : Runtime.not_committed) ->
            report.provider_input_refusals<>[]) failure.reports)
      | Named_api_only | Named_and_unknown_api | Unknown_api_only
      | Domain_then_named_api | Invalid_json_then_named_api
      | Local_projection_then_named_api | Local_connection_then_named_api -> ()));
  check int "the named provider received exactly its expected visit" named_posts (Fixture.post_count named);
  check int "the other actual HTTP provider received exactly its expected visit" other_posts (Fixture.post_count other);
  check int "only a declared CLI tail was invoked" (List.length cli_slots) !cli_calls;
  check bool "failed inference never writes Memory, its proof or continuation" true
    (before=List.map Fs_compat.load_file_opt paths)
;;

let () =
  run
    "keeper_librarian_cli_lane"
    [ ( "cli lane slots"
      , [ test_case "named API exhaustion grants Memory floor evidence" `Quick
            (test_memory_inference_exhaustion Named_api_only)
        ; test_case "exhausted named and unknown API failures retain floor evidence" `Quick
            (test_memory_inference_exhaustion Named_and_unknown_api)
        ; test_case "unknown-only API exhaustion grants no Memory floor evidence" `Quick
            (test_memory_inference_exhaustion Unknown_api_only)
        ; test_case "domain rejection vetoes a later named API refusal" `Quick
            (test_memory_inference_exhaustion Domain_then_named_api)
        ; test_case "invalid JSON vetoes a later named API refusal" `Quick
            (test_memory_inference_exhaustion Invalid_json_then_named_api)
        ; test_case "opaque CLI tail vetoes earlier named API refusal" `Quick
            (test_memory_inference_exhaustion Named_api_and_cli_tail)
        ; test_case "local projection rejection vetoes later named API refusal" `Quick
            (test_memory_inference_exhaustion Local_projection_then_named_api)
        ; test_case "local connection failure vetoes later named API refusal" `Quick
            (test_memory_inference_exhaustion Local_connection_then_named_api)
        ; test_case "Memory inference refuses a missing counterpart substitution" `Quick
            test_memory_inference_requires_counterpart_template
        ; test_case "invalid Memory inference preserves pending publication" `Quick
            (test_memory_inference_failure_keeps_pending_publication Invalid_memory_answer)
        ; test_case "unavailable inference gate preserves pending publication" `Quick
            (test_memory_inference_failure_keeps_pending_publication Gate_unavailable)
        ; test_case "opaque CLI inference preserves pending publication" `Quick
            (test_memory_inference_failure_keeps_pending_publication Opaque_cli_failure)
        ; test_case "cancelled inference preserves pending publication" `Quick
            (test_memory_inference_failure_keeps_pending_publication Cancelled_inference)
        ; test_case "a CLI execution failure names its slot once" `Quick
            test_execution_failure_names_cli_slot_once
        ; test_case "CLI-only librarian selects memory without an HTTP attempt" `Quick
          (fun () -> test_cli_slot_answers_after_catalog_exhaustion ~cli_only:true ())
      ; test_case "complete domain rejection reaches the same HTTP successor" `Quick
          test_complete_domain_rejection_reaches_http_successor
      ; test_case "incomplete HTTP reply exposes a typed body deadline" `Quick
          test_incomplete_reply_exposes_typed_body_deadline
      ; test_case
            "API projection refusal advances through CLI slots"
            `Quick test_projection_refusal_tries_cli_slots
        ; test_case
            "failed CLI slots preserve the API projection failure"
            `Quick test_projection_refusal_survives_failed_cli_slots
        ; test_case
            "domain-invalid CLI output advances to a valid selection"
            `Quick test_domain_invalid_cli_answer_advances_to_valid_selection
        ; test_case
            "a cli slot answers after catalog exhaustion"
            `Quick
            (fun () -> test_cli_slot_answers_after_catalog_exhaustion ())
        ; test_case
            "a domain-invalid cli answer keeps the terminal"
            `Quick
            test_domain_invalid_cli_answer_keeps_the_terminal
        ; test_case "API domain failure kind survives failed CLI fallback" `Quick
            test_domain_failure_kind_survives_failed_cli_slot
        ; test_case "an invalid provider response runs the CLI slot" `Quick
            (fun () -> test_invalid_provider_response_runs_cli ())
        ; test_case "a walk that sent before it failed reports the send" `Quick
            test_a_walk_that_sent_before_it_failed_reports_the_send
        ; test_case "a dispatched measurement failure runs the CLI slot" `Quick
            (fun () ->
              test_invalid_provider_response_runs_cli
                ~requires_token_measurement:true ())
        ; test_case "native Codex capacity permits message descent without unread authority" `Quick
            (test_native_capacity_message_descent Native_codex)
        ; test_case "native Claude capacity permits message descent without unread authority" `Quick
            (test_native_capacity_message_descent Native_claude)
        ; test_case
            "CLI prompt drift remains distinct from no CLI declaration"
            `Quick
            test_cli_prompt_drift_is_not_reported_as_no_cli_declaration
        ] )
    ]
;;
