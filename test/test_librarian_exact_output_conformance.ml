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

let exact_flow_base_path_ref = ref None

let exact_flow_base_path () =
  match !exact_flow_base_path_ref with
  | Some base_path -> base_path
  | None -> failwith "exact-flow test base path is unavailable outside its scope"
;;

let with_temp_keepers_dir f =
  let marker = Filename.temp_file "librarian-exact-output-" ".tmp" in
  Sys.remove marker;
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:marker
  in
  let previous = !exact_flow_base_path_ref in
  exact_flow_base_path_ref := Some marker;
  Fun.protect
    ~finally:(fun () -> exact_flow_base_path_ref := previous)
    (fun () ->
       Memory_io.For_testing.with_keepers_dir keepers_dir (fun () ->
         f keepers_dir))
;;

let ensure_registered_keeper keeper_id =
  match Masc.Keeper_registry.get ~base_path:(exact_flow_base_path ()) keeper_id with
  | Some _ -> ()
  | None ->
    let meta =
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [ "name", `String keeper_id
          ; "trace_id", `String ("trace-" ^ keeper_id)
          ])
      |> Result.get_ok
    in
    ignore
      (Masc.Keeper_registry.register_offline
         ~base_path:(exact_flow_base_path ())
         keeper_id
         meta)
;;

let extract_with_exact_output_classified
      ?clock
      ~net
      ~keeper_id
      ~generation
      input
  =
  ensure_registered_keeper keeper_id;
  Librarian_runtime.extract_with_exact_output_classified
    ?clock
    ~base_path:(exact_flow_base_path ())
    ~net
    ~keeper_id
    ~generation
    input
;;

let extract_with_exact_output
      ?clock
      ~net
      ~keeper_id
      ~generation
      input
  =
  match
    extract_with_exact_output_classified
      ?clock
      ~net
      ~keeper_id
      ~generation
      input
  with
  | Ok episode -> Ok episode
  | Error error ->
    Error (Librarian_runtime.extraction_error_to_string error)
;;

let extract_and_append_with_exact_output ?clock ~net ~keeper_id input =
  ensure_registered_keeper keeper_id;
  match
    Librarian_runtime.extract_and_append_with_exact_output_classified
      ?clock
      ~base_path:(exact_flow_base_path ())
      ~generation_floor:1
      ~net
      ~keeper_id
      input
  with
  | Ok episode -> Ok episode
  | Error error ->
    Error (Librarian_runtime.extraction_error_to_string error)
;;

let text_message text =
  Agent_sdk.Types.make_message
    ~role:Agent_sdk.Types.User
    [ Agent_sdk.Types.Text text ]
;;

let tool_result_message ~tool_use_id text : Agent_sdk.Types.message =
  { role = Agent_sdk.Types.Assistant
  ; content =
      [ Agent_sdk.Types.ToolResult
          { tool_use_id
          ; content = text
          ; outcome = Agent_sdk.Types.Tool_succeeded
          ; json = None
          ; content_blocks = None
          }
      ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let librarian_input trace_id =
  { Librarian.trace_id
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
              ]
          ] )
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

let has_response_format body =
  match Yojson.Safe.from_string body with
  | `Assoc fields -> Option.is_some (List.assoc_opt "response_format" fields)
  | _ -> false
;;

let exact_journal_path_for_keepers_dir
      ~keepers_dir
      ~keeper_id
      ~trace_id
      ~generation
  =
  let exact_trace_dir =
    Filename.concat keepers_dir keeper_id
    |> fun keeper_dir -> Filename.concat keeper_dir "exact-output"
    |> fun exact_output_dir ->
    Filename.concat
      exact_output_dir
      (trace_id
       |> Digestif.SHA256.digest_string
       |> Digestif.SHA256.to_hex)
  in
  Filename.concat
    exact_trace_dir
    (Printf.sprintf "librarian-exact-state-%d.json" generation)
;;

let exact_journal_path ~keeper_id ~trace_id ~generation =
  let keepers_dir =
    Memory_io.facts_path ~keeper_id
    |> Filename.dirname
  in
  exact_journal_path_for_keepers_dir
    ~keepers_dir
    ~keeper_id
    ~trace_id
    ~generation
;;

let exact_journal_state ~keeper_id ~trace_id ~generation =
  let path = exact_journal_path ~keeper_id ~trace_id ~generation in
  let json =
    In_channel.with_open_bin path In_channel.input_all
    |> Yojson.Safe.from_string
  in
  Yojson.Safe.Util.(json |> member "state" |> to_string)
;;

let write_exact_journal_json ~keeper_id ~trace_id ~generation json =
  let path = exact_journal_path ~keeper_id ~trace_id ~generation in
  let (_ : string) =
    Filename.dirname path
    |> Keeper_fs.ensure_dir
  in
  let payload = Yojson.Safe.to_string json in
  Out_channel.with_open_bin path (fun channel -> output_string channel payload)
;;

let write_exact_journal ~keeper_id ~trace_id ~generation ~state =
  write_exact_journal_json
    ~keeper_id
    ~trace_id
    ~generation
    (`Assoc
       [ "trace_id", `String trace_id
       ; "generation", `Int generation
       ; "state", `String state
       ])
;;

let exact_candidate_journal ~trace_id ~generation =
  `Assoc
    [ "trace_id", `String trace_id
    ; "generation", `Int generation
    ; "state", `String "candidate_bound"
    ; ( "candidate"
      , `Assoc
          [ "candidate_id", `String "restart-bound-candidate"
          ; ( "receipt"
            , `Assoc
                [ "call_id", `String "restart-bound-call"
                ; "http_status", `Null
                ; "plan_fingerprint", `String "restart-bound-plan"
                ; "request_body_sha256", `String "restart-bound-request"
                ; "catalog_generation", `String "restart-bound-catalog"
                ; "catalog_evidence_sha256", `String "restart-bound-evidence"
                ; "target_identity", `String "restart-bound-target"
                ] )
          ] )
    ]
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

let test_prompt_only_target_is_admitted_and_persisted () =
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
          extract_and_append_with_exact_output
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
               "Json_syntax stays prompt-only"
               false
               (has_response_format body)
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
            (exact_journal_state
               ~keeper_id
               ~trace_id:"trace-json-only"
               ~generation:1))))
;;

let test_production_write_uses_explicit_base_path () =
  with_prompt_registry (fun () ->
    with_temp_keepers_dir (fun keepers_dir ->
      let decoy_keepers_dir =
        Filename.temp_file "librarian-exact-output-decoy-" ".tmp"
      in
      Sys.remove decoy_keepers_dir;
      Memory_io.For_testing.with_keepers_dir decoy_keepers_dir (fun () ->
        run_eio (fun ~sw ~net ~clock ->
          let response = Fixture.openai_response valid_output in
          let server =
            Fixture.start_server ~sw ~net ~clock (Fixture.Reply response)
          in
          publish_lane
            [ { id = "librarian-base-path-authority"
              ; base_url = server.base_url
              }
            ];
          let keeper_id = "librarian-base-path-authority-keeper" in
          let trace_id = "trace-base-path-authority" in
          match
            extract_and_append_with_exact_output
              ~clock
              ~net
              ~keeper_id
              (librarian_input trace_id)
          with
          | Error error -> Alcotest.fail error
          | Ok episode ->
            Alcotest.(check int)
              "explicit base path owns the fact"
              1
              (List.length
                 (Memory_io.read_facts_all_for_keepers_dir
                    ~keepers_dir
                    ~keeper_id));
            Alcotest.(check int)
              "ambient override receives no fact"
              0
              (List.length
                 (Memory_io.read_facts_all_for_keepers_dir
                    ~keepers_dir:decoy_keepers_dir
                    ~keeper_id));
            Alcotest.(check int)
              "explicit base path owns the event"
              1
              (List.length
                 (Memory_io.read_events_tail_for_keepers_dir
                    ~keepers_dir
                    ~keeper_id
                    ~n:10));
            Alcotest.(check int)
              "ambient override receives no event"
              0
              (List.length
                 (Memory_io.read_events_tail_for_keepers_dir
                    ~keepers_dir:decoy_keepers_dir
                    ~keeper_id
                    ~n:10));
            Alcotest.(check bool)
              "explicit base path owns the exact journal"
              true
              (Sys.file_exists
                 (exact_journal_path_for_keepers_dir
                    ~keepers_dir
                    ~keeper_id
                    ~trace_id
                    ~generation:episode.Types.generation));
            Alcotest.(check bool)
              "ambient override receives no exact journal"
              false
              (Sys.file_exists
                 (exact_journal_path_for_keepers_dir
                    ~keepers_dir:decoy_keepers_dir
                    ~keeper_id
                    ~trace_id
                    ~generation:episode.Types.generation))))))
;;

let test_prompt_only_target_needs_no_wire_json_capability () =
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
        extract_and_append_with_exact_output
          ~clock
          ~net
          ~keeper_id:"librarian-no-json-keeper"
          (librarian_input "trace-no-json")
      with
      | Ok _ ->
        Alcotest.(check int) "one provider request" 1 (Fixture.post_count server);
        (match Fixture.request_bodies server with
         | [ body ] ->
           Alcotest.(check bool)
             "no provider-native response format"
             false
             (has_response_format body)
         | bodies ->
           Alcotest.failf "expected one request body, got %d" (List.length bodies))
      | Error error -> Alcotest.fail error)))
;;

let test_domain_invalid_output_advances_to_declared_successor () =
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
        extract_with_exact_output_classified
          ~clock
          ~net
          ~keeper_id:"librarian-domain-invalid-keeper"
          ~generation:1
          (librarian_input "trace-domain-invalid")
      with
      | Ok episode ->
        Alcotest.(check int)
          "first exact candidate dispatched once"
          1
          (Fixture.post_count invalid_server);
        Alcotest.(check int)
          "declared successor dispatched once"
          1
          (Fixture.post_count valid_server);
        Alcotest.(check string)
          "successor terminal is durable"
          "domain_valid"
          (exact_journal_state
             ~keeper_id:"librarian-domain-invalid-keeper"
             ~trace_id:"trace-domain-invalid"
             ~generation:1);
        Alcotest.(check int)
          "successor produced one claim"
          1
          (List.length episode.Types.claims)
      | Error error ->
        Alcotest.failf
          "declared domain successor failed: %s"
          (Librarian_runtime.extraction_error_to_string error))))
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
      write_exact_journal
        ~keeper_id
        ~trace_id:"trace-after-restart"
        ~generation:42
        ~state:"flow_started";
      match
        extract_with_exact_output_classified
          ~clock
          ~net
          ~keeper_id
          ~generation:42
          (librarian_input "trace-after-restart")
      with
      | Error error
        when Librarian_runtime.extraction_error_kind error
             = Librarian_runtime.Exact_setup_failure ->
        Alcotest.(check int) "restart guard dispatched nothing" 0 (Fixture.post_count server)
      | Error error ->
        Alcotest.failf
          "expected typed unsettled-attempt guard, got %s"
          (Librarian_runtime.extraction_error_to_string error)
      | Ok _ -> Alcotest.fail "unsettled prior exact attempt must fail closed")))
;;

let test_production_restart_reuses_active_generation_before_dispatch () =
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
      publish_lane
        [ { id = "librarian-production-restart"; base_url = server.base_url } ];
      let cases =
        [ ( "flow_started"
          , fun ~trace_id ~generation ->
              `Assoc
                [ "trace_id", `String trace_id
                ; "generation", `Int generation
                ; "state", `String "flow_started"
                ] )
        ; "candidate_bound", exact_candidate_journal
        ]
      in
      List.iteri
        (fun index (state, journal) ->
           let keeper_id =
             Printf.sprintf "librarian-production-restart-%d" index
           in
           let trace_id =
             Printf.sprintf "trace-production-restart-%d" index
           in
           ensure_registered_keeper keeper_id;
           let generation =
             Memory_io.next_generation_with_floor
               ~floor:42
               ~keeper_id
               ~trace_id
           in
           Alcotest.(check int)
             (state ^ " reserved generation")
             42
             generation;
           write_exact_journal_json
             ~keeper_id
             ~trace_id
             ~generation
             (journal ~trace_id ~generation);
           (match
              Librarian_runtime.extract_and_append_with_exact_output_classified
                ~clock
                ~base_path:(exact_flow_base_path ())
                ~generation_floor:1
                ~net
                ~keeper_id
                (librarian_input trace_id)
            with
            | Error error
              when Librarian_runtime.extraction_error_kind error
                   = Librarian_runtime.Exact_setup_failure ->
              ()
            | Error error ->
              Alcotest.failf
                "%s: expected typed restart fence, got %s"
                state
                (Librarian_runtime.extraction_error_to_string error)
            | Ok _ ->
              Alcotest.failf
                "%s: production restart bypassed its active generation"
                state);
           Alcotest.(check int)
             (state ^ " did not reserve past active generation")
             43
             (Memory_io.next_generation ~keeper_id ~trace_id))
        cases;
      Alcotest.(check int)
        "production restart dispatched nothing"
        0
        (Fixture.post_count server))))
;;

let test_terminal_restart_state_starts_fresh_flow () =
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
      let keeper_id = "librarian-terminal-restart-keeper" in
      write_exact_journal
        ~keeper_id
        ~trace_id:"trace-after-terminal"
        ~generation:42
        ~state:"execution_terminal";
      match
        extract_with_exact_output_classified
          ~clock
          ~net
          ~keeper_id
          ~generation:42
          (librarian_input "trace-after-terminal")
      with
      | Error error ->
        Alcotest.failf
          "terminal restart should start a fresh flow, got %s"
          (Librarian_runtime.extraction_error_to_string error)
      | Ok _ ->
        Alcotest.(check int)
          "fresh flow dispatched once"
          1
          (Fixture.post_count server);
        Alcotest.(check string)
          "fresh flow reached domain-valid terminal"
          "domain_valid"
          (exact_journal_state
             ~keeper_id
             ~trace_id:"trace-after-terminal"
             ~generation:42))))
;;

let test_production_terminal_restart_reserves_new_generation () =
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
      publish_lane
        [ { id = "librarian-production-terminal-restart"
          ; base_url = server.base_url
          }
        ];
      let keeper_id = "librarian-production-terminal-restart-keeper" in
      let trace_id = "trace-production-terminal-restart" in
      ensure_registered_keeper keeper_id;
      let generation =
        Memory_io.next_generation_with_floor
          ~floor:42
          ~keeper_id
          ~trace_id
      in
      write_exact_journal
        ~keeper_id
        ~trace_id
        ~generation
        ~state:"execution_terminal";
      match
        Librarian_runtime.extract_and_append_with_exact_output_classified
          ~clock
          ~base_path:(exact_flow_base_path ())
          ~generation_floor:1
          ~net
          ~keeper_id
          (librarian_input trace_id)
      with
      | Error error ->
        Alcotest.failf
          "terminal production restart failed: %s"
          (Librarian_runtime.extraction_error_to_string error)
      | Ok episode ->
        Alcotest.(check int)
          "terminal restart advances generation"
          43
          episode.Types.generation;
        Alcotest.(check int)
          "terminal restart dispatched once"
          1
          (Fixture.post_count server);
        Alcotest.(check string)
          "new generation reached domain-valid terminal"
          "domain_valid"
          (exact_journal_state
             ~keeper_id
             ~trace_id
             ~generation:43))))
;;

let test_invalid_current_journal_fails_before_dispatch () =
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
        { id = "librarian-invalid-current-journal"; base_url = server.base_url }
      in
      publish_lane [ slot ];
      let cases =
        [ ( "missing trace"
          , fun ~trace_id:_ ~generation ->
              `Assoc
                [ "generation", `Int generation
                ; "state", `String "execution_terminal"
                ] )
        ; ( "mismatched trace"
          , fun ~trace_id:_ ~generation ->
              `Assoc
                [ "trace_id", `String "different-trace"
                ; "generation", `Int generation
                ; "state", `String "execution_terminal"
                ] )
        ; ( "mismatched generation"
          , fun ~trace_id ~generation ->
              `Assoc
                [ "trace_id", `String trace_id
                ; "generation", `Int (generation + 1)
                ; "state", `String "execution_terminal"
                ] )
        ; ( "unknown field"
          , fun ~trace_id ~generation ->
              `Assoc
                [ "trace_id", `String trace_id
                ; "generation", `Int generation
                ; "state", `String "execution_terminal"
                ; "legacy", `Bool true
                ] )
        ; ( "unknown state"
          , fun ~trace_id ~generation ->
              `Assoc
                [ "trace_id", `String trace_id
                ; "generation", `Int generation
                ; "state", `String "future_state"
                ] )
        ; ( "duplicate state"
          , fun ~trace_id ~generation ->
              `Assoc
                [ "trace_id", `String trace_id
                ; "generation", `Int generation
                ; "state", `String "execution_terminal"
                ; "state", `String "execution_terminal"
                ] )
        ; ( "malformed candidate evidence"
          , fun ~trace_id ~generation ->
              `Assoc
                [ "trace_id", `String trace_id
                ; "generation", `Int generation
                ; "state", `String "domain_valid"
                ; "candidate", `Assoc []
                ] )
        ]
      in
      List.iteri
        (fun index (label, journal) ->
           let keeper_id =
             Printf.sprintf "librarian-invalid-current-journal-%d" index
           in
           let trace_id = Printf.sprintf "trace-invalid-current-journal-%d" index in
           let generation = 42 in
           write_exact_journal_json
             ~keeper_id
             ~trace_id
             ~generation
             (journal ~trace_id ~generation);
           match
             extract_with_exact_output_classified
               ~clock
               ~net
               ~keeper_id
               ~generation
               (librarian_input trace_id)
           with
           | Error error
             when Librarian_runtime.extraction_error_kind error
                  = Librarian_runtime.Exact_setup_failure ->
             ()
           | Error error ->
             Alcotest.failf
               "%s: expected typed journal setup failure, got %s"
               label
               (Librarian_runtime.extraction_error_to_string error)
           | Ok _ ->
             Alcotest.failf
               "%s: invalid current journal must fail before dispatch"
               label)
        cases;
      Alcotest.(check int)
        "invalid current journals dispatched nothing"
        0
        (Fixture.post_count server))))
;;

let test_noncanonical_journal_identity_fails_production_before_dispatch () =
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
        publish_lane
          [ { id = "librarian-noncanonical-journal"
            ; base_url = server.base_url
            }
          ];
        let keeper_id = "librarian-noncanonical-journal-keeper" in
        let trace_id = "trace-noncanonical-journal" in
        write_exact_journal_json
          ~keeper_id
          ~trace_id
          ~generation:42
          (`Assoc
             [ "trace_id", `String trace_id
             ; "generation", `Int 43
             ; "state", `String "flow_started"
             ]);
        match
          Librarian_runtime.extract_and_append_with_exact_output_classified
            ~clock
            ~base_path:(exact_flow_base_path ())
            ~generation_floor:1
            ~net
            ~keeper_id
            (librarian_input trace_id)
        with
        | Error error
          when Librarian_runtime.extraction_error_kind error
               = Librarian_runtime.Exact_setup_failure ->
          Alcotest.(check int)
            "noncanonical journal dispatched nothing"
            0
            (Fixture.post_count server)
        | Error error ->
          Alcotest.failf
            "expected typed setup failure, got %s"
            (Librarian_runtime.extraction_error_to_string error)
        | Ok _ ->
          Alcotest.fail
            "production ignored a journal whose file identity disagreed with its payload")))
;;

let test_corrupt_unrelated_trace_does_not_block_current_trace () =
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
        publish_lane
          [ { id = "librarian-unrelated-trace-isolation"
            ; base_url = server.base_url
            }
          ];
        let keeper_id = "librarian-unrelated-trace-isolation-keeper" in
        write_exact_journal_json
          ~keeper_id
          ~trace_id:"trace-corrupt-unrelated"
          ~generation:9
          (`Assoc
             [ "trace_id", `String "trace-corrupt-unrelated"
             ; "generation", `Int 9
             ; "state", `String "unknown_state"
             ]);
        match
          extract_and_append_with_exact_output
            ~clock
            ~net
            ~keeper_id
            (librarian_input "trace-current-isolated")
        with
        | Error error ->
          Alcotest.failf
            "an unrelated corrupt trace blocked the current trace: %s"
            error
        | Ok _ ->
          Alcotest.(check int)
            "current trace dispatched once"
            1
            (Fixture.post_count server))))
;;

let test_prompt_slice_and_provenance_share_one_input () =
  with_prompt_registry (fun () ->
  with_temp_keepers_dir (fun _ ->
    run_eio (fun ~sw ~net ~clock ->
      let prompt_capacity =
        Librarian_runtime.max_messages ()
        * Librarian_runtime.cadence_turns ()
      in
      if prompt_capacity < 1
      then Alcotest.fail "librarian prompt capacity must be positive";
      let tool_use_id = "tool-at-first-retained-message" in
      let output =
        `Assoc
          [ "episode_summary", `String "The retained tool result is cited."
          ; ( "claims"
            , `List
                [ `Assoc
                    [ "claim", `String "The retained tool result remains attributable."
                    ; "category", `String "fact"
                    ; "source_turn", `Int 0
                    ; "source_tool_call_id", `String tool_use_id
                    ; "claim_id", `Null
                    ]
                ] )
          ]
      in
      let server =
        Fixture.start_server
          ~sw
          ~net
          ~clock
          (Fixture.Reply (Fixture.openai_response output))
      in
      publish_lane
        [ { id = "librarian-prompt-provenance-snapshot"
          ; base_url = server.base_url
          }
        ];
      let retained_tail =
        List.init
          (prompt_capacity - 1)
          (fun index -> text_message (Printf.sprintf "retained-%d" index))
      in
      let input : Librarian.input =
        { trace_id = "trace-prompt-provenance-snapshot"
        ; messages =
            text_message "dropped-before-prompt"
            :: tool_result_message
                 ~tool_use_id
                 "The configured source remains visible."
            :: retained_tail
        }
      in
      match
        extract_with_exact_output
          ~clock
          ~net
          ~keeper_id:"librarian-prompt-provenance-snapshot-keeper"
          ~generation:1
          input
      with
      | Error error ->
        Alcotest.failf
          "prompt-local provenance was validated against another input: %s"
          error
      | Ok episode ->
        (match episode.Types.claims with
         | [ fact ] ->
           Alcotest.(check int)
             "source turn refers to the first retained message"
             0
             fact.Types.source.turn;
           Alcotest.(check (option string))
             "source tool id belongs to that retained message"
             (Some tool_use_id)
             fact.Types.source.tool_call_id
         | claims ->
           Alcotest.failf "expected one claim, got %d" (List.length claims));
        Alcotest.(check int)
          "single exact-output dispatch"
          1
          (Fixture.post_count server))))
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
        extract_with_exact_output_classified
          ~net
          ~keeper_id:"librarian-clock-guard-keeper"
          ~generation:1
          (librarian_input "trace-clock-guard")
      with
      | Error error
        when Librarian_runtime.extraction_error_kind error
             = Librarian_runtime.Execution_clock_unavailable ->
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
        extract_and_append_with_exact_output
          ~clock
          ~net
          ~keeper_id
          (librarian_input "trace-fact-write-failure")
      with
      | Error error ->
        Alcotest.(check bool)
          "typed write error is returned"
          true
          (String.starts_with
             ~prefix:"memory os publication failed phase=facts:"
             error);
        Alcotest.(check int)
          "episode commit marker was not published"
          0
          (List.length (Memory_io.read_events_tail ~keeper_id ~n:10))
      | Ok _ -> Alcotest.fail "fact upsert failure must block episode publication")))
;;

let test_episode_publication_failure_is_typed () =
  with_prompt_registry (fun () ->
    with_temp_keepers_dir (fun keepers_dir ->
      run_eio (fun ~sw ~net ~clock ->
        let server =
          Fixture.start_server
            ~sw
            ~net
            ~clock
            (Fixture.Reply (Fixture.openai_response valid_output))
        in
        publish_lane
          [ { id = "librarian-episode-write-failure"
            ; base_url = server.base_url
            }
          ];
        let keeper_id = "librarian-episode-write-failure-keeper" in
        let keeper_dir =
          Filename.concat keepers_dir keeper_id
          |> Keeper_fs.ensure_dir
        in
        Out_channel.with_open_bin
          (Filename.concat keeper_dir "episodes")
          (fun channel -> output_string channel "not-a-directory");
        match
          extract_and_append_with_exact_output
            ~clock
            ~net
            ~keeper_id
            (librarian_input "trace-episode-write-failure")
        with
        | Error error ->
          Alcotest.(check bool)
            "episode failure keeps its publication phase"
            true
            (String.starts_with
               ~prefix:"memory os publication failed phase=episode:"
               error);
          Alcotest.(check int)
            "facts were already written before the episode failure"
            1
            (List.length
               (Memory_io.read_facts_all_for_keepers_dir
                  ~keepers_dir
                  ~keeper_id))
        | Ok _ ->
          Alcotest.fail "episode publication failure escaped its typed result")))
;;

let test_event_publication_failure_is_typed () =
  with_prompt_registry (fun () ->
    with_temp_keepers_dir (fun keepers_dir ->
      run_eio (fun ~sw ~net ~clock ->
        let server =
          Fixture.start_server
            ~sw
            ~net
            ~clock
            (Fixture.Reply (Fixture.openai_response valid_output))
        in
        publish_lane
          [ { id = "librarian-event-write-failure"
            ; base_url = server.base_url
            }
          ];
        let keeper_id = "librarian-event-write-failure-keeper" in
        let keeper_dir =
          Filename.concat keepers_dir keeper_id
          |> Keeper_fs.ensure_dir
        in
        Unix.mkdir
          (Memory_io.events_path_for_keepers_dir
             ~keepers_dir
             ~keeper_id)
          0o700;
        match
          extract_and_append_with_exact_output
            ~clock
            ~net
            ~keeper_id
            (librarian_input "trace-event-write-failure")
        with
        | Error error ->
          Alcotest.(check bool)
            "event failure keeps its publication phase"
            true
            (String.starts_with
               ~prefix:"memory os publication failed phase=event:"
               error);
          Alcotest.(check int)
            "facts were already written before the event failure"
            1
            (List.length
               (Memory_io.read_facts_all_for_keepers_dir
                  ~keepers_dir
                  ~keeper_id));
          let episode_dir = Filename.concat keeper_dir "episodes" in
          Alcotest.(check int)
            "episode was already written before the event failure"
            1
            (Sys.readdir episode_dir
             |> Array.to_list
             |> List.filter (fun name -> Filename.check_suffix name ".json")
             |> List.length)
        | Ok _ ->
          Alcotest.fail "event publication failure escaped its typed result")))
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
        extract_with_exact_output
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
          (exact_journal_state
             ~keeper_id
             ~trace_id:"trace-safe-failover"
             ~generation:1))))
;;

let test_owner_replacement_does_not_invalidate_memory_observation () =
  with_prompt_registry (fun () ->
  with_temp_keepers_dir (fun _ ->
    run_eio (fun ~sw ~net ~clock ->
      let keeper_id = "librarian-owner-replaced-keeper" in
      ensure_registered_keeper keeper_id;
      let old_entry =
        match
          Keeper_registry.get
            ~base_path:(exact_flow_base_path ())
            keeper_id
        with
        | Some entry -> entry
        | None -> Alcotest.fail "librarian owner was not registered"
      in
      let replace_owner () =
        (match Keeper_registry.unregister_exact old_entry with
         | Keeper_registry.Exact_unregistered -> ()
         | _ -> Alcotest.fail "librarian old owner was not fenced");
        let replacement_meta =
          Masc_test_deps.meta_of_json_fixture
            (`Assoc
              [ "name", `String keeper_id
              ; "trace_id", `String "trace-librarian-owner-replacement"
              ])
          |> Result.get_ok
        in
        ignore
          (Keeper_registry.register_offline
             ~base_path:(exact_flow_base_path ())
             keeper_id
             replacement_meta)
      in
      let server =
        Fixture.start_server
          ~on_request_before_reply:replace_owner
          ~sw
          ~net
          ~clock
          (Fixture.Reply (Fixture.openai_response valid_output))
      in
      publish_lane
        [ { id = "librarian-owner-replaced"; base_url = server.base_url } ];
      (match
         extract_with_exact_output_classified
           ~clock
           ~net
           ~keeper_id
           ~generation:1
           (librarian_input "trace-librarian-owner-replaced")
       with
       | Ok _ ->
         Alcotest.(check int)
           "network dispatch completed once"
           1
           (Fixture.post_count server);
         Alcotest.(check string)
           "in-flight memory observation reaches its own terminal"
           "domain_valid"
           (exact_journal_state
              ~keeper_id
              ~trace_id:"trace-librarian-owner-replaced"
              ~generation:1)
       | Error error ->
         Alcotest.failf
           "owner replacement invalidated an in-flight memory observation: %s"
           (Librarian_runtime.extraction_error_to_string error));
      let successor =
        Fixture.start_server
          ~sw
          ~net
          ~clock
          (Fixture.Reply (Fixture.openai_response valid_output))
      in
      publish_lane
        [ { id = "librarian-owner-successor"; base_url = successor.base_url } ];
      (match
         extract_with_exact_output_classified
           ~clock
           ~net
           ~keeper_id
           ~generation:2
           (librarian_input "trace-librarian-owner-replaced")
       with
       | Ok _ ->
         Alcotest.(check int)
           "new generation dispatched once"
           1
           (Fixture.post_count successor);
         Alcotest.(check string)
           "new generation reached terminal"
           "domain_valid"
           (exact_journal_state
              ~keeper_id
              ~trace_id:"trace-librarian-owner-replaced"
              ~generation:2)
       | Error error ->
         Alcotest.failf
           "completed observation blocked the new generation: %s"
           (Librarian_runtime.extraction_error_to_string error)))))
;;

let () =
  Alcotest.run
    "librarian_exact_output_conformance"
    [ ( "exact output"
      , [ Alcotest.test_case
            "prompt-only target is admitted and persisted"
            `Quick
            test_prompt_only_target_is_admitted_and_persisted
        ; Alcotest.test_case
            "prompt-only target needs no wire JSON capability"
            `Quick
            test_prompt_only_target_needs_no_wire_json_capability
        ; Alcotest.test_case
            "production write uses explicit base path"
            `Quick
            test_production_write_uses_explicit_base_path
        ; Alcotest.test_case
            "domain-invalid output advances to declared successor"
            `Quick
            test_domain_invalid_output_advances_to_declared_successor
        ; Alcotest.test_case
            "unsettled restart state fails before dispatch"
            `Quick
            test_unsettled_restart_state_fails_before_dispatch
        ; Alcotest.test_case
            "production restart reuses active generation before dispatch"
            `Quick
            test_production_restart_reuses_active_generation_before_dispatch
        ; Alcotest.test_case
            "terminal restart state starts a fresh flow"
            `Quick
            test_terminal_restart_state_starts_fresh_flow
        ; Alcotest.test_case
            "production terminal restart reserves new generation"
            `Quick
            test_production_terminal_restart_reserves_new_generation
        ; Alcotest.test_case
            "invalid current journal fails before dispatch"
            `Quick
            test_invalid_current_journal_fails_before_dispatch
        ; Alcotest.test_case
            "noncanonical journal identity fails production before dispatch"
            `Quick
            test_noncanonical_journal_identity_fails_production_before_dispatch
        ; Alcotest.test_case
            "corrupt unrelated trace does not block current trace"
            `Quick
            test_corrupt_unrelated_trace_does_not_block_current_trace
        ; Alcotest.test_case
            "prompt slice and provenance share one input"
            `Quick
            test_prompt_slice_and_provenance_share_one_input
        ; Alcotest.test_case
            "missing clock fails before dispatch"
            `Quick
            test_missing_clock_fails_before_dispatch
        ; Alcotest.test_case
            "fact upsert failure does not publish episode"
            `Quick
            test_fact_upsert_failure_does_not_publish_episode
        ; Alcotest.test_case
            "episode publication failure is typed"
            `Quick
            test_episode_publication_failure_is_typed
        ; Alcotest.test_case
            "event publication failure is typed"
            `Quick
            test_event_publication_failure_is_typed
        ; Alcotest.test_case
            "zero-dispatch failure advances to next candidate"
            `Quick
            test_zero_dispatch_failure_advances_to_next_candidate
        ; Alcotest.test_case
            "owner replacement preserves in-flight memory observation"
            `Quick
            test_owner_replacement_does_not_invalidate_memory_observation
        ] )
    ]
;;
