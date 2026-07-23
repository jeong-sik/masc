open Masc

module Fixture = Compaction_exact_output_fixture
module Librarian = Keeper_librarian
module Librarian_runtime = Keeper_librarian_runtime
module Memory_io = Keeper_memory_os_io
module Types = Keeper_memory_os_types

let has_librarian_prompt_root path =
  Sys.file_exists
    (Filename.concat path "config/prompts/keeper.librarian.episode_extraction.md")
;;

let repo_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when has_librarian_prompt_root root -> root
  | _ ->
    let rec ascend path =
      if has_librarian_prompt_root path
      then path
      else (
        let parent = Filename.dirname path in
        if String.equal parent path then Sys.getcwd () else ascend parent)
    in
    ascend (Sys.getcwd ())
;;

let with_prompt_registry f =
  Fun.protect
    ~finally:Prompt_registry.clear
    (fun () ->
      Prompt_registry.clear ();
      Prompt_registry.set_markdown_dir (Filename.concat (repo_root ()) "config/prompts");
      Prompt_defaults.init ();
      f ())
;;

let with_temp_keepers_dir f =
  let marker = Filename.temp_file "librarian-exact-output-" ".tmp" in
  Sys.remove marker;
  Memory_io.For_testing.with_keepers_dir marker (fun () -> f marker)
;;

let text_message text =
  Agent_sdk.Types.make_message
    ~role:Agent_sdk.Types.User
    [ Agent_sdk.Types.Text text ]
;;

let librarian_input trace_id =
  { Librarian.trace_id
  ; generation = 1
  ; messages = [ text_message "Remember the exact-output boundary." ]
  }
;;

let valid_output =
  `Assoc
    [ "episode_summary", `String "OAS exact output succeeded."
    ; ( "claims"
      , `List
          [ `Assoc
              [ "claim", `String "OAS owns exact-output provider admission."
              ; "category", `String "constraint"
              ; "source_turn", `Int 0
              ; "source_tool_call_id", `Null
              ; "claim_id", `String "oas-exact-output-owns-admission"
              ; "claim_kind", `String "durable_knowledge"
              ; "valid_for_days", `Null
              ]
          ] )
    ; "open_items", `List []
    ; "constraints", `List []
    ; "preserved_tool_refs", `List []
    ]
;;

let publish_lane
      ?(supports_response_format_json = true)
      ?(supports_structured_output = false)
      fixtures
  =
  let snapshot =
    Fixture.resolver_snapshot
      ~supports_response_format_json
      ~supports_structured_output
      ~source:"librarian exact-output conformance"
      fixtures
  in
  ignore
    (Fixture.publish_registry
       ~lane_id:Librarian_runtime.exact_lane_id
       ~slot_ids:(List.map (fun (fixture : Fixture.target_fixture) -> fixture.id) fixtures)
       snapshot
      : Runtime_exact_output_registry.t)
;;

let json_object_response_format body =
  match Yojson.Safe.from_string body with
  | `Assoc fields ->
    (match List.assoc_opt "response_format" fields with
     | Some (`Assoc response_format) ->
       (match List.assoc_opt "type" response_format with
        | Some (`String "json_object") -> true
        | _ -> false)
     | _ -> false)
  | _ -> false
;;

let exact_journal_state ~keeper_id =
  let exact_output_dir =
    Memory_io.episodes_dir ~keeper_id
    |> Filename.dirname
    |> fun keeper_dir -> Filename.concat keeper_dir "exact-output"
  in
  let journals =
    exact_output_dir
    |> Sys.readdir
    |> Array.to_list
    |> List.filter (String.equal "librarian-exact-state.json")
  in
  match journals with
  | [ journal ] ->
    let path = Filename.concat exact_output_dir journal in
    let json =
      In_channel.with_open_bin path In_channel.input_all
      |> Yojson.Safe.from_string
    in
    Yojson.Safe.Util.(json |> member "state" |> to_string)
  | _ -> Alcotest.failf "expected one exact journal, got %d" (List.length journals)
;;

let write_exact_journal ~keeper_id ~state =
  let exact_output_dir =
    Memory_io.episodes_dir ~keeper_id
    |> Filename.dirname
    |> fun keeper_dir -> Filename.concat keeper_dir "exact-output"
    |> Keeper_fs.ensure_dir
  in
  let path = Filename.concat exact_output_dir "librarian-exact-state.json" in
  let payload =
    `Assoc
      [ "schema_version", `Int 1
      ; "trace_id", `String "prior-trace"
      ; "generation", `Int 41
      ; "state", `String state
      ]
    |> Yojson.Safe.to_string
  in
  Out_channel.with_open_bin path (fun channel -> output_string channel payload)
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

let test_json_only_target_is_admitted_and_persisted () =
  with_prompt_registry (fun () ->
    with_temp_keepers_dir (fun _ ->
      run_eio (fun ~sw ~net ~clock ->
        let response = Fixture.openai_response valid_output in
        let server = Fixture.start_server ~sw ~net ~clock (Fixture.Reply response) in
        let slot : Fixture.target_fixture =
          { id = "librarian-json-only"; base_url = server.base_url }
        in
        publish_lane [ slot ];
        let keeper_id = "librarian-json-only-keeper" in
        match
          Librarian_runtime.extract_and_append_with_exact_output
            ~clock
            ~net
            ~keeper_id
            (librarian_input "trace-json-only")
        with
        | Error error -> Alcotest.fail error
        | Ok episode ->
          Alcotest.(check int) "one claim" 1 (List.length episode.Types.claims);
          Alcotest.(check int) "one provider request" 1 (Fixture.post_count server);
          (match Fixture.request_bodies server with
           | [ body ] ->
             Alcotest.(check bool)
               "OAS selected json_object for a JSON-only target"
               true
               (json_object_response_format body)
           | bodies ->
             Alcotest.failf "expected one request body, got %d" (List.length bodies));
          Alcotest.(check int)
            "episode persisted"
            1
            (List.length (Memory_io.read_events_tail ~keeper_id ~n:10));
          Alcotest.(check int)
            "fact persisted"
            1
            (List.length (Memory_io.read_facts_tail ~keeper_id ~n:10));
          Alcotest.(check string)
            "exact receipt journal reached domain-valid terminal"
            "domain_valid"
            (exact_journal_state ~keeper_id))))
;;

let test_missing_json_capability_fails_before_dispatch () =
  with_prompt_registry (fun () ->
  with_temp_keepers_dir (fun _ ->
    run_eio (fun ~sw ~net ~clock ->
      let response = Fixture.openai_response valid_output in
      let server = Fixture.start_server ~sw ~net ~clock (Fixture.Reply response) in
      let slot : Fixture.target_fixture =
        { id = "librarian-no-json"; base_url = server.base_url }
      in
      publish_lane
        ~supports_response_format_json:false
        ~supports_structured_output:false
        [ slot ];
      match
        Librarian_runtime.extract_with_exact_output_classified
          ~clock
          ~net
          ~keeper_id:"librarian-no-json-keeper"
          ~generation:1
          (librarian_input "trace-no-json")
      with
      | Error (Librarian_runtime.Exact_setup_failed _) ->
        Alcotest.(check int) "no provider request" 0 (Fixture.post_count server)
      | Error error ->
        Alcotest.failf
          "expected typed exact setup failure, got %s"
          (Librarian_runtime.extraction_error_to_string error)
      | Ok _ -> Alcotest.fail "target without a JSON guarantee must fail closed")))
;;

let test_domain_invalid_output_does_not_fail_over () =
  with_prompt_registry (fun () ->
  with_temp_keepers_dir (fun _ ->
    run_eio (fun ~sw ~net ~clock ->
      let invalid_server =
        Fixture.start_server
          ~sw
          ~net
          ~clock
          (Fixture.Reply
             (Fixture.openai_response
                (`Assoc [ "episode_summary", `String "missing claims" ])))
      in
      let valid_server =
        Fixture.start_server
          ~sw
          ~net
          ~clock
          (Fixture.Reply (Fixture.openai_response valid_output))
      in
      let slots : Fixture.target_fixture list =
        [ { id = "librarian-domain-invalid"; base_url = invalid_server.base_url }
        ; { id = "librarian-domain-valid"; base_url = valid_server.base_url }
        ]
      in
      publish_lane slots;
      match
        Librarian_runtime.extract_with_exact_output_classified
          ~clock
          ~net
          ~keeper_id:"librarian-domain-invalid-keeper"
          ~generation:1
          (librarian_input "trace-domain-invalid")
      with
      | Error (Librarian_runtime.Provider_unparseable_response _) ->
        Alcotest.(check int)
          "first exact candidate dispatched once"
          1
          (Fixture.post_count invalid_server);
        Alcotest.(check int)
          "domain validation is terminal"
          0
          (Fixture.post_count valid_server);
        Alcotest.(check string)
          "domain-invalid terminal is durable"
          "domain_invalid"
          (exact_journal_state ~keeper_id:"librarian-domain-invalid-keeper")
      | Error error ->
        Alcotest.failf
          "expected domain validation failure, got %s"
          (Librarian_runtime.extraction_error_to_string error)
      | Ok _ -> Alcotest.fail "domain-invalid episode must not be accepted")))
;;

let test_unsettled_restart_state_fails_before_dispatch () =
  with_prompt_registry (fun () ->
  with_temp_keepers_dir (fun _ ->
    run_eio (fun ~sw ~net ~clock ->
      let server =
        Fixture.start_server
          ~sw
          ~net
          ~clock
          (Fixture.Reply (Fixture.openai_response valid_output))
      in
      let slot : Fixture.target_fixture =
        { id = "librarian-restart-guard"; base_url = server.base_url }
      in
      publish_lane [ slot ];
      let keeper_id = "librarian-restart-guard-keeper" in
      write_exact_journal ~keeper_id ~state:"candidate_bound";
      match
        Librarian_runtime.extract_with_exact_output_classified
          ~clock
          ~net
          ~keeper_id
          ~generation:42
          (librarian_input "trace-after-restart")
      with
      | Error
          (Librarian_runtime.Exact_setup_failed
             (Librarian_runtime.Exact_previous_attempt_unsettled
                { state = "candidate_bound"
                ; trace_id = "prior-trace"
                ; generation = 41
                })) ->
        Alcotest.(check int) "restart guard dispatched nothing" 0 (Fixture.post_count server)
      | Error error ->
        Alcotest.failf
          "expected typed unsettled-attempt guard, got %s"
          (Librarian_runtime.extraction_error_to_string error)
      | Ok _ -> Alcotest.fail "unsettled prior exact attempt must fail closed")))
;;

let test_oas_success_restart_state_starts_fresh_flow () =
  with_prompt_registry (fun () ->
  with_temp_keepers_dir (fun _ ->
    run_eio (fun ~sw ~net ~clock ->
      let server =
        Fixture.start_server
          ~sw
          ~net
          ~clock
          (Fixture.Reply (Fixture.openai_response valid_output))
      in
      let slot : Fixture.target_fixture =
        { id = "librarian-oas-success-restart"; base_url = server.base_url }
      in
      publish_lane [ slot ];
      let keeper_id = "librarian-oas-success-restart-keeper" in
      write_exact_journal ~keeper_id ~state:"oas_success";
      match
        Librarian_runtime.extract_with_exact_output_classified
          ~clock
          ~net
          ~keeper_id
          ~generation:42
          (librarian_input "trace-after-oas-success")
      with
      | Error error ->
        Alcotest.failf
          "oas-success restart should start a fresh flow, got %s"
          (Librarian_runtime.extraction_error_to_string error)
      | Ok _ ->
        Alcotest.(check int)
          "fresh flow dispatched once"
          1
          (Fixture.post_count server);
        Alcotest.(check string)
          "fresh flow reached domain-valid terminal"
          "domain_valid"
          (exact_journal_state ~keeper_id))))
;;

let test_missing_clock_fails_before_dispatch () =
  with_prompt_registry (fun () ->
  with_temp_keepers_dir (fun _ ->
    run_eio (fun ~sw ~net ~clock ->
      let server =
        Fixture.start_server
          ~sw
          ~net
          ~clock
          (Fixture.Reply (Fixture.openai_response valid_output))
      in
      let slot : Fixture.target_fixture =
        { id = "librarian-clock-guard"; base_url = server.base_url }
      in
      publish_lane [ slot ];
      match
        Librarian_runtime.extract_with_exact_output_classified
          ~net
          ~keeper_id:"librarian-clock-guard-keeper"
          ~generation:1
          (librarian_input "trace-clock-guard")
      with
      | Error Librarian_runtime.Provider_clock_unavailable ->
        Alcotest.(check int) "missing clock dispatched nothing" 0 (Fixture.post_count server)
      | Error error ->
        Alcotest.failf
          "expected typed missing-clock error, got %s"
          (Librarian_runtime.extraction_error_to_string error)
      | Ok _ -> Alcotest.fail "missing clock must fail closed")))
;;

let test_fact_upsert_failure_does_not_publish_episode () =
  with_prompt_registry (fun () ->
  with_temp_keepers_dir (fun _ ->
    run_eio (fun ~sw ~net ~clock ->
      let server =
        Fixture.start_server
          ~sw
          ~net
          ~clock
          (Fixture.Reply (Fixture.openai_response valid_output))
      in
      let slot : Fixture.target_fixture =
        { id = "librarian-fact-write-failure"; base_url = server.base_url }
      in
      publish_lane [ slot ];
      let keeper_id = "librarian-fact-write-failure-keeper" in
      Unix.mkdir (Memory_io.facts_path ~keeper_id) 0o700;
      match
        Librarian_runtime.extract_and_append_with_exact_output
          ~clock
          ~net
          ~keeper_id
          (librarian_input "trace-fact-write-failure")
      with
      | Error error ->
        Alcotest.(check bool)
          "typed write error is returned"
          true
          (String.starts_with ~prefix:"memory os fact upsert failed:" error);
        Alcotest.(check int)
          "episode commit marker was not published"
          0
          (List.length (Memory_io.read_events_tail ~keeper_id ~n:10))
      | Ok _ -> Alcotest.fail "fact upsert failure must block episode publication")))
;;

let test_zero_dispatch_failure_advances_to_next_candidate () =
  with_prompt_registry (fun () ->
  with_temp_keepers_dir (fun _ ->
    run_eio (fun ~sw ~net ~clock ->
      let valid_server =
        Fixture.start_server
          ~sw
          ~net
          ~clock
          (Fixture.Reply (Fixture.openai_response valid_output))
      in
      let slots : Fixture.target_fixture list =
        [ { id = "librarian-unreachable"; base_url = "http://127.0.0.1:1" }
        ; { id = "librarian-failover-success"; base_url = valid_server.base_url }
        ]
      in
      publish_lane slots;
      let keeper_id = "librarian-safe-failover-keeper" in
      match
        Librarian_runtime.extract_with_exact_output
          ~clock
          ~net
          ~keeper_id
          ~generation:1
          (librarian_input "trace-safe-failover")
      with
      | Error error -> Alcotest.fail error
      | Ok _ ->
        Alcotest.(check int)
          "next candidate received one request"
          1
          (Fixture.post_count valid_server);
        Alcotest.(check string)
          "failover receipt journal reached terminal"
          "domain_valid"
          (exact_journal_state ~keeper_id))))
;;

let () =
  Alcotest.run
    "librarian_exact_output_conformance"
    [ ( "exact output"
      , [ Alcotest.test_case
            "JSON-only target is admitted and persisted"
            `Quick
            test_json_only_target_is_admitted_and_persisted
        ; Alcotest.test_case
            "missing JSON capability fails before dispatch"
            `Quick
            test_missing_json_capability_fails_before_dispatch
        ; Alcotest.test_case
            "domain-invalid output does not fail over"
            `Quick
            test_domain_invalid_output_does_not_fail_over
        ; Alcotest.test_case
            "unsettled restart state fails before dispatch"
            `Quick
            test_unsettled_restart_state_fails_before_dispatch
        ; Alcotest.test_case
            "OAS success restart state starts a fresh flow"
            `Quick
            test_oas_success_restart_state_starts_fresh_flow
        ; Alcotest.test_case
            "missing clock fails before dispatch"
            `Quick
            test_missing_clock_fails_before_dispatch
        ; Alcotest.test_case
            "fact upsert failure does not publish episode"
            `Quick
            test_fact_upsert_failure_does_not_publish_episode
        ; Alcotest.test_case
            "zero-dispatch failure advances to next candidate"
            `Quick
            test_zero_dispatch_failure_advances_to_next_candidate
        ] )
    ]
;;
