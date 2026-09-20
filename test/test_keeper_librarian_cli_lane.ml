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
    Runtime.For_testing.execute_exact_output_classified
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
    check string
      "the answering slot is the cli runtime id"
      Fixture.cli_primary_runtime
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
    check string "accepted slot owns selection" Fixture.cli_secondary_runtime slot;
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
  | Ok ((selection, output), slot) ->
    check (list string) "projection refusal still walks declared CLI slots"
      [Fixture.cli_primary_runtime; Fixture.cli_secondary_runtime] !attempts;
    check string "the valid CLI answer owns the result" Fixture.cli_secondary_runtime slot;
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
    Error "synthetic bridge failure"
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
           ; detail = "synthetic bridge failure"
           })
      (Runtime.For_testing.classified_error_detail error)
;;

let test_failure_reaches_journal
      ~cli_only
      ~cli_slot_ids
      ~answer
      ~failure
      ~kind
      ?detail_contains
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
  Runtime.run_best_effort ~trigger:Runtime.Queue_changed ~cli_runner:runner
    ~base_path ~keepers_dir ~keeper_id ~expected_revision:None (input ());
  check int "only admitted CLI slots reach the runner" calls !attempts;
  let api_failure = if cli_only then None else Some projection_failure in
  (match Current.read_journal_tail ~keepers_dir ~keeper_id ~limit:1 with
   | [Ok (Current.Journal_failed { detail; kind = actual_kind; cadence_deferred; _ })] ->
     check_detail ?api_failure ?cli_failure:failure detail;
     Option.iter
       (fun expected ->
          check bool
            "journal names the transport declaration failure"
            true
            (Astring.String.is_infix ~affix:expected detail))
       detail_contains;
     check bool "journal keeps the original failure kind" true (actual_kind = kind);
     check bool "failure retains the existing cadence policy" true cadence_deferred
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
    Error "must not run"
  in
  match
    Runtime.For_testing.execute_exact_output_classified
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

let () =
  run
    "keeper_librarian_cli_lane"
    [ ( "cli lane slots"
      , [ test_case "CLI-only librarian selects memory without an HTTP attempt" `Quick
          (fun () -> test_cli_slot_answers_after_catalog_exhaustion ~cli_only:true ())
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
              ~answer:(Error "must not run") ~failure:None
              ~kind:Current.Exact_setup_failure ~calls:0)
        ; test_case "a lane with no transport reports setup failure" `Quick
            (test_failure_reaches_journal ~cli_only:true ~cli_slot_ids:[]
              ~answer:(Error "must not run") ~failure:None
              ~detail_contains:"declares no API or official-client slots"
              ~kind:Current.Exact_setup_failure ~calls:0)
        ; test_case "CLI admission refusal reaches journal and exact-run projection" `Quick
            (test_failure_reaches_journal ~cli_only:false
              ~cli_slot_ids:["missing-cli-runtime"] ~answer:(Error "must not run")
              ~failure:(Some (Cli.Not_an_official_client {runtime_id = "missing-cli-runtime"}))
              ~kind:Current.Exact_setup_failure ~calls:0)
        ; test_case "CLI domain failure reaches journal and exact-run projection" `Quick
            (fun () -> test_failure_reaches_journal ~cli_only:false
              ~cli_slot_ids:[Fixture.cli_primary_runtime] ~answer:(Ok "{}")
              ~failure:(Some (invalid_domain_failure ()))
              ~kind:Current.Exact_setup_failure ~calls:1 ())
        ; test_case "API domain failure kind survives failed CLI fallback" `Quick
            test_domain_failure_kind_survives_failed_cli_slot
        ; test_case "CLI execution failure reaches journal and exact-run projection" `Quick
            (test_failure_reaches_journal ~cli_only:false
              ~cli_slot_ids:[Fixture.cli_primary_runtime] ~answer:(Error "synthetic bridge failure")
              ~failure:(Some (Cli.Execution_failed
                {runtime_id = Fixture.cli_primary_runtime; detail = "synthetic bridge failure"}))
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
