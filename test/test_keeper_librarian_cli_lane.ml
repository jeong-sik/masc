open Alcotest

(* CLI lane-slot fallback for librarian_exact (RFC cli-runtimes-as-lane-slots):
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

let unchanged_memory_json =
  `Assoc ["new_claims", `List []; "dropped", `List []; "working_contexts", `List []]
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
  match Runtime.messages_for_librarian selected_input with
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

let test_failure_reaches_journal
      ~cli_only
      ~cli_slot_ids
      ~answer
      ~failure
      ~kind
      ~calls
      ()
  =
  with_eio @@ fun ~sw:_ ~net:_ ~clock:_ ~base_path ->
  Fixture.with_official_client_runtimes @@ fun () ->
  publish_unreachable_lane ~cli_only ~projection_refused:true ~cli_slot_ids
    ~source:"librarian failure journal" ();
  let keeper_id = Filename.basename base_path in
  let keepers_dir = Filename.concat base_path "keepers" in
  Unix.mkdir keepers_dir 0o700;
  let attempts = ref 0 in
  let runner ~runtime:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ =
    incr attempts;
    answer
  in
  Runtime.run_best_effort ~cli_runner:runner
    ~base_path ~keepers_dir ~keeper_id ~expected_revision:None (input ());
  check int "only admitted CLI slots reach the runner" calls !attempts;
  let api_failure = if cli_only then None else Some projection_failure in
  (match Current.read_journal_tail ~keepers_dir ~keeper_id ~limit:1 with
   | [Ok (Current.Journal_failed { detail; kind = actual_kind; _ })] ->
     check_detail ?api_failure ?cli_failure:failure detail;
     check bool "journal keeps the original failure kind" true (actual_kind = kind)
   | _ -> fail "failed pass must write one decodable journal failure");
  let runs = Exact_lane_run_registry.list_runs (Exact_lane_run_registry.global ())
    |> List.filter (fun (run : Exact_lane_run_registry.run) ->
      String.equal run.actor keeper_id) in
  (match runs with
   | [{ status = Exact_lane_run_registry.Completed
          { outcome = Exact_lane_run_registry.Failed { detail; _ }; _ }; _ }] ->
     check_detail ?api_failure ?cli_failure:failure detail
   | _ -> fail "exact-run projection must retain the same failed pass");
  match Current.read_for_keepers_dir ~keepers_dir ~keeper_id with
  | Ok None -> ()
  | Ok (Some _) | Error _ -> fail "failure must leave the current snapshot absent"
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

(* A declared total deadline may end a successful response before its body
   completes. The next API candidate must run before an optional CLI tail. *)
let test_body_timeout_reaches_http_successor ~with_cli () =
  with_eio @@ fun ~sw ~net ~clock ~base_path ->
  Fixture.with_official_client_runtimes @@ fun () ->
  Prompt_registry.set_markdown_dir
    (Masc_test_deps.source_path "config/prompts");
  let keeper_id = if with_cli then "timeout-with-cli" else "timeout-without-cli" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let initial =
    match Current.replace ~clock ~keepers_dir ~keeper_id ~expected_revision:None
      ~now:1_000_000.
      ~source:{ Current.kind = Current.Explicit_write; trace_id = "seed" }
      ~facts:[current_a; current_b] () with
    | Ok snapshot -> snapshot
    | Error detail -> fail detail
  in
  let read_snapshot () =
    match Current.read_for_keepers_dir ~keepers_dir ~keeper_id with
    | Ok (Some snapshot) -> snapshot
    | Ok None -> fail "the seeded Memory snapshot disappeared"
    | Error detail -> fail detail
  in
  let snapshot_path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id in
  let initial_bytes = Fs_compat.load_file snapshot_path in
  let snapshot_at_successor = ref None in
  let first = Fixture.start_server ~sw ~net ~clock
    (Fixture.Incomplete_reply {|{"choices":[|}) in
  let second = Fixture.start_server ~sw ~net ~clock
    ~on_request_before_reply:(fun () ->
      let snapshot = read_snapshot () in
      snapshot_at_successor := Some (Fs_compat.load_file snapshot_path, snapshot.revision))
    (Fixture.Reply (Fixture.openai_response valid_selection_json)) in
  let first_id = "librarian-body-timeout" in
  let second_id = "librarian-http-successor" in
  ignore (Fixture.publish_registry
    ~cli_slot_ids:(if with_cli then [Fixture.cli_primary_runtime] else [])
    ~lane_id:"librarian_exact" ~slot_ids:[first_id; second_id]
    (Fixture.resolver_snapshot ~source:"librarian body-timeout successor"
       ~body_timeouts:[first_id, 1.0]
       [{ Fixture.id = first_id; base_url = first.base_url };
        { Fixture.id = second_id; base_url = second.base_url }])
    : Runtime_exact_output_registry.t);
  let cli_calls = ref [] in
  let runner ~runtime:{Runtime_instance.id=runtime_id;_} ~system_prompt:_ ~output_schema:_ ~prompt:_ =
    cli_calls := runtime_id :: !cli_calls;
    Ok (Yojson.Safe.to_string valid_selection_json)
  in
  Runtime.run_best_effort ~cli_runner:runner
    ~base_path ~keepers_dir ~keeper_id ~expected_revision:(Some initial.revision)
    (input ());
  check int "the incomplete HTTP response was requested once" 1
    (Fixture.post_count first);
  check int "the next configured HTTP candidate was requested once" 1
    (Fixture.post_count second);
  check (list string) "HTTP successor answers before CLI" [] !cli_calls;
  (match !snapshot_at_successor with
   | Some (bytes, revision) ->
     check string "no Memory write before successor response" initial_bytes bytes;
     check int "no premature Memory revision" initial.revision revision
   | None -> fail "the HTTP successor did not observe the pre-commit state");
  let snapshot = read_snapshot () in
  check int "one Memory commit after accepted HTTP successor output"
    (initial.revision + 1) snapshot.revision;
  check (list string) "accepted HTTP disposition was committed"
    [current_a.claim]
    (List.map (fun (fact : Memory.fact) -> fact.claim) snapshot.facts);
  (match Current.read_journal_tail ~keepers_dir ~keeper_id ~limit:10 with
   | [Ok (Current.Journal_committed _);
      Ok (Current.Journal_committed { source = { kind = Current.Librarian; _ }; _ })] -> ()
   | _ -> fail "expected seed and one Librarian commit in the Memory journal");
  Printf.printf
    "BODY_DEADLINE_ADVANCE with_cli=%b api1=%d api2=%d cli=%d memory_revision=%d->%d\n%!"
    with_cli (Fixture.post_count first) (Fixture.post_count second)
    (List.length !cli_calls) initial.revision snapshot.revision
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

let test_admission_worker_requires_actual_input_capacity () =
  with_eio @@ fun ~sw:_ ~net:_ ~clock:_ ~base_path ->
  Fixture.with_official_client_runtimes @@ fun () ->
  let module Queue = Masc.Keeper_memory_admission_queue in
  let module Worker = Masc.Keeper_memory_admission_worker in
  let require = function Ok value -> value | Error detail -> fail detail in
  Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
  let keeper_id = "cli-lane-keeper" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let initial = Current.replace ~keepers_dir ~keeper_id ~expected_revision:None
    ~now:1_000_000. ~source:{Current.kind=Current.Explicit_write; trace_id="seed"}
    ~facts:[current_a;current_b] () |> require in
  List.iter (fun id -> ignore (Queue.append ~keepers_dir ~keeper_id ~request_id:id
    (fact ~claim:("candidate " ^ id)) |> Result.map_error Queue.append_error_to_string |> require)) ["a";"b";"c";"d"];
  let queue_before = Fs_compat.load_file (Queue.path ~keepers_dir ~keeper_id) in
  let current_before = Fs_compat.load_file (Current.path_for_keepers_dir ~keepers_dir ~keeper_id) in
  let attempt ~answers ~expected_calls ~expected_partition_sizes =
    publish_unreachable_lane ~cli_only:true ~cli_slot_ids:(List.map fst answers)
      ~source:"admission capacity evidence fixture" ();
    let calls = ref 0 and sizes = ref [] and reports = ref [] in
    let runner ~runtime:{Runtime_instance.id=runtime_id;_} ~system_prompt:_ ~output_schema:_ ~prompt:_ =
      incr calls; List.assoc runtime_id answers in
    let judge admission =
      sizes := List.length (Queue.candidates admission) :: !sizes;
      let outcome = ref (Worker.Deferred "missing runtime callback") in
      Runtime.run_best_effort ~write_scope:Runtime.Memory_maintenance ~admission ~cli_runner:runner
        ~on_memory_committed:(fun () -> outcome := Worker.Committed)
        ~on_admission_deferred:(fun () -> outcome := Worker.Awaiting_evidence)
        ~on_not_committed:(fun reason -> reports := reason :: !reports;
          outcome := Worker.For_testing.judgment_of_not_committed reason)
        ~base_path ~keepers_dir ~keeper_id ~expected_revision:(Some initial.revision) (input ());
      !outcome in
    (match Worker.For_testing.run_with ~keepers_dir ~keeper_name:keeper_id ~judge with
     | Worker.Pending _ -> () | _ -> fail "failed candidate batch must remain pending");
    check int "actual runtime runner calls" expected_calls !calls;
    check (list int) "actual worker partition traversal" expected_partition_sizes (List.rev !sizes);
    check string "failure leaves queue unchanged" queue_before
      (Fs_compat.load_file (Queue.path ~keepers_dir ~keeper_id));
    check string "failure leaves current facts unchanged" current_before
      (Fs_compat.load_file (Current.path_for_keepers_dir ~keepers_dir ~keeper_id));
    !reports in
  List.iter (fun (answer,expected_descent) ->
    let reports = attempt ~answers:[Fixture.cli_primary_runtime,answer] ~expected_calls:1 ~expected_partition_sizes:[4] in
    check bool "output and transport failure provide no admission capacity evidence" true
      (List.for_all (fun (r : Runtime.not_committed) ->
        r.input_capacity_evidence=Runtime.No_input_capacity_refusal
        && r.message_descent=expected_descent) reports);
    check bool "output and ordinary transport failures cannot descend messages" false
      (Runtime.may_descend_messages reports))
    [Ok "not-json",Runtime.Invalid_output_blocks_descent;
     Ok "{}",Runtime.Invalid_output_blocks_descent;
     Error (Masc.Fusion_official_client.Setup_failure "offline"),Runtime.No_descent_evidence];
  let capacity_answer = Error (Masc.Fusion_official_client.Codex_failure
    (Runtime_codex_app_server.Context_window_exceeded
      {message="fixture explicit input refusal"; tool_effect_attempted=false})) in
  let reports = attempt ~answers:[Fixture.cli_primary_runtime,capacity_answer]
      ~expected_calls:7 ~expected_partition_sizes:[4;2;1;1;2;1;1] in
  check bool "typed input refusal alone authorizes partition traversal" true
    (List.for_all (fun (r : Runtime.not_committed) ->
      r.input_capacity_evidence=Runtime.Input_capacity_refused) reports);
  check bool "native context refusal is distinct from measured range-size evidence" true
    (List.for_all (fun (r : Runtime.not_committed) ->
      not r.walk_shows_size && not r.smaller_range_meets_same_failure
      && r.message_descent=Runtime.Smaller_input_may_help) reports);
  check bool "native context refusal permits reading a smaller message input" true
    (Runtime.may_descend_messages reports);
  List.iter (fun (first,second) ->
    let reports = attempt
        ~answers:[Fixture.cli_primary_runtime,first;Fixture.cli_secondary_runtime,second]
        ~expected_calls:2 ~expected_partition_sizes:[4] in
    check bool "invalid output vetoes capacity evidence in either slot order" true
      (List.for_all (fun (r : Runtime.not_committed) ->
        r.input_capacity_evidence=Runtime.No_input_capacity_refusal
        && not r.walk_shows_size
        && r.message_descent=Runtime.Invalid_output_blocks_descent) reports);
    check bool "invalid output blocks message descent in either slot order" false
      (Runtime.may_descend_messages reports))
    [Ok "{}",capacity_answer;capacity_answer,Ok "{}";
     Ok "not-json",capacity_answer;capacity_answer,Ok "not-json"]
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

(* The absorb gate refuses before any request when the pass's observations
   and Memory do not fit one. The supporting candidates are among those
   observations: four of them overflow a request and two fit, so the worker
   splits the batch instead of sending it whole on every wake. The judgment
   endpoint is closed, so the fitting half fails its sent request and the
   pass stays pending. *)
let test_absorb_gate_capacity_refusal_splits_the_admission_batch () =
  with_eio @@ fun ~sw:_ ~net:_ ~clock:_ ~base_path ->
  Fixture.with_official_client_runtimes @@ fun () ->
  Masc_test_deps.with_process_env "TYPESAFEAI_API_KEY" (Some "synthetic-jev-key") @@ fun () ->
  Masc_test_deps.with_typesafeai_policy
    { Runtime_schema.default_typesafeai with
      lane_enabled = true
    ; absorb_gate = true
    ; destinations =
        ( { Runtime_schema.endpoint = "http://127.0.0.1:1/evaluate"; model = "jev-fixture"
          ; api_key_env = "TYPESAFEAI_API_KEY" }
        , [] )
    } @@ fun () ->
  let module Queue = Masc.Keeper_memory_admission_queue in
  let module Worker = Masc.Keeper_memory_admission_worker in
  let require = function Ok value -> value | Error detail -> fail detail in
  Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
  publish_unreachable_lane ~cli_only:true ~cli_slot_ids:[Fixture.cli_primary_runtime]
    ~source:"absorb gate capacity fixture" ();
  let keeper_id = "cli-lane-keeper" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let initial = Current.replace ~keepers_dir ~keeper_id ~expected_revision:None
    ~now:1_000_000. ~source:{Current.kind=Current.Explicit_write; trace_id="seed"}
    ~facts:[current_a;current_b] () |> require in
  let request_ids = List.map (fun id -> "capacity-candidate-" ^ id) ["a";"b";"c";"d"] in
  let candidate_bytes = Masc.Keeper_librarian_absorb_gate.request_bytes_limit * 9 / 32 in
  List.iter (fun request_id -> ignore (Queue.append ~keepers_dir ~keeper_id ~request_id
    (fact ~claim:(request_id ^ " " ^ String.make candidate_bytes 'x')) |> Result.map_error Queue.append_error_to_string |> require)) request_ids;
  let merged = "keep A together with B" in
  let runner ~runtime:_ ~system_prompt:_ ~output_schema:_ ~prompt =
    let present = List.filter (fun affix -> Astring.String.is_infix ~affix prompt) request_ids in
    Ok (Yojson.Safe.to_string (`Assoc
      [ "memory", `Assoc
          [ "working_contexts", `List []
          ; Librarian.wire_field_new_claims, `List
              [ `Assoc [ "claim", `String merged; "category", `String "fact"
                       ; "absorbs", `List [`String "m1"; `String "m2"] ] ]
          ; Librarian.wire_field_dropped, `List [] ]
      ; "change_support", `List (List.map (fun id -> `String id) present)
      ; "candidates", `List (List.map (fun id -> `Assoc
          [ "request_id", `String id; "outcome", `String "incorporated"
          ; "memory_claim", `String merged; "reason", `String "capacity fixture" ]) present) ])) in
  let sizes = ref [] and reports = ref [] in
  let judge admission =
    sizes := List.length (Queue.candidates admission) :: !sizes;
    let outcome = ref (Worker.Deferred "missing runtime callback") in
    Runtime.run_best_effort ~write_scope:Runtime.Memory_maintenance ~admission ~cli_runner:runner
      ~on_memory_committed:(fun () -> outcome := Worker.Committed)
      ~on_admission_deferred:(fun () -> outcome := Worker.Awaiting_evidence)
      ~on_not_committed:(fun reason -> reports := reason :: !reports;
        outcome := Worker.For_testing.judgment_of_not_committed reason)
      ~base_path ~keepers_dir ~keeper_id ~expected_revision:(Some initial.revision) (input ());
    !outcome in
  (match Worker.For_testing.run_with ~keepers_dir ~keeper_name:keeper_id ~judge with
   | Worker.Pending _ -> () | _ -> fail "the half whose judgment request failed must stay pending");
  (match List.rev !reports with
   | (whole : Runtime.not_committed) :: _ ->
     check bool "the whole batch met the gate's pre-request capacity refusal" true
       whole.walk_shows_size;
     check bool "that refusal is admission input capacity evidence" true
       (whole.input_capacity_evidence = Runtime.Input_capacity_refused)
   | [] -> fail "the gate refusal produced no report");
  check (list int) "the gate's capacity refusal splits the batch" [4;2] (List.rev !sizes)
;;

let test_explicit_admission_envelope ?(transport_failure=false) ~deferred () =
  with_eio @@ fun ~sw:_ ~net:_ ~clock:_ ~base_path ->
  Fixture.with_official_client_runtimes @@ fun () ->
  let module Queue = Masc.Keeper_memory_admission_queue in
  let require = function Ok value -> value | Error detail -> fail detail in
  Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
  publish_unreachable_lane ~cli_only:true ~cli_slot_ids:[Fixture.cli_primary_runtime]
    ~source:"explicit admission fixture" ();
  let keeper_id = "cli-lane-keeper" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let initial = Current.replace ~keepers_dir ~keeper_id ~expected_revision:None
    ~now:1_000_000. ~source:{Current.kind=Current.Explicit_write; trace_id="seed"}
    ~facts:[current_a;current_b] () |> require in
  let config = Masc.Workspace.default_config base_path in
  let meta = Masc_test_deps.meta_of_json_fixture
    (`Assoc ["name",`String keeper_id;"trace_id",`String "admission-producer"]) |> require in
  let written = Masc.Keeper_tool_memory_runtime.keeper_memory_write_with_outcome
    ~config ~meta ~args:(`Assoc ["content",`String "A was confirmed; B was withdrawn in favor of A"]) in
  let receipt = Yojson.Safe.from_string written.raw_output in
  check string "actual producer returns pending outcome" "persisted_pending_admission"
    Yojson.Safe.Util.(receipt |> member "outcome" |> to_string);
  check bool "pending receipt has no current identity" true
    (Yojson.Safe.Util.member "memory_id" receipt = `Null);
  let request_id = Yojson.Safe.Util.(receipt |> member "request_id" |> to_string) in
  let admission = match Queue.read_pending ~keepers_dir ~keeper_id |> require with
    | Some batch -> batch | None -> fail "missing candidate" in
  let requests = ref 0 in
  let held = deferred || transport_failure in
  let runner ~runtime:_ ~system_prompt:_ ~output_schema ~prompt =
    incr requests;
    let properties = Yojson.Safe.Util.member "properties" output_schema in
    check bool "provider schema requires candidate judgments" true
      (Yojson.Safe.Util.member "candidates" properties <> `Null);
    check bool "actual prompt includes pending candidate identity" true
      (Astring.String.is_infix ~affix:request_id prompt);
    let outcome, memory_claim = if deferred then "deferred", `Null
      else "already_represented", `String current_a.claim in
    if transport_failure then Error (Masc.Fusion_official_client.Setup_failure "synthetic transport unavailable")
    else Ok (Yojson.Safe.to_string (`Assoc ["memory",(if deferred then unchanged_memory_json else valid_selection_json);
      "change_support",`List (if deferred then [] else [`String request_id]);
      "candidates",`List [`Assoc ["request_id",`String request_id;
        "outcome",`String outcome; "memory_claim",memory_claim;
        "reason",`String "same event; judgment fixture"]]])) in
  let committed = ref 0 and retained = ref 0 and awaiting_evidence = ref 0 in
  Runtime.run_best_effort ~write_scope:Runtime.Memory_maintenance ~admission
    ~cli_runner:runner ~on_memory_committed:(fun () -> incr committed)
    ~on_not_committed:(fun _ -> incr retained)
    ~on_admission_deferred:(fun () -> incr awaiting_evidence)
    ~base_path ~keepers_dir ~keeper_id ~expected_revision:(Some initial.revision) (input ());
  check int "one actual exact-lane dispatch" 1 !requests;
  check int "only settled answer commits" (if held then 0 else 1) !committed;
  check int "uncertainty is explicitly retained" (if held then 1 else 0) !retained;
  check int "only validated semantic deferral emits evidence-wait signal"
    (if deferred && not transport_failure then 1 else 0) !awaiting_evidence;
  Queue.acknowledge_committed ~keepers_dir ~keeper_id |> require;
  check bool "queue consumption follows the Memory receipt" held
    (Option.is_some (Queue.read_pending ~keepers_dir ~keeper_id |> require));
  let after = match Current.read_for_keepers_dir ~keepers_dir ~keeper_id |> require with
    | Some value -> value | None -> fail "snapshot absent" in
  check (list string) "deferred answer has no Memory effects"
    (if held then [current_a.claim;current_b.claim] else [current_a.claim])
    (List.map (fun (f : Memory.fact) -> f.claim) after.facts)
;;

(* Model answers are injected: this proves evidence delivery and store/receipt
   behavior, not that a live model always chooses the appropriate outcome. *)
let test_admission_retirement_evidence ~reobserved () =
  with_eio @@ fun ~sw:_ ~net:_ ~clock:_ ~base_path ->
  Fixture.with_official_client_runtimes @@ fun () ->
  Masc_test_deps.with_typesafeai_policy
    {Runtime_schema.default_typesafeai with lane_enabled=false; absorb_gate=false} @@ fun () ->
  let module Queue = Masc.Keeper_memory_admission_queue in
  let require = function Ok value -> value | Error detail -> fail detail in
  Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
  publish_unreachable_lane ~cli_only:true ~cli_slot_ids:[Fixture.cli_primary_runtime]
    ~source:"retirement admission fixture" ();
  let keeper_id = "cli-lane-keeper" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let config = Masc.Workspace.default_config base_path in
  let meta = Masc_test_deps.meta_of_json_fixture
    (`Assoc ["name",`String keeper_id; "trace_id",`String "retirement-input"]) |> require in
  let policy = fact ~claim:"Production P-42 requires owner approval." in
  let unrelated = fact ~claim:"Unrelated staging R-9 uses a separate checklist." in
  ignore (Current.replace ~keepers_dir ~keeper_id ~expected_revision:None
    ~now:(Time_compat.now ()) ~source:{Current.kind=Current.Explicit_write; trace_id="seed"}
    ~facts:[policy;unrelated] () |> require : Current.t);
  let enqueue () =
    let result = Masc.Keeper_tool_memory_runtime.keeper_memory_write_with_outcome
      ~config ~meta ~args:(`Assoc ["content",`String policy.claim]) in
    let json = Yojson.Safe.from_string result.raw_output in
    check string "real producer queues observation" "persisted_pending_admission"
      Yojson.Safe.Util.(json |> member "outcome" |> to_string) in
  let retire target reason =
    let result = Masc.Keeper_tool_memory_runtime.keeper_memory_retract_with_outcome
      ~config ~meta ~args:(`Assoc ["memory_id",`String (Memory.memory_id target);
                                 "reason",`String reason]) in
    check bool "real retract removes current fact" true
      Yojson.Safe.Util.(Yojson.Safe.from_string result.raw_output |> member "ok" |> to_bool) in
  if not reobserved then enqueue ();
  let reason = "P-42 policy was withdrawn by its owner; assess later evidence separately." in
  retire policy reason;
  retire unrelated "UNRELATED_RETIREMENT_MUST_NOT_ENTER_ADMISSION";
  if reobserved then enqueue ();
  let admission = match Queue.read_pending ~keepers_dir ~keeper_id |> require with
    | Some batch -> batch | None -> fail "candidate missing" in
  let candidate = match Queue.candidates admission with
    | [candidate] -> candidate | _ -> fail "expected one candidate" in
  let snapshot = match Current.read_for_keepers_dir ~keepers_dir ~keeper_id |> require with
    | Some snapshot -> snapshot | None -> fail "retired snapshot missing" in
  check int "both facts retired before model" 0 (List.length snapshot.facts);
  let current_before = Fs_compat.load_file (Current.path_for_keepers_dir ~keepers_dir ~keeper_id) in
  let captured = ref [] in
  let runner ~runtime:_ ~system_prompt:_ ~output_schema:_ ~prompt =
    captured := prompt :: !captured;
    let claims = if reobserved then [`Assoc ["claim",`String policy.claim;
      "category",`String "fact"; "supersedes",`Null; "absorbs",`List []]] else [] in
    Ok (Yojson.Safe.to_string (`Assoc ["memory",`Assoc ["new_claims",`List claims;
      "dropped",`List []; "working_contexts",`List []];
      "change_support",`List (if reobserved then [`String candidate.request_id] else []);
      "candidates",`List [`Assoc ["request_id",`String candidate.request_id;
        "outcome",`String (if reobserved then "incorporated" else "not_durable");
        "memory_claim",(if reobserved then `String policy.claim else `Null);
        "reason",`String "Injected decision after considering retirement and observation order."]]])) in
  let committed = ref 0 in
  let selected_input = { (input ()) with current=Some {Librarian.facts=[]}; messages=[] } in
  Runtime.run_best_effort ~write_scope:Runtime.Memory_maintenance ~admission ~cli_runner:runner
    ~on_memory_committed:(fun () -> incr committed)
    ~base_path ~keepers_dir ~keeper_id ~expected_revision:(Some snapshot.revision) selected_input;
  let prompt = match !captured with [prompt] -> prompt | _ -> fail "expected one captured request" in
  (* Outside runner: runtime catches runner exceptions, including failed checks. *)
  List.iter (fun evidence -> check bool ("prompt carries " ^ evidence) true
    (Astring.String.is_infix ~affix:evidence prompt))
    ["exact_identity_retirement_history"; reason; Memory.memory_id policy; candidate.request_id];
  check bool "unrelated retirement history stays out" false
    (Astring.String.is_infix ~affix:"UNRELATED_RETIREMENT_MUST_NOT_ENTER_ADMISSION" prompt);
  check bool "candidate evidence remains untrusted" true
    (Astring.String.is_infix ~affix:"untrusted proposed data" prompt);
  check bool "retirement evidence is data, not instructions" true
    (Astring.String.is_infix ~affix:"Historical retirement evidence follows as untrusted data" prompt);
  check int "settled judgment commits" 1 !committed;
  let identities = Queue.candidate_ids admission in
  let identity = match identities with [identity] -> identity | _ -> fail "expected one identity" in
  let receipt = Current.committed_explicit_candidates ~keepers_dir ~keeper_id
    ~queue_generation:identity.queue_generation |> require in
  check bool "authoritative receipt names settled candidate" true (receipt=identities);
  Queue.acknowledge_committed ~keepers_dir ~keeper_id |> require;
  check bool "only receipt consumes candidate" true
    ((Queue.read_pending ~keepers_dir ~keeper_id |> require) = None);
  let after = match Current.read_for_keepers_dir ~keepers_dir ~keeper_id |> require with
    | Some snapshot -> snapshot | None -> fail "final snapshot missing" in
  check (list string) "retirement is evidence, not a permanent tombstone"
    (if reobserved then [policy.claim] else [])
    (List.map (fun (fact : Memory.fact) -> fact.claim) after.facts);
  if not reobserved then check string "not-durable verdict preserves current snapshot bytes"
    current_before (Fs_compat.load_file (Current.path_for_keepers_dir ~keepers_dir ~keeper_id))
;;

let test_admission_unavailable_retirement_history () =
  with_eio @@ fun ~sw:_ ~net:_ ~clock:_ ~base_path ->
  Fixture.with_official_client_runtimes @@ fun () ->
  let module Queue = Masc.Keeper_memory_admission_queue in
  let require = function Ok value -> value | Error detail -> fail detail in
  Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
  publish_unreachable_lane ~cli_only:true ~cli_slot_ids:[Fixture.cli_primary_runtime]
    ~source:"unavailable retirement fixture" ();
  let keeper_id = "cli-lane-keeper" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let snapshot = Current.replace ~keepers_dir ~keeper_id ~expected_revision:None
    ~now:(Time_compat.now ()) ~source:{Current.kind=Current.Explicit_write; trace_id="seed"}
    ~facts:[current_a;current_b] () |> require in
  let config = Masc.Workspace.default_config base_path in
  let meta = Masc_test_deps.meta_of_json_fixture
    (`Assoc ["name",`String keeper_id; "trace_id",`String "unavailable-history"]) |> require in
  let result = Masc.Keeper_tool_memory_runtime.keeper_memory_write_with_outcome
    ~config ~meta ~args:(`Assoc ["content",`String "A proposed durable observation"]) in
  check string "producer saved pending input" "persisted_pending_admission"
    Yojson.Safe.Util.(Yojson.Safe.from_string result.raw_output |> member "outcome" |> to_string);
  let admission = match Queue.read_pending ~keepers_dir ~keeper_id |> require with
    | Some batch -> batch | None -> fail "candidate missing" in
  let candidate = match Queue.candidates admission with
    | [candidate] -> candidate | _ -> fail "expected one candidate" in
  let journal_path = Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
  Fs_compat.save_file_atomic_strict journal_path "{malformed retirement journal}\n" |> require;
  let current_path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id in
  let queue_path = Queue.path ~keepers_dir ~keeper_id in
  let current_before = Fs_compat.load_file current_path in
  let queue_before = Fs_compat.load_file queue_path in
  let captured = ref [] and committed = ref 0 and deferred = ref 0 in
  let runner ~runtime:_ ~system_prompt:_ ~output_schema:_ ~prompt =
    captured := prompt :: !captured;
    Ok (Yojson.Safe.to_string (`Assoc ["memory",`Assoc ["new_claims",`List [];
      "dropped",`List []; "working_contexts",`List []];
      "change_support",`List [];
      "candidates",`List [`Assoc ["request_id",`String candidate.request_id;
        "outcome",`String "deferred"; "memory_claim",`Null;
        "reason",`String "Injected uncertainty because retirement evidence is unavailable."]]])) in
  Runtime.run_best_effort ~write_scope:Runtime.Memory_maintenance ~admission ~cli_runner:runner
    ~on_memory_committed:(fun () -> incr committed)
    ~on_not_committed:(fun _ -> incr deferred)
    ~base_path ~keepers_dir ~keeper_id ~expected_revision:(Some snapshot.revision) (input ());
  let prompt = match !captured with [prompt] -> prompt | _ -> fail "expected one captured request" in
  (* These checks run outside the runtime's exception-catching runner boundary. *)
  check bool "history read failure is represented explicitly" true
    (Astring.String.is_infix
      ~affix:{|"evidence_kind":"exact_identity_retirement_history","status":"unavailable"|} prompt);
  check bool "unavailable history is not an empty successful archive" false
    (Astring.String.is_infix ~affix:{|"status":"available","matches":[]|} prompt);
  check int "deferred response commits nothing" 0 !committed;
  check int "deferred response is reported" 1 !deferred;
  let identity = match Queue.candidate_ids admission with
    | [identity] -> identity | _ -> fail "expected one identity" in
  check bool "no consumed-input receipt was created" true
    ((Current.committed_explicit_candidates ~keepers_dir ~keeper_id
      ~queue_generation:identity.queue_generation |> require) = []);
  Queue.acknowledge_committed ~keepers_dir ~keeper_id |> require;
  check string "current Memory stays byte-exact" current_before (Fs_compat.load_file current_path);
  check string "candidate queue stays byte-exact" queue_before (Fs_compat.load_file queue_path)
;;

(* Injected decisions exercise partial commit authority, not model quality. *)
let test_mixed_admission ~depends_on_deferred () =
  with_eio @@ fun ~sw:_ ~net:_ ~clock:_ ~base_path ->
  Fixture.with_official_client_runtimes @@ fun () ->
  Masc_test_deps.with_typesafeai_policy
    {Runtime_schema.default_typesafeai with lane_enabled=false; absorb_gate=false} @@ fun () ->
  let module Queue = Masc.Keeper_memory_admission_queue in
  let require = function Ok value -> value | Error detail -> fail detail in
  Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
  publish_unreachable_lane ~cli_only:true ~cli_slot_ids:[Fixture.cli_primary_runtime]
    ~source:"mixed admission fixture" ();
  let keeper_id = "cli-lane-keeper" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let initial = Current.replace ~keepers_dir ~keeper_id ~expected_revision:None
    ~now:(Time_compat.now ()) ~source:{Current.kind=Current.Explicit_write;trace_id="seed"}
    ~facts:[] () |> require in
  let config = Masc.Workspace.default_config base_path in
  let meta = Masc_test_deps.meta_of_json_fixture
    (`Assoc ["name",`String keeper_id;"trace_id",`String "mixed-admission"]) |> require in
  let enqueue claim =
    let result = Masc.Keeper_tool_memory_runtime.keeper_memory_write_with_outcome
      ~config ~meta ~args:(`Assoc ["content",`String claim]) in
    let json = Yojson.Safe.from_string result.raw_output in
    check string "real producer persists candidate" "persisted_pending_admission"
      Yojson.Safe.Util.(json |> member "outcome" |> to_string);
    Yojson.Safe.Util.(json |> member "request_id" |> to_string) in
  let uncertain_id = enqueue "A awaits owner confirmation." in
  let confirmed_claim = "Independent B has owner approval." in
  let confirmed_id = enqueue confirmed_claim in
  let admission = match Queue.read_pending ~keepers_dir ~keeper_id |> require with
    | Some batch -> batch | None -> fail "pending batch absent" in
  let uncertain, confirmed = match Queue.candidate_ids admission with
    | [a;b] -> a,b | _ -> fail "expected two candidate identities" in
  let current_path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id in
  let queue_path = Queue.path ~keepers_dir ~keeper_id in
  let before_current = Fs_compat.load_file current_path in
  let before_queue = Fs_compat.load_file queue_path in
  let requests = ref 0 and committed = ref 0 in
  let runner ~runtime:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ =
    incr requests;
    Ok (Yojson.Safe.to_string (`Assoc [
      "memory",`Assoc ["new_claims",`List [`Assoc ["claim",`String confirmed_claim;
        "category",`String "fact";"supersedes",`Null;"absorbs",`List []]];
        "dropped",`List [];"working_contexts",`List []];
      "change_support",`List [`String (if depends_on_deferred then uncertain_id else confirmed_id)];
      "candidates",`List [
        `Assoc ["request_id",`String uncertain_id;"outcome",`String "deferred";
          "memory_claim",`Null;"reason",`String "Owner confirmation remains missing."];
        `Assoc ["request_id",`String confirmed_id;"outcome",`String "incorporated";
          "memory_claim",`String confirmed_claim;"reason",`String "Independent confirmed observation."]]])) in
  let selected_input = {(input ()) with current=Some {Librarian.facts=[]};messages=[]} in
  Runtime.run_best_effort ~write_scope:Runtime.Memory_maintenance ~admission
    ~cli_runner:runner ~on_memory_committed:(fun () -> incr committed)
    ~base_path ~keepers_dir ~keeper_id ~expected_revision:(Some initial.revision) selected_input;
  check int "one injected provider response" 1 !requests;
  check int "only independently supported subset commits" (if depends_on_deferred then 0 else 1) !committed;
  let receipts = Current.committed_explicit_candidates ~keepers_dir ~keeper_id
    ~queue_generation:uncertain.queue_generation |> require in
  check bool "only B obtains a receipt; A never does" true
    (receipts = if depends_on_deferred then [] else [confirmed]);
  Queue.acknowledge_committed ~keepers_dir ~keeper_id |> require;
  let remaining = match Queue.read_pending ~keepers_dir ~keeper_id |> require with
    | Some batch -> Queue.candidates batch | None -> fail "A must remain pending" in
  check (list string) "uncertain input remains pending with its identity"
    (if depends_on_deferred then [uncertain_id;confirmed_id] else [uncertain_id])
    (List.map (fun (row : Queue.candidate) -> row.request_id) remaining);
  let snapshot = match Current.read_for_keepers_dir ~keepers_dir ~keeper_id |> require with
    | Some value -> value | None -> fail "current snapshot absent" in
  check (list string) "only independent confirmed memory enters current"
    (if depends_on_deferred then [] else [confirmed_claim])
    (List.map (fun (row : Memory.fact) -> row.claim) snapshot.facts);
  if depends_on_deferred then (
    check string "shared uncertain change leaves snapshot untouched" before_current
      (Fs_compat.load_file current_path);
    check string "shared uncertain change leaves queue untouched" before_queue
      (Fs_compat.load_file queue_path))
;;

let test_a_later_report_without_capacity_evidence_keeps_the_refusal () =
  let report evidence : Runtime.not_committed =
    { input_capacity_evidence = evidence; provider_input_refusals = []; message_descent=Runtime.No_descent_evidence;
      detail = "fixture"; walk_shows_size = false;
      smaller_range_meets_same_failure = false } in
  let refused = report Runtime.Input_capacity_refused in
  let silent = report Runtime.No_input_capacity_refusal in
  let module Worker = Masc.Keeper_memory_admission_worker in
  let keep = Worker.For_testing.keep_strongest_judgment in
  let first = keep (Worker.Deferred "no report yet") refused in
  check bool "a capacity refusal is recorded" true
    (match first with Worker.Input_size_refused _ -> true | _ -> false);
  check bool "a later report with no evidence cannot retract it" true
    (match keep first silent with Worker.Input_size_refused _ -> true | _ -> false);
  check bool "without a refusal the later report stands" true
    (match keep (Worker.Deferred "earlier") silent with Worker.Deferred _ -> true | _ -> false)

(* A Memory inference uses real parsing and gate policy but has no publication
   authority. Its captured source and typed decision remain process-local. *)
let inference_answer =
  `Assoc ["new_claims", `List [`Assoc
    ["claim", `String "A and revised B remain grounded in the original observations."
    ; "category", `String "fact"; "supersedes", `String "m2"
    ; "absorbs", `List [`String "m1"]]]
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

let test_memory_inference_retains_gated_decision () =
  with_eio @@ fun ~sw:_ ~net:_ ~clock:_ ~base_path ->
  Fixture.with_official_client_runtimes @@ fun () ->
  Masc_test_deps.with_typesafeai_policy
    {Runtime_schema.default_typesafeai with lane_enabled=false; absorb_gate=false} @@ fun () ->
  let require = function Ok value -> value | Error detail -> fail detail in
  Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
  publish_unreachable_lane ~cli_only:true ~cli_slot_ids:[Fixture.cli_primary_runtime]
    ~source:"process-only Memory inference" ();
  let keeper_id = "cli-lane-keeper" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  ignore (Current.replace ~keepers_dir ~keeper_id ~expected_revision:None ~now:1_000_000.
    ~source:{Current.kind=Current.Explicit_write;trace_id="seed"}
    ~facts:[current_a;current_b] () |> require : Current.t);
  let paths = inference_store_paths ~keepers_dir ~keeper_id in
  let before = List.map Fs_compat.load_file_opt paths in
  let captured = ref [] in
  let runner ~runtime:_ ~system_prompt:_ ~output_schema:_ ~prompt =
    captured := prompt :: !captured;
    Ok (Yojson.Safe.to_string inference_answer) in
  let selected_input = {(input ()) with
    working_context={Masc.Keeper_librarian_context.empty with unavailable=["pending-source"]}} in
  let started = Time_compat.now () in
  let result = Runtime.infer_memory_step ~cli_runner:runner ~base_path ~keepers_dir ~keeper_id
    ~previous_state:(Some "prior continuation, not Memory evidence") ~unread_messages:[] selected_input in
  check bool "inference preserves every Memory and context store" true
    (before = List.map Fs_compat.load_file_opt paths);
  let step = match result with
    | Runtime.Memory_not_inferred {reports;_} ->
      failf "Memory inference refused: %s"
        (String.concat "; " (List.map (fun (r : Runtime.not_committed) -> r.detail) reports))
    | Runtime.Memory_inferred {step;served_by} ->
      check served_slot "actual serving transport is retained"
        (Runtime.Cli_slot Fixture.cli_primary_runtime) served_by; step in
  check bool "exact source input is bound, excluding live queue ownership" true
    (step.source_input = {selected_input with working_context=Masc.Keeper_librarian_context.empty});
  let claim = match step.new_claims with [claim] -> claim | _ -> fail "expected one validated claim" in
  let identity = Memory.memory_id claim in
  check bool "one parser acceptance assigns fact timestamps" true
    (claim.first_seen >= started && claim.first_seen = claim.last_seen
      && claim.last_seen <= Time_compat.now ());
  check bool "original extracted origin/basis remain intact" true
    (claim.origin = {Memory.kind=Memory.Injected;trace_id=""}
      && claim.basis = Memory.Observed Memory.Transcript);
  check bool "retirement identity and reason remain exact" true
    (step.dropped = [{Memory.memory_id=Memory.memory_id current_b;
      reason="B was revised by the selected observation."}]);
  check bool "revision identity remains exact" true
    (step.revisions = [{Memory.superseded=Memory.memory_id current_b;superseded_by=identity}]);
  check bool "only gated absorption is retained" true
    (step.absorbed = [{Memory.absorbed=Memory.memory_id current_a;into=identity}]
      && step.absorbed = Masc.Keeper_librarian_absorb_gate.absorbed_of_run step.absorb_gate);
  check string "working state remains separate from facts" "planned continuation" step.working_state;
  let prompt = match !captured with [prompt] -> prompt | _ -> fail "expected one Memory request" in
  check bool "Memory prompt carries original conversation" true
    (Astring.String.is_infix ~affix:"new conversation" prompt);
  check bool "Memory prompt carries original current facts" true
    (Astring.String.is_infix ~affix:current_a.claim prompt && Astring.String.is_infix ~affix:current_b.claim prompt);
  let module Registry = Masc.Exact_lane_run_registry in
  let run = match Registry.get (Registry.global ()) ~run_id:step.run_id with
    | Some run -> run | None -> fail "inference run evidence missing" in
  let json = Fixture.lane_run_detail run in
  let decoded = Masc.Tui_decode.decode_lane_run_detail json |> require in
  let reading = match decoded.lrd_librarian_preflight with
    | Some reading -> reading | None -> fail "inference reading missing" in
  check bool "actual producer decodes as Memory inference" true
    (reading.lp_memory_scope = Masc.Tui_decode.Memory_inference_scope);
  check bool "no successful Memory snapshot is claimed" true (reading.lp_memory_result=None);
  check bool "no successful side write is claimed" true
    (reading.lp_side_writes =
      [Masc.Tui_decode.Context_write,Masc.Tui_decode.Side_not_attempted;
       Masc.Tui_decode.Continuity_write,Masc.Tui_decode.Side_not_attempted]);
  let member = Yojson.Safe.Util.member in
  let output = member "output" (member "run" json) in
  let with_field key value = match json, output with
    | `Assoc envelope, `Assoc output ->
      (match List.assoc_opt "run" envelope with
       | Some (`Assoc fields) ->
         `Assoc (("run", `Assoc (("output", `Assoc ((key,value)::List.remove_assoc key output))
           :: List.remove_assoc "output" fields)) :: List.remove_assoc "run" envelope)
       | Some _ | None -> fail "invalid captured run")
    | _ -> fail "invalid captured run" in
  let after = `Assoc ["revision",`Int 1;"fact_count",`Int 1;"commit",`String "unchanged";
    "change",`Assoc ["added_count",`Int 0;"removed_count",`Int 0]] in
  check bool "an inference cannot claim snapshot publication" true
    (Result.is_error (Masc.Tui_decode.decode_lane_run_detail (with_field "after" after)));
  check bool "an inference cannot claim continuity publication" true
    (Result.is_error (Masc.Tui_decode.decode_lane_run_detail
      (with_field "continuity_write" (`Assoc ["status",`String "outcome_unconfirmed"]))));
  check bool "malformed inference marker cannot change scope" true
    (Result.is_error (Masc.Tui_decode.decode_lane_run_detail (with_field "memory_inference" (`Bool false))))
;;

module Memory_plan = Masc.Keeper_librarian_memory_plan

let require_plan = function
  | Ok value -> value
  | Error error -> fail (Memory_plan.error_to_string error)

let expect_plan_error expected = function
  | Ok _ -> fail "an invalid Memory plan was accepted"
  | Error actual ->
    let error = testable
      (fun fmt error -> Format.pp_print_string fmt (Memory_plan.error_to_string error)) ( = ) in
    check error "typed plan rejection" expected actual

let require_memory = function Ok value -> value | Error detail -> fail detail

let memory_answer ?(new_claims=[]) ?(dropped=[]) state =
  `Assoc ["new_claims", `List new_claims; "dropped", `List dropped;
    "working_contexts", `List []; "working_state", `String state]

let retire_wire identity =
  `Assoc ["memory_id", `String identity; "reason", `String "The selected message retires this claim."]

(* Only the CLI completion is injected. Selection, parsing, gate policy and
   source capture are the production inference path. The gate is explicitly
   disabled here; these scenarios do not claim live semantic judgment. *)
let with_memory_plan_fixture initial_facts f =
  with_eio @@ fun ~sw:_ ~net:_ ~clock:_ ~base_path ->
  Fixture.with_official_client_runtimes @@ fun () ->
  Masc_test_deps.with_typesafeai_policy
    {Runtime_schema.default_typesafeai with lane_enabled=false; absorb_gate=false} @@ fun () ->
  Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
  publish_unreachable_lane ~cli_only:true ~cli_slot_ids:[Fixture.cli_primary_runtime]
    ~source:"ordered process-local Memory decisions" ();
  let keeper_id = "cli-lane-keeper" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let snapshot = Option.map (fun facts ->
    Current.replace ~keepers_dir ~keeper_id ~expected_revision:None ~now:1_000_000.
      ~source:{Current.kind=Current.Explicit_write; trace_id="plan-seed"} ~facts ()
    |> require_memory) initial_facts in
  let source = {(input ()) with current=Option.map
    (fun (snapshot : Current.t) -> {Librarian.facts=snapshot.facts}) snapshot} in
  let plan = Memory_plan.create ~keeper_id:source.keeper_id ~turn_ref:source.turn_ref ~snapshot
    |> require_plan in
  let infer source answer =
    let runner ~runtime:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ =
      Ok (Yojson.Safe.to_string answer) in
    match Runtime.infer_memory_step ~cli_runner:runner ~base_path ~keepers_dir ~keeper_id
      ~previous_state:None ~unread_messages:[] source with
    | Runtime.Memory_inferred {step;_} -> step
    | Runtime.Memory_not_inferred {reports;_} ->
      failf "ordered Memory inference refused: %s"
        (String.concat "; " (List.map (fun (r : Runtime.not_committed) -> r.detail) reports))
  in
  f ~keepers_dir ~keeper_id ~snapshot ~source ~plan ~infer

let staged_facts plan =
  match Memory_plan.current plan with None -> [] | Some current -> current.facts

let check_memory_payloads label expected actual =
  let payloads = List.map (fun fact -> Yojson.Safe.to_string (Memory.fact_to_json fact)) in
  check (list string) label (payloads expected) (payloads actual)

(* Sequential store calls are an oracle for individual step semantics, not a
   floor publication algorithm: production must publish once at the boundary. *)
let check_stored_plan_steps ~keepers_dir ~keeper_id plan =
  List.iter (fun (stage : Memory_plan.stage) ->
    let step = stage.step in
    let stored = Current.apply_disposition ~keepers_dir ~keeper_id ~now:(Time_compat.now ())
      ~source:{Current.kind=Current.Librarian; trace_id=Ids.Turn_ref.trace_id step.source_input.turn_ref}
      ~dropped_statements:step.dropped ~absorbed:step.absorbed ~revisions:step.revisions
      ~new_claims:step.new_claims () |> require_memory in
    check_memory_payloads "staged/store facts and order agree" stage.current.facts stored.snapshot.facts;
    check_memory_payloads "staged/store refused claims agree" stage.claims_not_applied stored.claims_not_applied;
    let journal_result = match Current.read_journal_tail ~keepers_dir ~keeper_id ~limit:1 with
      | [entry] -> entry
      | [] | _ :: _ -> fail "expected one disposition journal entry" in
    match require_memory journal_result with
    | Current.Journal_committed {change;_} ->
      check bool "staged/store support invalidations agree, including unchanged snapshots" true
        (stage.invalidated = change.invalidated)
    | Current.Journal_failed _ | Current.Journal_quarantined _ ->
      fail "a successful store oracle did not leave a committed journal entry")
    (Memory_plan.stages plan)

let test_ordered_memory_revision_chain () =
  with_memory_plan_fixture (Some [current_a;current_b])
  @@ fun ~keepers_dir ~keeper_id ~snapshot ~source ~plan ~infer ->
  let paths = inference_store_paths ~keepers_dir ~keeper_id in
  let before = List.map Fs_compat.load_file_opt paths in
  let first = infer source inference_answer in
  let after_first = Memory_plan.append plan first |> require_plan in
  check_memory_payloads "first decision replaces both original facts" first.new_claims (staged_facts after_first);
  let second_input = {source with current=Memory_plan.current after_first;
    messages=[Agent_core.Types.make_message ~role:Agent_core.Types.User
      [Agent_core.Types.Text "A later observation revises the intermediate conclusion."]]} in
  let final_claim = `Assoc ["claim", `String "Final conclusion from the second observation.";
    "category", `String "fact"; "supersedes", `String "m1"] in
  let second = infer second_input
    (memory_answer ~new_claims:[final_claim] ~dropped:[retire_wire "m1"] "second continuation") in
  let result = Memory_plan.append after_first second |> require_plan in
  check_memory_payloads "second decision retains accepted timestamps and fields"
    second.new_claims (staged_facts result);
  check bool "all staging leaves stored bytes unchanged" true (before = List.map Fs_compat.load_file_opt paths);
  check bool "initial snapshot remains the original publication identity" true
    (Memory_plan.initial_snapshot result = snapshot);
  check_memory_payloads "an earlier immutable plan remains reusable" [current_a;current_b] (staged_facts plan);
  (match Memory_plan.stages result with
   | [first_stage;second_stage] ->
     check bool "intermediate source, gate and successor program stay ordered" true
       (first_stage.step = first && second_stage.step = second
         && first_stage.step.source_input = first.source_input
         && second_stage.step.source_input = second_input)
   | _ -> fail "expected two retained decision stages");
  check_stored_plan_steps ~keepers_dir ~keeper_id result

let test_gated_runtime_program_binding () =
  with_memory_plan_fixture (Some [current_a;current_b])
  @@ fun ~keepers_dir ~keeper_id ~snapshot:_ ~source ~plan ~infer ->
  let module Program = Masc.Keeper_memory_os_program in
  let module Adapter = Masc.Keeper_librarian_memory_program in
  let module Source = Masc.Keeper_librarian_unread in
  let anchor = Current.capture_program_anchor ~keepers_dir ~keeper_id |> require_memory in
  let paths = inference_store_paths ~keepers_dir ~keeper_id in
  let before = List.map Fs_compat.load_file_opt paths in
  let first = infer source inference_answer in
  let staged = Memory_plan.append plan first |> require_plan in
  let later_input = {source with current=Memory_plan.current staged;
    messages=[Agent_core.Types.make_message ~role:Agent_core.Types.User
      [Agent_core.Types.Text "A later observation revises the intermediate conclusion."]]} in
  let final_claim = `Assoc ["claim", `String "Final program conclusion.";
    "category", `String "fact"; "supersedes", `String "m1"] in
  let second = infer later_input
    (memory_answer ~new_claims:[final_claim] ~dropped:[retire_wire "m1"] "final program state") in
  let source_of_step index (step : Runtime.memory_step) =
    match step.source_input.messages with
    | [message] -> Source.Official_turn {turn_ref=source.turn_ref;boundary_line=1;
        message_in_turn=index;message_sha256=Source.message_digest message}
    | [] | _ :: _ :: _ -> fail "fixture requires one exact source per decision" in
  let original = source_of_step 0 first and later = source_of_step 1 second in
  let program = Adapter.create ~transaction_id:"gated-runtime-program"
    ~keeper_id:source.keeper_id ~turn_ref:source.turn_ref ~sources:[original;later] ~unread:[]
    ~initial_current:(Some [current_a;current_b]) ~steps:[([original],first);([later],second)]
    |> require_memory in
  let decoded = Program.of_json (Program.to_json program) |> require_memory in
  let execution = Program.replay decoded ~current:[current_a;current_b] |> require_memory in
  check_memory_payloads "actual gated Runtime successors survive both codec and replay"
    second.new_claims execution.final_facts;
  (match decoded.stages with
   | [one;two] ->
     let field key json = match json with
       | `Assoc fields -> List.assoc key fields
       | _ -> fail "expected preserved input evidence" in
     check bool "original rendered base prompt stays with the first inference" true
       (field "rendered_base_prompt" one.decision.input_evidence = `String first.rendered_prompt);
     check bool "host context variables stay original rather than being rerendered" true
       (field "prompt_variables" one.decision.input_evidence
         = `Assoc (List.map (fun (key,value) -> key,`String value) first.prompt_variables));
     check bool "actual gate evidence and final working state survive" true
       (two.decision.gate_evidence = Masc.Keeper_librarian_absorb_gate.run_result_to_yojson second.absorb_gate
         && two.decision.working_state = second.working_state)
   | [] | [_] | _ :: _ :: _ :: _ -> fail "expected two actual Runtime decisions");
  (match Adapter.decision ~sources:[later] first with
   | Error _ -> () | Ok _ -> fail "adapter accepted another message's source hash");
  (match Adapter.decision ~sources:[original;later] first with
   | Error _ -> () | Ok _ -> fail "adapter accepted an unjudged extra source");
  check bool "inference, adapter, codec and replay publish no Memory or receipt" true
    (before = List.map Fs_compat.load_file_opt paths);
  let range : Current.official_range_id = {receipt_scope="gated-runtime-program";
    after_boundary_line=0;turns=[1,source.turn_ref];unread_messages=[]} in
  let original_messages=first.source_input.messages@second.source_input.messages in
  let committed=Current.apply_program ~keepers_dir ~keeper_id ~now:2_000_000. ~anchor
    ~source:(Current.Official_program_source {range;selected_turns=[1,source.turn_ref,original_messages]})
    ~validate_source:(fun () -> Ok ()) program |> require_memory in
  check_memory_payloads "actual Runtime program publishes its final gated Memory once"
    second.new_claims committed.snapshot.facts;
  check int "only one new durable revision despite two inferred decisions" 2 committed.snapshot.revision;
  let coverage=Current.committed_official_coverage ~keepers_dir ~keeper_id
    ~receipt_scope:range.receipt_scope |> require_memory in
  check bool "original whole turn, not an intermediate source, is consumed" true (coverage=Some range)

let test_ordered_memory_support_is_maintained_between_steps () =
  let premise = fact ~claim:"P supports the deployment conclusion." in
  let alternate = fact ~claim:"Q independently supports the deployment conclusion." in
  let derived claim derivations = Memory.derived ~claim ~category:Memory.Fact ~now:1_000_000.
    ~origin:{Memory.kind=Memory.Authored; trace_id="support-source"} ~derivations |> require_memory in
  let dependent = derived "D relies on P."
    [{Memory.rule_id="from_p"; premise_ids=[Memory.memory_id premise]}] in
  let transitive = derived "F relies on D."
    [{Memory.rule_id="from_d"; premise_ids=[Memory.memory_id dependent]}] in
  let alternative = derived "E has two independent support paths."
    [{Memory.rule_id="from_p"; premise_ids=[Memory.memory_id premise]};
     {Memory.rule_id="from_q"; premise_ids=[Memory.memory_id alternate]}] in
  with_memory_plan_fixture (Some [premise;dependent;transitive;alternate;alternative])
  @@ fun ~keepers_dir ~keeper_id ~snapshot:_ ~source ~plan ~infer ->
  let first = infer source (memory_answer ~dropped:[retire_wire "m1"] "P retired") in
  let after_first = Memory_plan.append plan first |> require_plan in
  check_memory_payloads "alternate proof survives, transitive dependents leave"
    [alternate;alternative] (staged_facts after_first);
  (match Memory_plan.stages after_first with
   | [stage] ->
     check_memory_payloads "intermediate invalidations remain evidence"
       [dependent;transitive] (List.map (fun (i : Current.support_invalidation) -> i.fact) stage.invalidated)
   | _ -> fail "expected one support-maintained stage");
  let second = infer {source with current=Memory_plan.current after_first}
    (memory_answer ~new_claims:[`Assoc ["claim", `String premise.claim; "category", `String "fact"]]
      "P observed again") in
  let result = Memory_plan.append after_first second |> require_plan in
  check_memory_payloads "re-adding P cannot resurrect already invalidated D or F"
    ([alternate;alternative] @ second.new_claims) (staged_facts result);
  check_stored_plan_steps ~keepers_dir ~keeper_id result

let test_ordered_memory_source_binding () =
  with_memory_plan_fixture (Some [current_a;current_b])
  @@ fun ~keepers_dir:_ ~keeper_id:_ ~snapshot ~source ~plan ~infer ->
  let step = infer source inference_answer in
  let make_plan ?(keeper_id=source.keeper_id) ?(turn_ref=source.turn_ref) snapshot =
    Memory_plan.create ~keeper_id ~turn_ref ~snapshot |> require_plan in
  let another_keeper = Masc_test_deps.keeper_id_fixture "another-keeper" in
  Memory_plan.append (make_plan ~keeper_id:another_keeper snapshot) step
  |> expect_plan_error (Memory_plan.Keeper_mismatch {expected=another_keeper; observed=source.keeper_id});
  let another_turn = Ids.Turn_ref.make ~trace_id:"another-trace" ~absolute_turn:7 in
  Memory_plan.append (make_plan ~turn_ref:another_turn snapshot) step
  |> expect_plan_error (Memory_plan.Batch_turn_mismatch {expected=another_turn; observed=source.turn_ref});
  let snapshot = match snapshot with Some snapshot -> snapshot | None -> fail "seed missing" in
  let changed = {current_a with last_seen=current_a.last_seen +. 1.} in
  Memory_plan.append (make_plan (Some {snapshot with facts=[changed;current_b]})) step
  |> expect_plan_error Memory_plan.Current_input_mismatch;
  Memory_plan.create ~keeper_id:source.keeper_id ~turn_ref:source.turn_ref
    ~snapshot:(Some {snapshot with facts=[current_a;changed;current_b]})
  |> expect_plan_error (Memory_plan.Duplicate_current_identity (Memory.memory_id current_a));
  let reordered_input = {source with current=Some {Librarian.facts=[current_b;current_a]}} in
  let reordered_answer = `Assoc ["new_claims", `List [`Assoc
    ["claim", `String "Both original facts were judged in the opposite surrogate order.";
     "category", `String "fact"; "supersedes", `String "m1"; "absorbs", `List [`String "m2"]]];
    "dropped", `List [retire_wire "m1"]; "working_contexts", `List [];
    "working_state", `String "opposite source order"] in
  let reordered_step = infer reordered_input reordered_answer in
  let result = Memory_plan.append plan reordered_step |> require_plan in
  check_memory_payloads "equivalent current sets permit different surrogate order"
    reordered_step.new_claims (staged_facts result);
  match Memory_plan.stages result with
  | [stage] -> check bool "source's surrogate order is retained" true
      (stage.step.source_input.current = reordered_input.current)
  | _ -> fail "expected one reordered stage"

let test_ordered_memory_retains_source_when_gated_target_loses_support () =
  let original = fact ~claim:"an independent source must not disappear into an unsupported target" in
  let premise = fact ~claim:"the target's premise is withdrawn by this message" in
  let target = Memory.derived ~claim:"a held derived target restated by the Librarian"
    ~category:Memory.Fact ~now:1_000_000.
    ~origin:{Memory.kind=Memory.Authored; trace_id="target-source"}
    ~derivations:[{Memory.rule_id="held_target_support"; premise_ids=[Memory.memory_id premise]}]
    |> require_memory in
  with_memory_plan_fixture (Some [original;premise;target])
  @@ fun ~keepers_dir ~keeper_id ~snapshot:_ ~source ~plan ~infer ->
  let step = infer source
    (memory_answer ~new_claims:[`Assoc ["claim", `String target.claim;
      "category", `String "fact"; "absorbs", `List [`String "m1"]]]
      ~dropped:[retire_wire "m2"] "the target loses support") in
  check bool "actual parsing and gate preserve the proposed absorption" true
    (step.absorbed=[{Memory.absorbed=Memory.memory_id original; into=Memory.memory_id target}]);
  let result = Memory_plan.append plan step |> require_plan in
  check_memory_payloads "staged application cannot consume its source into an invalidated destination"
    [original] (staged_facts result);
  check_stored_plan_steps ~keepers_dir ~keeper_id result

let test_ordered_memory_empty_and_repeated_inference () =
  with_memory_plan_fixture None
  @@ fun ~keepers_dir ~keeper_id ~snapshot:_ ~source ~plan ~infer ->
  let paths = inference_store_paths ~keepers_dir ~keeper_id in
  let before = List.map Fs_compat.load_file_opt paths in
  let first = infer source (memory_answer "empty first step") in
  let after_first = Memory_plan.append plan first |> require_plan in
  check bool "accepted empty state is known, not an absent original snapshot" true
    (Memory_plan.current plan = None && Memory_plan.current after_first = Some {Librarian.facts=[]});
  Memory_plan.append after_first first |> expect_plan_error (Memory_plan.Duplicate_step_run first.run_id);
  let stale = infer source (memory_answer "stale missing current") in
  Memory_plan.append after_first stale |> expect_plan_error Memory_plan.Current_input_mismatch;
  let second = infer {source with current=Memory_plan.current after_first} (memory_answer "known empty") in
  let result = Memory_plan.append after_first second |> require_plan in
  check int "rejected append leaves the earlier plan usable" 2 (List.length (Memory_plan.stages result));
  check bool "staging does not create an empty Memory publication" true
    (before = List.map Fs_compat.load_file_opt paths)

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
      , [ test_case "gated Runtime decisions bind exact sources through program replay" `Quick
            test_gated_runtime_program_binding
        ; test_case "named API exhaustion grants Memory floor evidence" `Quick
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
        ; test_case "ordered Memory revisions preserve original decisions and store parity" `Quick
            test_ordered_memory_revision_chain
        ; test_case "ordered Memory support closure prevents later resurrection" `Quick
            test_ordered_memory_support_is_maintained_between_steps
        ; test_case "ordered Memory binds Keeper, source batch and complete fact fields" `Quick
            test_ordered_memory_source_binding
        ; test_case "ordered Memory retains a source when its gated target loses support" `Quick
            test_ordered_memory_retains_source_when_gated_target_loses_support
        ; test_case "ordered Memory distinguishes absent current and repeated inference" `Quick
            test_ordered_memory_empty_and_repeated_inference
        ; test_case "Memory inference retains a gated decision without publishing" `Quick
            test_memory_inference_retains_gated_decision
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
      ; test_case "body deadline reaches HTTP successor and commits Memory" `Quick
          (test_body_timeout_reaches_http_successor ~with_cli:false)
      ; test_case "body deadline reaches HTTP successor before CLI" `Quick
          (test_body_timeout_reaches_http_successor ~with_cli:true)
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
        ; test_case "no CLI declaration preserves the API failure" `Quick
            (test_failure_reaches_journal ~cli_only:false ~cli_slot_ids:[]
              ~answer:(Error (Masc.Fusion_official_client.Setup_failure "must not run")) ~failure:None
              ~kind:Current.Exact_setup_failure ~calls:0)
        ; test_case "CLI admission refusal reaches journal and exact-run projection" `Quick
            (test_failure_reaches_journal ~cli_only:false
              ~cli_slot_ids:["missing-cli-runtime"] ~answer:(Error (Masc.Fusion_official_client.Setup_failure "must not run"))
              ~failure:(Some (Cli.Unknown_runtime {runtime_id = "missing-cli-runtime"}))
              ~kind:Current.Exact_setup_failure ~calls:0)
        ; test_case "CLI domain failure reaches journal and exact-run projection" `Quick
            (fun () -> test_failure_reaches_journal ~cli_only:false
              ~cli_slot_ids:[Fixture.cli_primary_runtime] ~answer:(Ok "{}")
              ~failure:(Some (invalid_domain_failure ()))
              ~kind:Current.Exact_setup_failure ~calls:1 ())
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
        ; test_case "CLI execution failure reaches journal and exact-run projection" `Quick
            (test_failure_reaches_journal ~cli_only:false
              ~cli_slot_ids:[Fixture.cli_primary_runtime] ~answer:(Error (Masc.Fusion_official_client.Setup_failure "synthetic bridge failure"))
              ~failure:(Some (Cli.Execution_failed
                {runtime_id = Fixture.cli_primary_runtime; cause = Masc.Fusion_official_client.Setup_failure "synthetic bridge failure"}))
              ~kind:Current.Exact_setup_failure ~calls:1)
        ; test_case "CLI-only failure reaches journal and exact-run projection" `Quick
            (fun () -> test_failure_reaches_journal ~cli_only:true
              ~cli_slot_ids:[Fixture.cli_primary_runtime] ~answer:(Ok "{}")
              ~failure:(Some (invalid_domain_failure ()))
              ~kind:Current.Exact_execution_failure ~calls:1 ())
        ; test_case "admission worker partitions only actual input capacity refusals" `Quick
            test_admission_worker_requires_actual_input_capacity
        ; test_case "native Codex capacity permits message descent without unread authority" `Quick
            (test_native_capacity_message_descent Native_codex)
        ; test_case "native Claude capacity permits message descent without unread authority" `Quick
            (test_native_capacity_message_descent Native_claude)
        ; test_case "absorb gate capacity refusal splits the admission batch" `Quick
            test_absorb_gate_capacity_refusal_splits_the_admission_batch
        ; test_case "settled explicit candidates commit through exact lane and receipt" `Quick
            (test_explicit_admission_envelope ~deferred:false)
        ; test_case "deferred explicit candidates leave Memory and queue intact" `Quick
            (test_explicit_admission_envelope ~deferred:true)
        ; test_case "transport failure is not a completed evidence deferral" `Quick
            (test_explicit_admission_envelope ~transport_failure:true ~deferred:false)
        ; test_case "settled B commits while preceding A stays deferred" `Quick
            (test_mixed_admission ~depends_on_deferred:false)
        ; test_case "change depending on deferred A has no effects" `Quick
            (test_mixed_admission ~depends_on_deferred:true)
        ; test_case "queued observation sees later retirement before admission" `Quick
            (test_admission_retirement_evidence ~reobserved:false)
        ; test_case "later reobservation may be admitted despite retirement history" `Quick
            (test_admission_retirement_evidence ~reobserved:true)
        ; test_case "unavailable retirement history remains explicit and deferred" `Quick
            test_admission_unavailable_retirement_history
        ; test_case "a later report without capacity evidence keeps the refusal" `Quick
            test_a_later_report_without_capacity_evidence_keeps_the_refusal
        ; test_case
            "CLI prompt drift remains distinct from no CLI declaration"
            `Quick
            test_cli_prompt_drift_is_not_reported_as_no_cli_declaration
        ] )
    ]
;;
