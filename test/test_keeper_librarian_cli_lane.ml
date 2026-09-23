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
  ; goal_context = Masc.Keeper_librarian.No_task
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
  "librarian request projection failed for slot=librarian-cli-unreachable reason=librarian-cli-unreachable: wire_admission_rejected:target_request_rejected"
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
  let runner ~runtime_id ~system_prompt:_ ~output_schema:_ ~prompt =
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
  let runner ~runtime_id ~system_prompt:_ ~output_schema:_ ~prompt:_ =
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
  let runner ~runtime_id ~system_prompt:_ ~output_schema:_ ~prompt:_ =
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
  let runner ~runtime_id ~system_prompt:_ ~output_schema:_ ~prompt:_ =
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
  let runner ~runtime_id ~system_prompt:_ ~output_schema:_ ~prompt:_ =
    attempts := runtime_id :: !attempts;
    Ok "{}"
  in
  (match execute ~net ~clock ~base_path ~runner with
   | Ok _ -> fail "a domain-invalid CLI answer must not be accepted"
   | Error error ->
     check_detail ~api_failure:projection_failure
       ~cli_failure:(invalid_domain_failure ())
       (Runtime.For_testing.classified_error_detail error));
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
  let runner ~runtime_id:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ =
    incr attempts;
    Error (Masc.Fusion_official_client.Setup_failure (Provider_error "synthetic bridge failure"))
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
      ~api_failure:"librarian domain output invalid"
      ~cli_failure:
        (Cli.Execution_failed
           { runtime_id = Fixture.cli_primary_runtime
           ; cause = Masc.Fusion_official_client.Setup_failure
               (Provider_error "synthetic bridge failure")
           })
      (Runtime.For_testing.classified_error_detail error)
;;

let test_invalid_provider_response_does_not_run_cli ?(requires_token_measurement = false) () =
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
          ~source:"librarian non-advanceable terminal"
          [ { Fixture.id = "librarian-invalid-provider-response"
            ; base_url = server.base_url
            } ])
      : Runtime_exact_output_registry.t);
  let cli_calls = ref 0 in
  let runner ~runtime_id:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ =
    incr cli_calls;
    Ok (Yojson.Safe.to_string valid_selection_json)
  in
  let result = execute ~net ~clock ~base_path ~runner in
  check int "provider response came from one HTTP request" 1 (Fixture.post_count server);
  if requires_token_measurement then
    check (list string) "only token measurement reached HTTP; generation did not start"
      [ "/v1/messages/count_tokens" ] (Fixture.request_paths server);
  check int "a non-advanceable terminal does not run CLI" 0 !cli_calls;
  match result with
  | Ok _ -> fail "a CLI answer must not replace the invalid provider response"
  | Error error ->
    check bool "the original execution failure is preserved" true
      (Runtime.For_testing.classified_error_kind error = Current.Exact_execution_failure)
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
  let runner ~runtime_id:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ =
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
  let runner ~runtime_id:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ =
    incr calls;
    Error (Masc.Fusion_official_client.Setup_failure (Provider_error "must not run"))
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
  let runner ~runtime_id ~system_prompt:_ ~output_schema:_ ~prompt:_ =
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
  let runner ~runtime_id:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ =
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

let () =
  run
    "keeper_librarian_cli_lane"
    [ ( "cli lane slots"
      , [ test_case "CLI-only librarian selects memory without an HTTP attempt" `Quick
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
              ~answer:(Error (Masc.Fusion_official_client.Setup_failure (Provider_error "must not run"))) ~failure:None
              ~kind:Current.Exact_setup_failure ~calls:0)
        ; test_case "CLI admission refusal reaches journal and exact-run projection" `Quick
            (test_failure_reaches_journal ~cli_only:false
              ~cli_slot_ids:["missing-cli-runtime"] ~answer:(Error (Masc.Fusion_official_client.Setup_failure (Provider_error "must not run")))
              ~failure:(Some (Cli.Not_an_official_client {runtime_id = "missing-cli-runtime"}))
              ~kind:Current.Exact_setup_failure ~calls:0)
        ; test_case "CLI domain failure reaches journal and exact-run projection" `Quick
            (fun () -> test_failure_reaches_journal ~cli_only:false
              ~cli_slot_ids:[Fixture.cli_primary_runtime] ~answer:(Ok "{}")
              ~failure:(Some (invalid_domain_failure ()))
              ~kind:Current.Exact_setup_failure ~calls:1 ())
        ; test_case "API domain failure kind survives failed CLI fallback" `Quick
            test_domain_failure_kind_survives_failed_cli_slot
        ; test_case "an invalid provider response does not run CLI" `Quick
            (fun () -> test_invalid_provider_response_does_not_run_cli ())
        ; test_case "a dispatched measurement failure does not run CLI" `Quick
            (fun () ->
              test_invalid_provider_response_does_not_run_cli
                ~requires_token_measurement:true ())
        ; test_case "CLI execution failure reaches journal and exact-run projection" `Quick
            (test_failure_reaches_journal ~cli_only:false
              ~cli_slot_ids:[Fixture.cli_primary_runtime] ~answer:(Error (Masc.Fusion_official_client.Setup_failure (Provider_error "synthetic bridge failure")))
              ~failure:(Some (Cli.Execution_failed
                {runtime_id = Fixture.cli_primary_runtime; cause = Masc.Fusion_official_client.Setup_failure
                  (Provider_error "synthetic bridge failure")}))
              ~kind:Current.Exact_setup_failure ~calls:1)
        ; test_case "CLI-only failure reaches journal and exact-run projection" `Quick
            (fun () -> test_failure_reaches_journal ~cli_only:true
              ~cli_slot_ids:[Fixture.cli_primary_runtime] ~answer:(Ok "{}")
              ~failure:(Some (invalid_domain_failure ()))
              ~kind:Current.Exact_execution_failure ~calls:1 ())
        ; test_case
            "CLI prompt drift remains distinct from no CLI declaration"
            `Quick
            test_cli_prompt_drift_is_not_reported_as_no_cli_declaration
        ] )
    ]
;;
