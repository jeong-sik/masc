open Alcotest

module EO = Agent_core.Exact_output
module F = Exact_output_fixture
module Gate = Masc.Keeper_gate
module Q = Masc.Keeper_approval_queue
module QT = Keeper_approval_queue_rules_types
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
  Masc.Keeper_registry.For_testing.clear ();
  match Q.install_persistence ~base_path with
  | Ok _ -> ()
  | Error error -> fail (Q.install_error_to_string error)
;;

let ensure_registered_keeper ~base_path keeper_name =
  match Masc.Keeper_registry.get ~base_path keeper_name with
  | Some _ -> ()
  | None ->
    let meta =
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [ "name", `String keeper_name
          ; "trace_id", `String ("trace-" ^ keeper_name)
          ])
      |> Result.get_ok
    in
    ignore
      (Masc.Keeper_registry.register_offline
         ~base_path
         keeper_name
         meta)
;;

let pending_entry
      ?(input_tag = "default")
      ?(keeper_name = "keeper")
      ?(include_request_context = true)
      ~base_path
      ()
  =
  let request_context =
    `Assoc
      [ ( "initial"
        , `Assoc
            [ "history_messages", `List [ `String "older turn" ]
            ; "user_message", `String "inspect the exact requested operation"
            ; "dynamic_context", `String "current context"
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
        ?request_context:
          (if include_request_context then Some request_context else None)
        ()
    with
    | Ok submission -> submission.approval_id
    | Error error -> fail (Q.storage_error_to_string error)
  in
  (match Q.mark_summary_pending ~id with
   | Ok true -> ()
   | Ok false -> fail "summary did not enter pending state"
   | Error error -> fail (Q.summary_transition_error_to_string error));
  match Q.For_testing.get_pending_entry_unchecked ~id with
  | Some entry ->
    ensure_registered_keeper ~base_path entry.keeper_name;
    entry
  | None -> fail "pending approval disappeared"
;;

let publish_lane ?(cli_slot_ids = []) slot_ids snapshot =
  match
    Runtime.publish_exact_output_registry
      ~lanes:[ { Runtime_schema.id = Worker.For_testing.lane_id; slot_ids; cli_slot_ids } ]
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

let require_executed = function
  | Worker.Executed -> ()
  | Worker.Identity_unbound_blocked ->
    fail "registered HITL exact-flow owner stopped before binding an identity"
  | Worker.Exact_rejection_blocked _ ->
    fail "registered HITL exact-flow owner hit a deterministic exact rejection"
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

let exact_queue_ops
      ?bind_writer
      ?release_writer
      ?complete_writer
      ?quarantine_writer
      ?after_bind
      ()
  =
  let bind =
    Option.map
      (fun save_file_atomic_strict_staged ->
         Q.For_testing.bind_summary_exact_attempt_with_writer
           ~save_file_atomic_strict_staged)
      bind_writer
  in
  let release_before_dispatch =
    Option.map
      (fun save_file_atomic_strict_staged ->
         Q.For_testing.release_summary_exact_attempt_before_dispatch_with_writer
           ~save_file_atomic_strict_staged)
      release_writer
  in
  let complete =
    Option.map
      (fun save_file_atomic_strict_staged ->
         Q.For_testing.complete_summary_exact_attempt_with_writer
           ~save_file_atomic_strict_staged)
      complete_writer
  in
  let quarantine =
    Option.map
      (fun save_file_atomic_strict_staged ->
         Q.For_testing.quarantine_summary_exact_attempt_with_writer
           ~save_file_atomic_strict_staged)
      quarantine_writer
  in
  Worker.For_testing.make_exact_queue_ops
    ?bind
    ?release_before_dispatch
    ?complete
    ?quarantine
    ?after_bind
    ()
;;

let[@inline never] raise_injected_cancellation expected_backtrace payload =
  try raise (Eio.Cancel.Cancelled payload) with
  | Eio.Cancel.Cancelled _ as cancellation ->
    let backtrace = Printexc.get_raw_backtrace () in
    expected_backtrace := Some backtrace;
    Printexc.raise_with_backtrace cancellation backtrace
;;

let check_backtrace_starts_at_origin label expected observed =
  let expected = Printexc.raw_backtrace_to_string expected in
  let observed = Printexc.raw_backtrace_to_string observed in
  check bool label true (Astring.String.is_prefix ~affix:expected observed)
;;

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
    [ "approve", QT.Approve; "deny", QT.Deny; "require_human", QT.Require_human ]
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

(* The live shape, 2026-08-27: request_context.initial.history_messages[] with
   content_blocks[] carrying a Keeper's own reasoning beside what it did. *)
let context_with_thinking =
  `Assoc
    [ ( "initial"
      , `Assoc
          [ ( "history_messages"
            , `List
                [ `Assoc
                    [ "role", `String "assistant"
                    ; ( "content_blocks"
                      , `List
                          [ `Assoc
                              [ "type", `String "thinking"
                              ; "thinking", `String "I MUST STOP this immediately"
                              ]
                          ; `Assoc
                              [ "type", `String "text"; "text", `String "posting" ]
                          ] )
                    ]
                ; `Assoc
                    [ "role", `String "tool"
                    ; ( "content_blocks"
                      , `List
                          [ `Assoc
                              [ "type", `String "tool_result"
                              ; "content", `String "ok"
                              ]
                          ] )
                    ]
                ] )
          ; "user_message", `String "go"
          ] )
    ; "completed_tool_calls", `List []
    ]

let block_types bundle =
  let open Yojson.Safe.Util in
  bundle
  |> member "request_context"
  |> member "initial"
  |> member "history_messages"
  |> to_list
  |> List.concat_map (fun message ->
       match message |> member "content_blocks" with
       | `List blocks ->
         List.map (fun block -> block |> member "type" |> to_string) blocks
       | _ -> [])

let test_the_judge_is_not_shown_the_keepers_reasoning () =
  with_temp_dir "hitl-thinking" @@ fun base_path ->
  install_queue base_path;
  let entry = pending_entry ~base_path () in
  let bundle =
    Worker.For_testing.build_context_bundle
      ~entry:{ entry with request_context = Some context_with_thinking }
  in
  let open Yojson.Safe.Util in
  check (list string) "what the Keeper did survives; what it told itself does not"
    [ "text"; "tool_result" ] (block_types bundle);
  (* Reported, so a judge reading a thin bundle can tell trimming from a turn
     that never reasoned. *)
  check yojson "and the judge is told how much was cut" (`Int 1)
    (bundle |> member "thinking_blocks_omitted")

let test_a_turn_without_reasoning_reports_nothing_cut () =
  with_temp_dir "hitl-no-thinking" @@ fun base_path ->
  install_queue base_path;
  let entry = pending_entry ~base_path () in
  let bundle = Worker.For_testing.build_context_bundle ~entry in
  let open Yojson.Safe.Util in
  check yojson "nothing was cut" (`Int 0)
    (bundle |> member "thinking_blocks_omitted")

let test_a_context_of_another_shape_is_carried_through () =
  (* Guessing at the shape is how a field nobody meant to touch gets
     rewritten. A context without the one path this knows is left alone. *)
  with_temp_dir "hitl-other-shape" @@ fun base_path ->
  install_queue base_path;
  let entry = pending_entry ~base_path () in
  let foreign = `Assoc [ "something_else", `List [ `String "kept" ] ] in
  let bundle =
    Worker.For_testing.build_context_bundle
      ~entry:{ entry with request_context = Some foreign }
  in
  let open Yojson.Safe.Util in
  check yojson "carried through unchanged" foreign
    (bundle |> member "request_context")

(* Through the real knob, so the wiring is covered and not just the trimming.
   Restored afterwards: a leaked runtime param would decide the next test. *)
let thinking_blocks_key = "keeper.hitl.thinking_blocks"
let hitl_concurrency_key = "keeper.hitl.max_concurrent_per_keeper"

let with_thinking_blocks_kept n f =
  let restore () =
    ignore (Masc.Runtime_params.clear_by_key thinking_blocks_key)
  in
  (match Masc.Runtime_params.set_by_key thinking_blocks_key (`Int n) with
   | Ok () -> ()
   | Error detail -> Alcotest.failf "could not set the knob: %s" detail);
  Fun.protect ~finally:restore f

let with_hitl_concurrency n f =
  let restore () =
    ignore (Masc.Runtime_params.clear_by_key hitl_concurrency_key)
  in
  (match Masc.Runtime_params.set_by_key hitl_concurrency_key (`Int n) with
   | Ok () -> ()
   | Error detail -> Alcotest.failf "could not set HITL concurrency: %s" detail);
  Fun.protect ~finally:restore f

let test_the_newest_reasoning_can_be_kept () =
  (* The knob exists because the two sides pull opposite ways: the bundle is
     smaller without reasoning, and the judge's deny rationales cite the
     constraints a Keeper wrote for itself. Newest, because that is where a
     self-imposed constraint is. *)
  with_temp_dir "hitl-thinking-keep" @@ fun base_path ->
  install_queue base_path;
  let entry = pending_entry ~base_path () in
  with_thinking_blocks_kept 1 @@ fun () ->
  let bundle =
    Worker.For_testing.build_context_bundle
      ~entry:{ entry with request_context = Some context_with_thinking }
  in
  let open Yojson.Safe.Util in
  check (list string) "the reasoning survives beside what was done"
    [ "thinking"; "text"; "tool_result" ] (block_types bundle);
  check yojson "and nothing is reported as cut" (`Int 0)
    (bundle |> member "thinking_blocks_omitted")

let test_the_budget_keeps_the_newest_not_the_first () =
  with_temp_dir "hitl-thinking-newest" @@ fun base_path ->
  install_queue base_path;
  let entry = pending_entry ~base_path () in
  let thinking text =
    `Assoc [ "type", `String "thinking"; "thinking", `String text ]
  in
  let context =
    `Assoc
      [ ( "initial"
        , `Assoc
            [ ( "history_messages"
              , `List
                  [ `Assoc
                      [ "role", `String "assistant"
                      ; "content_blocks", `List [ thinking "old" ]
                      ]
                  ; `Assoc
                      [ "role", `String "assistant"
                      ; "content_blocks", `List [ thinking "newest" ]
                      ]
                  ] )
            ] )
      ]
  in
  with_thinking_blocks_kept 1 @@ fun () ->
  let bundle =
    Worker.For_testing.build_context_bundle
      ~entry:{ entry with request_context = Some context }
  in
  let open Yojson.Safe.Util in
  let kept =
    bundle
    |> member "request_context"
    |> member "initial"
    |> member "history_messages"
    |> to_list
    |> List.concat_map (fun m ->
         match m |> member "content_blocks" with
         | `List blocks -> List.map (fun b -> b |> member "thinking" |> to_string) blocks
         | _ -> [])
  in
  check (list string) "the one it just wrote down" [ "newest" ] kept;
  check yojson "and the older one is reported as cut" (`Int 1)
    (bundle |> member "thinking_blocks_omitted")

let test_context_bundle_is_exact () =
  with_temp_dir "hitl-context" @@ fun base_path ->
  install_queue base_path;
  let entry = pending_entry ~base_path () in
  let bundle = Worker.For_testing.build_context_bundle ~entry in
  let open Yojson.Safe.Util in
  check yojson "exact input" entry.input (bundle |> member "input");
  check yojson
    "exact outer-turn context"
    (Option.get entry.request_context)
    (bundle |> member "request_context");
  check yojson "context is whole" (`Bool false) (bundle |> member "partial_context");
  check yojson "no derived classification" `Null (bundle |> member "classification")
;;

let write_registered_masc_catalog base_path =
  let config_dir = Filename.concat base_path ".masc/config" in
  Fs_compat.mkdir_p config_dir;
  Fs_compat.save_file
    (Filename.concat config_dir "repositories.toml")
    "[repository.masc]\nname = \"MASC\"\nurl = \"https://github.com/jeong-sik/masc.git\"\nlocal_path = \"workspace/yousleepwhen/masc\"\naliases = []\ndefault_branch = \"main\"\nkeepers = []\nstatus = \"Active\"\nauto_sync = false\nsync_interval = 300\ncreated_at = 1700000000\nupdated_at = 1700000000\n"
;;

let execute_gate_input ~cwd argv =
  `Assoc
    [ "schema", `String "masc.keeper_gate.request.v1"
    ; "input", `Assoc [ "cwd", `String cwd; "argv", `List (List.map (fun value -> `String value) argv) ]
    ; "cwd", `String cwd
    ; "sandbox_profile", `String "docker"
    ; "sandbox_target", `String "docker:masc-keeper-sandbox:local"
    ]
;;

let test_host_context_identifies_registered_clone_and_destination_state () =
  with_temp_dir "hitl-host-context" @@ fun base_path ->
  install_queue base_path;
  write_registered_masc_catalog base_path;
  let entry = pending_entry ~base_path () in
  let cwd = Filename.concat base_path ".masc/playground/docker/fixture" in
  Fs_compat.mkdir_p cwd;
  let input =
    execute_gate_input
      ~cwd
      [ "git"
      ; "clone"
      ; "--depth"
      ; "1"
      ; "https://github.com/jeong-sik/masc.git"
      ; "repos/masc"
      ]
  in
  let entry =
    { entry with
      tool_name = "tool_execute"
    ; input
    ; task_id = Some "task-636"
    ; goal_id = Some "goal-keeper-can-work"
    }
  in
  let open Yojson.Safe.Util in
  let host_context bundle = bundle |> member "host_context" in
  let catalog_match bundle =
    host_context bundle
    |> member "execution"
    |> member "repository_references"
    |> member "items"
    |> to_list
    |> List.hd
    |> member "catalog_match"
  in
  let first = Worker.For_testing.build_context_bundle ~entry in
  check string "host provenance" "host_observed"
    (host_context first |> member "provenance" |> to_string);
  check string "durable task link" "task-636"
    (host_context first
     |> member "task_link"
     |> member "request"
     |> member "task_id"
     |> to_string);
  check string "durable goal link" "goal-keeper-can-work"
    (host_context first
     |> member "task_link"
     |> member "request"
     |> member "goal_id"
     |> to_string);
  check string "canonical repository id" "github.com_jeong-sik_masc"
    (host_context first
     |> member "execution"
     |> member "repository_references"
     |> member "items"
     |> to_list
     |> List.hd
     |> member "canonical_id"
     |> to_string);
  check string "catalog identity" "registered"
    (catalog_match first |> member "state" |> to_string);
  check string "catalog repository id" "masc"
    (catalog_match first |> member "repository_id" |> to_string);
  check string "resolved destination is initially absent" "absent"
    (host_context first
     |> member "execution"
     |> member "git_clone_destination"
     |> member "state"
     |> to_string);
  Fs_compat.mkdir_p (Filename.concat cwd "repos/masc");
  let after_create = Worker.For_testing.build_context_bundle ~entry in
  check string "the same resolved destination is now present" "present"
    (host_context after_create
     |> member "execution"
     |> member "git_clone_destination"
     |> member "state"
     |> to_string)
;;

let test_host_context_reports_a_missing_durable_task_link () =
  run_eio @@ fun ~sw:_ ~net:_ ~clock:_ ->
  with_temp_dir "hitl-host-task-link" @@ fun base_path ->
  install_queue base_path;
  let config = Masc.Workspace.default_config base_path in
  ignore (Masc.Workspace.init config ~agent_name:(Some "fixture-keeper"));
  Fun.protect
    ~finally:(fun () -> ignore (Masc.Workspace.reset config))
    (fun () ->
       ignore
         (Masc.Workspace.add_task
            config
            ~title:"Context task"
            ~priority:1
            ~description:"");
       ignore
         (Masc.Workspace.claim_task
            config
            ~agent_name:"fixture-keeper"
            ~task_id:"task-001");
       let entry = pending_entry ~base_path ~keeper_name:"fixture-keeper" () in
       let open Yojson.Safe.Util in
       let task_link =
         Worker.For_testing.build_context_bundle ~entry
         |> member "host_context"
         |> member "task_link"
       in
       check string "request/backlog disagreement is explicit" "request_link_missing"
         (task_link |> member "state" |> to_string);
       check (list string) "the authoritative active task is still visible"
         [ "task-001" ]
         (task_link |> member "active_task_ids" |> to_list |> List.map to_string))
;;

let test_missing_context_is_reported_as_partial () =
  with_temp_dir "hitl-missing-context" @@ fun base_path ->
  install_queue base_path;
  let entry = pending_entry ~base_path () in
  let bundle =
    Worker.For_testing.build_context_bundle
      ~entry:{ entry with request_context = None }
  in
  let open Yojson.Safe.Util in
  check yojson "context is partial" (`Bool true) (bundle |> member "partial_context");
  check yojson "no fabricated context" `Null (bundle |> member "request_context");
  check yojson "request identity survives" entry.input (bundle |> member "input");
  check yojson
    "keeper identity survives"
    (`String entry.keeper_name)
    (bundle |> member "keeper_name");
  check yojson
    "tool identity survives"
    (`String entry.tool_name)
    (bundle |> member "tool_name")
;;

let test_missing_context_does_not_change_flow_admission () =
  with_temp_dir "hitl-context-admission" @@ fun base_path ->
  install_queue base_path;
  let entry = pending_entry ~base_path () in
  let outcome candidate =
    match Worker.For_testing.prepare_flow ~entry:candidate with
    | Ok _ -> Ok ()
    | Error detail -> Error detail
  in
  check
    (result unit string)
    "outer-turn context presence does not decide admission"
    (outcome entry)
    (outcome { entry with request_context = None })
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

let test_json_syntax_request_is_prompt_only_and_carries_canonical_domain_schema () =
  run_eio @@ fun ~sw ~net ~clock ->
  with_temp_dir "hitl-json-syntax-contract" @@ fun base_path ->
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
         [ "hitl-json-syntax-contract" ]
         (F.resolver_snapshot
            ~supports_response_format_json:false
            ~supports_structured_output:false
            ~source:"hitl-json-syntax-contract"
            [ { id = "hitl-json-syntax-contract"; base_url = server.base_url } ]);
       let entry = pending_entry ~base_path () in
       (* The sink is what carries the branch to the run registry. Running the
          real flow inside one proves the worker's own [record_outcome] calls
          reach it -- a direct call to the codec would not. *)
       let observed_branch = ref None in
       Worker.For_testing.with_outcome_sink observed_branch (fun () ->
         Worker.For_testing.execute_prepared_flow
           ~net
           ~clock
           ~on_summary:(fun _ -> ())
           (prepare_exn entry)
         |> require_executed);
       check bool
         "the flow recorded which branch it took"
         true
         (!observed_branch <> None);
       let request_body =
         match F.request_bodies server with
         | [ body ] -> Yojson.Safe.from_string body
         | bodies ->
           failf "expected one prompt-only request, got %d" (List.length bodies)
       in
       let open Yojson.Safe.Util in
       (match request_body with
        | `Assoc fields ->
          check
            bool
            "JSON syntax request has no provider response_format"
            false
            (List.mem_assoc "response_format" fields)
        | _ -> fail "prompt-only request body is not an object");
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
  | EO.Candidate_admitted candidate -> candidate.visit.identity.candidate_id
  | EO.Candidate_rejected rejection ->
    (EO.candidate_rejection_identity rejection).candidate_id
;;

let candidate_id (identity : EO.flow_candidate_identity) = identity.candidate_id
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
         "immutable candidate order"
         [ "hitl-first"; "hitl-second" ]
         (List.map candidate_id evidence.declared_candidate_snapshot);
       check
         (list string)
         "admission is deferred until execution"
         []
         (List.map admission_id evidence.admissions);
       let delivered = ref None in
       Worker.For_testing.execute_prepared_flow
         ~net
         ~clock
         ~on_summary:(fun summary -> delivered := Some summary)
         prepared
       |> require_executed;
       check
         (list string)
         "only the reached candidate is admitted"
         [ "hitl-first" ]
         ((Worker.For_testing.flow_evidence prepared).admissions
          |> List.map admission_id);
       check int "first candidate posted once" 1 (F.post_count first);
       check int "second candidate not used" 0 (F.post_count second);
       (match Q.For_testing.get_pending_entry_unchecked ~id:entry.id with
        | Some
            { exact_attempt =
                QT.Exact_bound
                  { slot_id = "hitl-first"; status = QT.Exact_completed; _ }
            ; summary_status = QT.Summary_available _
            ; _
            } ->
          ()
        | _ -> fail "successful flow did not durably complete its exact binding");
       check bool "validated summary delivered" true (Option.is_some !delivered);
       Worker.For_testing.execute_prepared_flow
         ~net
         ~clock
         ~on_summary:(fun _ -> fail "replay delivered a second summary")
         prepared
       |> require_executed;
       check int "replay made no second POST" 1 (F.post_count first))
;;

let test_keeper_preference_reorders_the_hitl_lane () =
  run_eio @@ fun ~sw ~net ~clock ->
  with_temp_dir "hitl-per-keeper-preference" @@ fun base_path ->
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
       let preferred =
         F.start_server
           ~sw
           ~net
           ~clock
           (F.Reply (F.openai_response (judgment_json "deny")))
       in
       publish_lane
         [ "hitl-default"; "hitl-preferred" ]
         (F.resolver_snapshot
            ~source:"hitl-per-keeper-preference"
            [ { id = "hitl-default"; base_url = first.base_url }
            ; { id = "hitl-preferred"; base_url = preferred.base_url }
            ]);
       (match
          Masc.Keeper_exact_lane_preference.set
            (Masc.Workspace.default_config base_path)
            ~actor:"test"
            ~keeper_name:"keeper"
            ~lane_id:Worker.For_testing.lane_id
            (Some "hitl-preferred")
        with
        | Ok _ -> ()
        | Error detail -> fail detail);
       let entry = pending_entry ~base_path () in
       let prepared = prepare_exn entry in
       let declared =
         Worker.For_testing.flow_evidence prepared
         |> fun evidence ->
         List.map candidate_id evidence.declared_candidate_snapshot
       in
       check
         (list string)
         "Keeper preference first, declared failover retained"
         [ "hitl-preferred"; "hitl-default" ]
         declared)
;;

let test_predispatch_failure_advances_only_to_agent_core_successor () =
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
       let prepared = prepare_exn entry in
       Worker.For_testing.execute_prepared_flow
         ~net
         ~clock
         ~on_summary:(fun _ -> ())
         prepared
       |> require_executed;
       check int "AGENT_CORE-selected successor posted once" 1 (F.post_count successor);
       (match (Worker.For_testing.flow_evidence prepared).advances with
        | [ advance ] ->
          check string
            "advance targets the frozen successor"
            "hitl-successor"
            advance.next.identity.candidate_id;
          (match advance.failed with
           | EO.Flow_advance_execution_failed { candidate; cause; _ } ->
             check string
               "advance retains the failed candidate"
               "hitl-unreachable"
               candidate.visit.identity.candidate_id;
             check bool
               "advance retains the typed transport failure"
               true
               (cause = EO.Completion_failed)
           | EO.Flow_advance_candidate_rejected _ ->
             fail "transport failure was recorded as a candidate rejection")
        | _ -> fail "exactly one typed AGENT_CORE advance should be retained");
       match Q.For_testing.get_pending_entry_unchecked ~id:entry.id with
       | Some
           { exact_attempt =
               QT.Exact_bound
                 { slot_id = "hitl-successor"; status = QT.Exact_completed; _ }
           ; _
           } ->
         ()
       | _ -> fail "pre-dispatch failover did not complete the predetermined successor")
;;

let test_cancellation_between_candidates_terminalizes_released_identity () =
  run_eio @@ fun ~sw ~net ~clock ->
  with_temp_dir "hitl-between-candidate-cancellation" @@ fun base_path ->
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
         [ { id = "hitl-cancel-between-unreachable"
           ; base_url = "http://127.0.0.1:1"
           }
         ; { id = "hitl-cancel-between-successor"
           ; base_url = successor.base_url
           }
         ]
       in
       publish_lane
         [ "hitl-cancel-between-unreachable"
         ; "hitl-cancel-between-successor"
         ]
         (F.resolver_snapshot
            ~source:"hitl-between-candidate-cancellation"
            fixtures);
       let entry = pending_entry ~base_path () in
       let bind_calls = ref 0 in
       let expected_backtrace = ref None in
       let payload =
         Failure "injected cancellation before successor bind"
       in
       let bind_writer path body =
         incr bind_calls;
         if !bind_calls = 2
         then raise_injected_cancellation expected_backtrace payload
         else Fs_compat.save_file_atomic_strict_staged path body
       in
       let observed_payload =
         match
           Worker.For_testing.execute_prepared_flow_with_queue_ops
             ~queue_ops:(exact_queue_ops ~bind_writer ())
             ~net
             ~clock
             ~on_summary:(fun _ ->
               fail "between-candidate cancellation delivered a summary")
             (prepare_exn entry)
         with
         | exception Eio.Cancel.Cancelled observed -> observed
         | Worker.Executed
         | Worker.Identity_unbound_blocked
         | Worker.Exact_rejection_blocked _ ->
           fail "between-candidate cancellation did not leave the flow"
       in
       check bool
         "between-candidate cancellation payload is preserved"
         true
         (observed_payload == payload);
       check int "successor bind was attempted exactly once" 2 !bind_calls;
       check int "cancelled successor made no POST" 0 (F.post_count successor);
       match Q.For_testing.get_pending_entry_unchecked ~id:entry.id with
       | Some
           { exact_attempt =
               QT.Exact_bound
                 { slot_id = "hitl-cancel-between-unreachable"
                 ; status = QT.Exact_quarantined QT.Exact_cancellation
                 ; _
                 }
           ; summary_attempt_disposition = QT.Summary_attempt_settled
           ; _
           } ->
         ()
       | _ ->
         fail
           "between-candidate cancellation lost or misclassified the released identity")
;;

let prompt_only_snapshot base_url =
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

let test_json_syntax_candidate_is_admitted_without_structured_capability () =
  run_eio @@ fun ~sw:_ ~net ~clock ->
  with_temp_dir "hitl-prompt-only" @@ fun base_path ->
  Fun.protect
    ~finally:Q.For_testing.reset_runtime_state
    (fun () ->
       install_queue base_path;
       Prompt_registry.set_markdown_dir
         (Masc_test_deps.source_path "config/prompts");
       publish_lane
         [ "hitl-incapable" ]
         (prompt_only_snapshot "http://127.0.0.1:1");
       let entry = pending_entry ~base_path () in
       let prepared = prepare_exn entry in
       let before = Worker.For_testing.flow_evidence prepared in
       check
         (list string)
         "prompt-only topology remains frozen"
         [ "hitl-incapable" ]
         (List.map candidate_id before.declared_candidate_snapshot);
       check
         (list string)
         "candidate admission remains deferred until the flow runs"
         []
         (List.map admission_id before.admissions);
       (match
          Worker.For_testing.execute_prepared_flow
            ~net
            ~clock
            ~on_summary:(fun _ -> fail "prompt-only candidate delivered a summary")
            prepared
        with
        | Worker.Executed -> ()
        | Worker.Identity_unbound_blocked ->
          fail "prompt-only candidate lost its exact-attempt identity"
        | Worker.Exact_rejection_blocked _ ->
          fail "prompt-only candidate was rejected before its attempt ran");
       check
         (list string)
         "execution records the admitted candidate"
         [ "hitl-incapable" ]
         ((Worker.For_testing.flow_evidence prepared).admissions
          |> List.map admission_id);
       match Q.For_testing.get_pending_entry_unchecked ~id:entry.id with
       | Some
           { exact_attempt =
               QT.Exact_bound
                 { status = QT.Exact_quarantined QT.Exact_flow_execution_failed; _ }
           ; summary_status = QT.Summary_failed _
           ; summary_attempt_disposition = QT.Summary_attempt_settled
           ; _
           } ->
         ()
       | _ -> fail "prompt-only execution did not settle its failed exact attempt")
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
       Worker.For_testing.execute_prepared_flow_with_queue_ops
         ~queue_ops:
           (exact_queue_ops ~bind_writer:visible_after_rename_writer ())
         ~net
         ~clock
         ~on_summary:(fun _ -> fail "unconfirmed bind delivered a summary")
         (prepare_exn entry)
       |> require_executed;
       check int "unconfirmed bind forbids POST" 0 (F.post_count server);
       match Q.For_testing.get_pending_entry_unchecked ~id:entry.id with
       | Some
           { exact_attempt =
               QT.Exact_bound
                 { status =
                     QT.Exact_quarantined QT.Exact_terminal_persistence_failure
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
       Worker.For_testing.execute_prepared_flow_with_queue_ops
         ~queue_ops:
           (exact_queue_ops ~release_writer:visible_after_rename_writer ())
         ~net
         ~clock
         ~on_summary:(fun _ -> fail "unconfirmed release advanced the flow")
         (prepare_exn entry)
       |> require_executed;
       check int "unconfirmed release forbids successor POST" 0 (F.post_count successor);
       match Q.For_testing.get_pending_entry_unchecked ~id:entry.id with
       | Some
           { exact_attempt =
               QT.Exact_bound
                 { status =
                     QT.Exact_quarantined QT.Exact_terminal_persistence_failure
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
          Worker.For_testing.execute_prepared_flow_with_queue_ops
            ~queue_ops:
              (exact_queue_ops ~complete_writer:visible_after_rename_writer ())
            ~net
            ~clock
            ~on_summary:(fun _ -> delivered := true)
            (prepare_exn entry)
          |> require_executed
        with
        | exception Worker.Exact_terminalization_persistence_failed _ -> ()
        | () -> fail "visible completion did not signal persistence uncertainty");
       check int "provider completed once" 1 (F.post_count server);
       check bool "unconfirmed completion forbids Gate delivery" false !delivered;
       (match Q.For_testing.get_pending_entry_unchecked ~id:entry.id with
       | Some
           { exact_attempt =
               QT.Exact_bound { status = QT.Exact_completed; _ }
           ; summary_status = QT.Summary_available _
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
       (match Q.For_testing.get_pending_entry_unchecked ~id:successor.id with
        | Some
            { exact_attempt = QT.Exact_unbound
            ; summary_status = QT.Summary_pending
            ; _
            } ->
          ()
        | _ -> fail "restart skipped the oldest finalization barrier"))
;;

let test_completion_identity_conflict_stays_deterministic () =
  run_eio @@ fun ~sw ~net ~clock ->
  with_temp_dir "hitl-completion-identity-conflict" @@ fun base_path ->
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
         [ "hitl-completion-identity-conflict" ]
         (F.resolver_snapshot
            ~source:"hitl-completion-identity-conflict"
            [ { id = "hitl-completion-identity-conflict"
              ; base_url = server.base_url
              }
            ]);
       let entry = pending_entry ~base_path () in
       let replacement_call_id = "replacement-call" in
       let replace_bound_identity () =
         match Q.For_testing.get_pending_entry_unchecked ~id:entry.id with
         | Some { exact_attempt = QT.Exact_bound binding; _ } ->
           let transition_exn operation = function
             | Ok { Q.write_outcome = Q.Fsync_completed; _ } -> ()
             | Ok { Q.write_outcome = Q.Visible_sync_unconfirmed detail; _ } ->
               failf "%s was not durable: %s" operation detail
             | Error error ->
               failf
                 "%s failed: %s"
                 operation
                 (Q.exact_attempt_error_to_string error)
           in
           Q.release_summary_exact_attempt_before_dispatch
             ~id:entry.id
             ~input_hash:entry.input_hash
             ~sequence:entry.sequence
             ~slot_id:binding.slot_id
             ~call_id:binding.call_id
             ~plan_fingerprint:binding.plan_fingerprint
             ~request_body_sha256:binding.request_body_sha256
           |> transition_exn "release original identity";
           Q.bind_summary_exact_attempt
             ~id:entry.id
             ~input_hash:entry.input_hash
             ~sequence:entry.sequence
             ~slot_id:"replacement-slot"
             ~call_id:replacement_call_id
             ~plan_fingerprint:(String.make 64 'a')
             ~request_body_sha256:(String.make 64 'b')
           |> transition_exn "bind replacement identity"
         | Some { exact_attempt = QT.Exact_unbound; _ } ->
           fail "after_bind observed an unbound exact attempt"
         | None -> fail "after_bind lost the pending approval"
       in
       let delivered = ref false in
       (match
          Worker.For_testing.execute_prepared_flow_with_queue_ops
            ~queue_ops:
              (exact_queue_ops ~after_bind:replace_bound_identity ())
            ~net
            ~clock
            ~on_summary:(fun _ -> delivered := true)
            (prepare_exn entry)
        with
        | Worker.Exact_rejection_blocked
            (Q.Exact_attempt_identity_conflict binding) ->
          check string
            "typed replacement identity survives"
            replacement_call_id
            binding.call_id
        | Worker.Exact_rejection_blocked rejection ->
          failf
            "wrong deterministic rejection: %s"
            (Q.exact_attempt_error_to_string
               (Q.Exact_attempt_rejected rejection))
        | Worker.Executed ->
          fail "deterministic completion conflict reported success"
        | Worker.Identity_unbound_blocked ->
          fail "deterministic completion conflict lost its bound identity");
       check bool "rejected completion delivered no summary" false !delivered;
       match Q.For_testing.get_pending_entry_unchecked ~id:entry.id with
       | Some
           { exact_attempt =
               QT.Exact_bound { call_id; status = QT.Exact_dispatch_uncertain; _ }
           ; summary_status = QT.Summary_pending
           ; summary_attempt_disposition = QT.Summary_attempt_in_flight
           ; _
           } ->
         check string
           "deterministic conflict retained replacement identity"
           replacement_call_id
           call_id
       | _ ->
         fail "deterministic completion conflict mutated durable uncertainty state")
;;

let test_flow_execution_failure_quarantines_and_allows_successor () =
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
         (prepare_exn entry)
       |> require_executed;
       check int "failed candidate dispatched once" 1 (F.post_count failed);
       (match Q.For_testing.get_pending_entry_unchecked ~id:entry.id with
        | Some
            { input_hash
            ; sequence
            ; summary_status = QT.Summary_failed { reason }
            ; exact_attempt =
                QT.Exact_bound
                  { slot_id
                  ; call_id
                  ; plan_fingerprint
                  ; request_body_sha256
                  ; status = QT.Exact_quarantined QT.Exact_flow_execution_failed
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
       let successor_server =
         F.start_server
           ~sw
           ~net
           ~clock
           (F.Reply (F.openai_response (judgment_json "approve")))
       in
       publish_lane
         [ "hitl-flow-successor" ]
         (F.resolver_snapshot
            ~source:"hitl-flow-successor"
            [ { id = "hitl-flow-successor"
              ; base_url = successor_server.base_url
              }
            ]);
       let resumed = Gate.resume_persisted_auto_judges ~base_path in
       check
         (list string)
         "quarantined entry does not stall a later owner entry"
         [ successor.id ]
         resumed.started_ids;
       Eio.Promise.await successor_server.first_request_arrived;
       check int "failed entry dispatched once" 1 (F.post_count failed);
       check int
         "successor dispatches once"
         1
         (F.post_count successor_server))
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
       let in_flight_entry : QT.pending_approval option ref = ref None in
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
                    ~decision:(QT.Decision.Reject "manual operator resolution")
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
          Worker.For_testing.spawn_with_queue_ops
            ~queue_ops:(exact_queue_ops ())
            ~sw
            ~entry
            ~on_summary:(fun _ -> delivered := true)
            ~on_finish:(fun outcome -> finish_outcome := Some outcome)
            ()
        with
        | Ok Worker.Worker_forked -> ()
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
           | Some Worker.Terminalization_persistence_uncertain
           | Some Worker.Terminalization_identity_unbound
           | Some Worker.Terminalization_rejected
           | None -> false);
       check bool
         "manually resolved source left pending queue"
         true
         (Option.is_none (Q.For_testing.get_pending_entry_unchecked ~id:entry.id)))
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
                 (prepare_exn entry)
               |> require_executed)
            (fun () ->
               F.await_first_request server;
               raise Cancel_after_request_arrived)
        with
        | exception Cancel_after_request_arrived -> ()
        | () -> fail "cancellation trigger did not win");
       (match Q.For_testing.get_pending_entry_unchecked ~id:entry.id with
        | Some
            { exact_attempt =
                QT.Exact_bound
                  { status = QT.Exact_quarantined QT.Exact_cancellation; _ }
            ; _
            } ->
          ()
        | _ -> fail "post-dispatch cancellation was not terminally quarantined");
       (* #31474 routed this row to worker activation at boot, but the
          reservation underneath refuses it: [reserve_summary_attempt_retry]
          documents that a terminal exact quarantine is never retried, and a
          cancellation quarantine is terminal. So recovery requests the row,
          the reservation declines, and no worker runs.

          What this pins is that the report says so. Collapsing the declined
          reservation into [Started] made the boot log read
          "requested=1 started=1" for an approval nothing had picked up, and
          the same row came back on the next restart. *)
       install_queue base_path;
       let recovery = Gate.resume_persisted_auto_judges ~base_path in
       check int "boot recovery requests the cancelled row" 1 recovery.requested;
       check
         (list string)
         "but it must not claim a worker started"
         []
         recovery.started_ids;
       check bool
         "it is reported skipped"
         true
         (List.mem entry.id recovery.skipped_ids);
       check int "and not as a failure" 0 (List.length recovery.failures))
;;

let test_spawn_preserves_cancellation_origin_backtrace () =
  let previous_backtrace_status = Printexc.backtrace_status () in
  Fun.protect
    ~finally:(fun () -> Printexc.record_backtrace previous_backtrace_status)
    (fun () ->
       Printexc.record_backtrace true;
       run_eio @@ fun ~sw ~net ~clock ->
       with_temp_dir "hitl-cancellation-backtrace" @@ fun base_path ->
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
              [ "hitl-cancellation-backtrace" ]
              (F.resolver_snapshot
                 ~source:"hitl-cancellation-backtrace"
                 [ { id = "hitl-cancellation-backtrace"
                   ; base_url = server.base_url
                   }
                 ]);
            let entry = pending_entry ~base_path () in
            let expected_backtrace = ref None in
            let finish_outcome = ref None in
            let payload = Failure "injected HITL cancellation origin" in
            let bind_writer _path _body =
              raise_injected_cancellation expected_backtrace payload
            in
            let observed_payload, observed_backtrace =
              match
                Eio.Switch.run
                @@ fun worker_sw ->
                match
                  Worker.For_testing.spawn_with_queue_ops
                    ~queue_ops:(exact_queue_ops ~bind_writer ())
                    ~sw:worker_sw
                    ~entry
                    ~on_summary:(fun _ ->
                      fail "cancelled worker delivered a summary")
                    ~on_finish:(fun outcome -> finish_outcome := Some outcome)
                    ()
                with
                | Ok Worker.Worker_forked -> ()
                | Error detail -> fail detail
              with
              | exception Eio.Cancel.Cancelled observed_payload ->
                observed_payload, Printexc.get_raw_backtrace ()
              | () -> fail "injected cancellation did not leave the worker"
            in
            check bool
              "cancellation payload identity is preserved"
              true
              (observed_payload == payload);
            let expected_backtrace =
              match !expected_backtrace with
              | Some backtrace -> backtrace
              | None -> fail "injected cancellation origin was not captured"
            in
            check_backtrace_starts_at_origin
              "cancellation origin raw backtrace is preserved"
              expected_backtrace
              observed_backtrace;
            check bool
              "pre-bind cancellation reports identity-unbound"
               true
               (match !finish_outcome with
                | Some Worker.Terminalization_identity_unbound -> true
                | Some Worker.Conclusive_terminalization
                | Some Worker.Terminalization_persistence_uncertain
                | Some Worker.Terminalization_rejected
                | None -> false);
            check int
              "cancelled before-dispatch callback made no request"
              0
              (F.post_count server)))
;;

let test_prebind_cancellation_withholds_production_gate_drain () =
  let previous_backtrace_status = Printexc.backtrace_status () in
  Fun.protect
    ~finally:(fun () -> Printexc.record_backtrace previous_backtrace_status)
    (fun () ->
       Printexc.record_backtrace true;
       run_eio @@ fun ~sw ~net ~clock ->
       with_temp_dir "hitl-prebind-cancellation-gate" @@ fun base_path ->
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
              [ "hitl-prebind-cancellation-gate" ]
              (F.resolver_snapshot
                 ~source:"hitl-prebind-cancellation-gate"
                 [ { id = "hitl-prebind-cancellation-gate"
                   ; base_url = server.base_url
                   }
                 ]);
            select_auto_judge_mode base_path;
            let cancelled =
              pending_entry ~input_tag:"cancelled" ~base_path ()
            in
            let successor =
              pending_entry ~input_tag:"successor" ~base_path ()
            in
            let bind_calls = ref 0 in
            let expected_backtrace = ref None in
            let payload =
              Failure "injected Gate pre-bind cancellation origin"
            in
            let observed_payload, observed_backtrace =
              match
                Eio.Switch.run
                @@ fun worker_sw ->
                Eio_context.set_switch worker_sw;
                match
                  Gate.For_testing.spawn_auto_judge_entry_with_worker
                    ~spawn_worker:
                      (fun ~sw ~entry ~on_summary ~on_finish () ->
                         Worker.For_testing.spawn_with_queue_ops
                           ~queue_ops:
                             (exact_queue_ops
                                ~bind_writer:(fun _path _body ->
                                  incr bind_calls;
                                  raise_injected_cancellation
                                    expected_backtrace
                                    payload)
                                ())
                           ~sw
                           ~entry
                           ~on_summary
                           ~on_finish
                           ())
                    cancelled
                with
                | Ok true -> ()
                | Ok false -> fail "production Gate did not claim oldest work"
                | Error detail -> fail detail
              with
              | exception Eio.Cancel.Cancelled observed_payload ->
                observed_payload, Printexc.get_raw_backtrace ()
              | () -> fail "Gate worker cancellation did not reach its supervisor"
            in
            check bool
              "Gate cancellation payload identity is preserved"
              true
              (observed_payload == payload);
            let expected_backtrace =
              match !expected_backtrace with
              | Some backtrace -> backtrace
              | None -> fail "Gate cancellation origin was not captured"
            in
            check_backtrace_starts_at_origin
              "Gate cancellation raw backtrace is preserved"
              expected_backtrace
              observed_backtrace;
            check int "Gate invokes the cancelled bind exactly once" 1 !bind_calls;
            check int
              "pre-bind Gate cancellation performs no provider POST"
              0
              (F.post_count server);
            (match Q.For_testing.get_pending_entry_unchecked ~id:cancelled.id with
             | Some
                 { exact_attempt = QT.Exact_unbound
                 ; summary_status = QT.Summary_pending
                 ; summary_attempt_disposition =
                     QT.Summary_attempt_identity_unbound
                 ; _
                 } ->
               ()
             | _ -> fail "Gate drained or mutated the cancelled pending entry");
            match Q.For_testing.get_pending_entry_unchecked ~id:successor.id with
            | Some
                { exact_attempt = QT.Exact_unbound
                ; summary_status = QT.Summary_pending
                ; summary_attempt_disposition = QT.Summary_attempt_ready
                ; _
                } ->
              ()
            | _ -> fail "Gate drained or dispatched successor work"))
;;

let test_bound_cancellation_cleanup_uncertainty_preserves_origin () =
  let previous_backtrace_status = Printexc.backtrace_status () in
  Fun.protect
    ~finally:(fun () -> Printexc.record_backtrace previous_backtrace_status)
    (fun () ->
       Printexc.record_backtrace true;
       run_eio @@ fun ~sw ~net ~clock ->
       with_temp_dir "hitl-bound-cancellation-uncertain" @@ fun base_path ->
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
              [ "hitl-bound-cancellation-uncertain" ]
              (F.resolver_snapshot
                 ~source:"hitl-bound-cancellation-uncertain"
                 [ { id = "hitl-bound-cancellation-uncertain"
                   ; base_url = server.base_url
                   }
                 ]);
            let entry = pending_entry ~base_path () in
            let expected_backtrace = ref None in
            let finish_outcome = ref None in
            let payload =
              Failure "injected bound HITL cancellation origin"
            in
            let observed_payload, observed_backtrace =
              match
                Eio.Switch.run
                @@ fun worker_sw ->
                match
                  Worker.For_testing.spawn_with_queue_ops
                    ~queue_ops:
                      (exact_queue_ops
                         ~quarantine_writer:unknown_writer
                         ~after_bind:(fun () ->
                           raise_injected_cancellation
                             expected_backtrace
                             payload)
                         ())
                    ~sw:worker_sw
                    ~entry
                    ~on_summary:(fun _ ->
                      fail "cancelled worker delivered a summary")
                    ~on_finish:(fun outcome -> finish_outcome := Some outcome)
                    ()
                with
                | Ok Worker.Worker_forked -> ()
                | Error detail -> fail detail
              with
              | exception Eio.Cancel.Cancelled observed_payload ->
                observed_payload, Printexc.get_raw_backtrace ()
              | () -> fail "injected cancellation did not leave the worker"
            in
            check bool
              "bound cancellation payload identity is preserved"
              true
              (observed_payload == payload);
            let expected_backtrace =
              match !expected_backtrace with
              | Some backtrace -> backtrace
              | None -> fail "bound cancellation origin was not captured"
            in
            check_backtrace_starts_at_origin
              "bound cancellation raw backtrace is preserved"
              expected_backtrace
              observed_backtrace;
            check bool
              "failed bound cleanup reports persistence uncertainty"
              true
               (match !finish_outcome with
                | Some Worker.Terminalization_persistence_uncertain -> true
                | Some Worker.Conclusive_terminalization
                | Some Worker.Terminalization_identity_unbound
                | Some Worker.Terminalization_rejected
                | None -> false);
            check int
              "cancellation before dispatch performs no provider POST"
              0
              (F.post_count server);
            match Q.For_testing.get_pending_entry_unchecked ~id:entry.id with
            | Some
                { exact_attempt = QT.Exact_bound _
                ; summary_status = QT.Summary_pending
                ; _
                } ->
              ()
            | _ ->
              fail
                "failed cancellation cleanup did not preserve the durable binding"))
;;

let test_pre_worker_start_failure_preserves_unbound_pending () =
  run_eio @@ fun ~sw:_ ~net:_ ~clock:_ ->
  with_temp_dir "hitl-pre-worker-start-failure" @@ fun base_path ->
  Fun.protect
    ~finally:Q.For_testing.reset_runtime_state
    (fun () ->
       install_queue base_path;
       select_auto_judge_mode base_path;
       let entry = pending_entry ~base_path () in
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
       (match Q.For_testing.get_pending_entry_unchecked ~id:entry.id with
       | Some
           { exact_attempt = QT.Exact_unbound
           ; summary_status = QT.Summary_pending
           ; summary_attempt_disposition =
               QT.Summary_attempt_pre_worker_unavailable
                 { reason_code =
                     QT.Summary_pre_worker_auto_judge_unavailable
                 ; operator_detail = "no usable exact-output lane slots"
                 }
           ; _
           } ->
         ()
       | _ -> fail "pre-worker failure lost its durable typed reason");
       ())
;;

let test_detached_worker_start_survives_keeper_turn_stop () =
  run_eio @@ fun ~sw:_ ~net:_ ~clock:_ ->
  with_temp_dir "hitl-detached-worker-start" @@ fun base_path ->
  Fun.protect
    ~finally:Q.For_testing.reset_runtime_state
    (fun () ->
       install_queue base_path;
       select_auto_judge_mode base_path;
       let entry = pending_entry ~base_path () in
       let worker_entered, resolve_worker_entered = Eio.Promise.create () in
       let allow_worker_finish, resolve_allow_worker_finish = Eio.Promise.create () in
       let worker_finished, resolve_worker_finished = Eio.Promise.create () in
       let keeper_turn_stopped =
         match
           Eio.Switch.run
           @@ fun turn_sw ->
           Eio_context.with_turn_switch turn_sw
           @@ fun () ->
           (match
              Gate.For_testing.spawn_auto_judge_entry_with_detached_worker
                ~spawn_worker:
                  (fun ~sw:_ ~entry:_ ~on_summary:_ ~on_finish () ->
                     Eio.Promise.resolve resolve_worker_entered ();
                     Eio.Promise.await allow_worker_finish;
                     on_finish Worker.Terminalization_identity_unbound;
                     Eio.Promise.resolve resolve_worker_finished ();
                     Ok Worker.Worker_forked)
                entry
            with
            | Ok true -> ()
            | Ok false -> fail "detached Gate worker did not acquire the entry"
            | Error detail -> fail detail);
           Eio.Switch.fail
             turn_sw
             Masc.Keeper_owner_signals.Stop_active_child
         with
         | exception Masc.Keeper_owner_signals.Stop_active_child -> true
         | exception
             Eio.Cancel.Cancelled Masc.Keeper_owner_signals.Stop_active_child ->
           true
         | () -> false
       in
       check bool "Keeper turn received its stop signal" true keeper_turn_stopped;
       Eio.Promise.await worker_entered;
       Eio.Promise.resolve resolve_allow_worker_finish ();
       Eio.Promise.await worker_finished;
       check
         (list string)
         "server-root worker released the owner after the stopped turn"
         []
         (Gate.For_testing.active_auto_judges_for_owner
            ~base_path
            ~keeper_name:entry.keeper_name))
;;

let test_visible_uncertainty_withholds_production_drain () =
  run_eio_without_context @@ fun ~sw ~net ~clock ~mono_clock ->
  with_temp_dir "hitl-uncertain-lifecycle" @@ fun base_path ->
  Fun.protect
    ~finally:Q.For_testing.reset_runtime_state
    (fun () ->
       (* This case isolates the persistence-uncertain lifecycle. Keep one slot
          so the successor cannot legitimately start in parallel. *)
       with_hitl_concurrency 1 @@ fun () ->
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
                     Worker.For_testing.spawn_with_queue_ops
                       ~queue_ops:
                         (exact_queue_ops ~complete_writer:visible_writer ())
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
       (match Q.For_testing.get_pending_entry_unchecked ~id:uncertain.id with
       | Some
           { exact_attempt =
               QT.Exact_bound { status = QT.Exact_completed; _ }
           ; summary_status = QT.Summary_available _
           ; summary_attempt_disposition =
               QT.Summary_attempt_persistence_uncertain
           ; _
           } ->
         ()
       | _ -> fail "uncertain completion did not remain durably visible");
       (match Q.For_testing.get_pending_entry_unchecked ~id:successor.id with
        | Some
            { exact_attempt = QT.Exact_unbound
            ; summary_status = QT.Summary_pending
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

let test_same_owner_workers_run_in_parallel_with_bound () =
  run_eio @@ fun ~sw ~net ~clock ->
  with_temp_dir "hitl-owner-fifo-drain" @@ fun base_path ->
  Fun.protect
    ~finally:Q.For_testing.reset_runtime_state
    (fun () ->
       with_hitl_concurrency 2 @@ fun () ->
       install_queue base_path;
       Prompt_registry.set_markdown_dir
         (Masc_test_deps.source_path "config/prompts");
       let release_first, resolve_release_first = Eio.Promise.create () in
       let server =
         F.start_server
           ~on_request_before_reply:(fun () -> Eio.Promise.await release_first)
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
       let first =
         pending_entry
           ~input_tag:"first"
           ~include_request_context:false
           ~base_path
           ()
       in
       let second = pending_entry ~input_tag:"second" ~base_path () in
       check
         (option yojson)
         "FIFO head reproduces absent causal context"
         None
         first.request_context;
       let initial = Gate.resume_persisted_auto_judges ~base_path in
       check
         (list string)
         "production recovery fills both same-owner worker slots in queue order"
         [ first.id; second.id ]
         initial.started_ids;
       F.await_first_request server;
       let concurrent = Gate.resume_persisted_auto_judges ~base_path in
       check
         (list string)
         "concurrent recovery cannot overfill the owner bound"
         []
         concurrent.started_ids;
       await_condition
         ~clock
         ~remaining:100
         ~failure:"second same-owner worker did not reach the provider concurrently"
         (fun () -> F.post_count server = 2);
       check int
         "both same-owner requests arrive before the first response is released"
         2
         (F.post_count server);
       check
         (list string)
         "both worker identities remain independently claimed"
         (List.sort String.compare [ first.id; second.id ])
         (Gate.For_testing.active_auto_judges_for_owner
            ~base_path
            ~keeper_name:first.keeper_name);
       ignore (Eio.Promise.try_resolve resolve_release_first ());
       await_condition
         ~clock
         ~remaining:100
         ~failure:"parallel same-owner workers did not complete"
         (fun () ->
            Option.is_none (Q.For_testing.get_pending_entry_unchecked ~id:first.id)
            && Option.is_none
                 (Q.For_testing.get_pending_entry_unchecked ~id:second.id));
       check int
         "each owner entry dispatches exactly once"
         2
         (F.post_count server))
;;

let test_require_human_head_does_not_stop_owner_drain () =
  run_eio @@ fun ~sw ~net ~clock ->
  with_temp_dir "hitl-require-human-drain" @@ fun base_path ->
  Fun.protect
    ~finally:Q.For_testing.reset_runtime_state
    (fun () ->
       with_hitl_concurrency 2 @@ fun () ->
       install_queue base_path;
       Prompt_registry.set_markdown_dir
         (Masc_test_deps.source_path "config/prompts");
       let server =
         F.start_server
           ~sw
           ~net
           ~clock
           (F.Replies
              [ F.openai_response (judgment_json "require_human")
              ; F.openai_response (judgment_json "approve")
              ])
       in
       publish_lane
         [ "hitl-require-human-head" ]
         (F.resolver_snapshot
            ~source:"hitl-require-human-head"
            [ { id = "hitl-require-human-head"; base_url = server.base_url } ]);
       select_auto_judge_mode base_path;
       let head = pending_entry ~input_tag:"require-human-head" ~base_path () in
       let successor = pending_entry ~input_tag:"successor" ~base_path () in
       let recovery = Gate.resume_persisted_auto_judges ~base_path in
       check
         (list string)
         "recovery starts both owner entries"
         [ head.id; successor.id ]
         recovery.started_ids;
       await_condition
         ~clock
         ~remaining:100
         ~failure:"same-owner judgments did not both reach the provider"
         (fun () -> F.post_count server = 2);
       await_condition
         ~clock
         ~remaining:100
         ~failure:"successor did not complete after Require_human head"
         (fun () ->
            Option.is_none
              (Q.For_testing.get_pending_entry_unchecked ~id:successor.id));
       (match Q.For_testing.get_pending_entry_unchecked ~id:head.id with
        | Some
            { exact_attempt =
                QT.Exact_bound { status = QT.Exact_completed; _ }
            ; summary_status =
                QT.Summary_available { judgment = QT.Require_human; _ }
            ; summary_attempt_disposition = QT.Summary_attempt_settled
            ; _
            } ->
          ()
        | _ -> fail "Require_human head lost its durable operator-visible state");
       check int "both same-owner entries judged once" 2 (F.post_count server))
;;

let test_judge_effect_prompt_comes_from_registry () =
  Prompt_registry.set_markdown_dir
    (Masc_test_deps.source_path "config/prompts");
  match Worker.For_testing.system_prompt () with
  | Error detail -> fail ("Gate judgment prompt unavailable: " ^ detail)
  | Ok prompt ->
    check bool "prompt is non-empty" true (String.trim prompt <> "");
    check bool
      "judge is scoped to effect safety"
      true
      (Astring.String.is_infix
         ~affix:"authority is the concrete effect's safety"
         prompt);
    check bool
      "missing task purpose alone does not escalate"
      true
      (Astring.String.is_infix
         ~affix:"Missing task-purpose context by itself is not a safety ambiguity"
         prompt);
    check bool
      "read-only examples are explicit"
      true
      (Astring.String.is_infix
         ~affix:"remote repository metadata views"
         prompt);
    check bool
      "non-destructive bounded effects do not require intent review"
      true
      (Astring.String.is_infix
         ~affix:"bounded, reversible effect"
         prompt);
    check bool
      "host context outranks transcript claims"
      true
      (Astring.String.is_infix
         ~affix:"host-observed structured evidence and outranks claims"
         prompt);
    check bool
      "catalog absence is not called a personal fork"
      true
      (Astring.String.is_infix
         ~affix:"\"personal fork\" or \"malicious\""
         prompt)
;;


(* {1 Run-registry outcome}

   A finished exact run reached [Exact_lane_run_registry.Succeeded] whether or
   not it produced a summary: [Flow_semantic_candidates_exhausted] quarantines
   the candidate, returns [Executed] like a judged run, and the caller
   synthesised an output for the missing summary. A run that judged nothing was
   indistinguishable from one that did.

   Both arms are pinned here because the decision is now a named function and
   the outcome type has a variant for each. *)

let summary_fixture () : QT.hitl_context_summary =
  { summary_version = QT.current_hitl_context_summary_version
  ; generated_at = 1000.0
  ; model_run_id = "run-fixture"
  ; context_summary = "context"
  ; key_questions = [ "q1" ]
  ; judgment = QT.Approve
  ; rationale = "because"
  }
;;

let test_observed_summary_earns_succeeded () =
  let outcome, output =
    Worker.For_testing.run_outcome_of_observed_summary
      ~last_outcome:None
      (Some (summary_fixture ()))
  in
  (match outcome with
   | Masc.Exact_lane_run_registry.Succeeded -> ()
   | Masc.Exact_lane_run_registry.Cancelled -> Alcotest.fail "expected Succeeded, got Cancelled"
   | Masc.Exact_lane_run_registry.Failed { code; _ } ->
     Alcotest.failf "expected Succeeded, got Failed %s" code);
  Alcotest.(check bool) "output carries the summary" true (output <> `Null)
;;

(* The point of the whole sink: a flow that ends without a summary tells the
   run registry which branch it was on, instead of every failure arriving as
   one indistinguishable code. *)
let test_missing_summary_reports_the_last_branch () =
  List.iter
    (fun (outcome_variant, expected_code) ->
       match
         Worker.For_testing.run_outcome_of_observed_summary
           ~last_outcome:(Some outcome_variant)
           None
       with
       | Masc.Exact_lane_run_registry.Failed { code; detail }, _ ->
         Alcotest.(check string) "code is the branch" expected_code code;
         Alcotest.(check bool)
           "detail names the branch too"
           true
           (let n = String.length expected_code in
            let rec scan i =
              i + n <= String.length detail
              && (String.sub detail i n = expected_code || scan (i + 1))
            in
            scan 0)
       | Masc.Exact_lane_run_registry.Succeeded, _ ->
         Alcotest.fail "a run with no summary was recorded as Succeeded"
       | Masc.Exact_lane_run_registry.Cancelled, _ ->
         Alcotest.fail "expected Failed, got Cancelled")
    Worker.
      [ Candidates_exhausted, "exact_candidates_exhausted"
      ; Execution_failed, "exact_execution_failed"
      ; Provenance_mismatch, "exact_provenance_mismatch"
      ; Cli_slots_exhausted, "exact_cli_slots_exhausted"
      ]
;;

let test_missing_summary_earns_failed () =
  let outcome, output =
    Worker.For_testing.run_outcome_of_observed_summary ~last_outcome:None None
  in
  (match outcome with
   | Masc.Exact_lane_run_registry.Failed { code; detail } ->
     Alcotest.(check string) "code names the absent branch" "no_branch_recorded" code;
     Alcotest.(check bool) "detail is not empty" true (String.trim detail <> "")
   | Masc.Exact_lane_run_registry.Succeeded ->
     Alcotest.fail "a run that produced no summary was recorded as Succeeded"
   | Masc.Exact_lane_run_registry.Cancelled -> Alcotest.fail "expected Failed, got Cancelled"
  );
  Alcotest.(check bool) "no output is synthesised" true (output = `Null)
;;

(* ── CLI lane-slot fallback (RFC cli-runtimes-as-lane-slots) ────────
   The walk engages only after every catalog slot is exhausted. These drive
   the real worker flow against an unreachable HTTP slot and an injected cli
   runner; the runtime table below is what lets [is_official_client] admit
   the cli ids, exactly like the fusion panel fixture. *)

let cli_runtime_fixture =
  {|
[runtime]
default = "stub-http.stub-model"

[providers.stub-http]
display-name = "Stub HTTP"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:9/v1"

[providers.claude_code]
display-name = "Claude Code Max Subscription"
protocol = "claude-code"
command = "/usr/bin/true"
is-non-interactive = true

[models.stub-model]
api-name = "gpt-5.4"
max-context = 200000
tools-support = true
streaming = true

[stub-http.stub-model]

[models."claude-sonnet-5"]
api-name = "claude-sonnet-5"
max-context = 1000000
tools-support = true
streaming = true
turn-timeout-s = 0

[claude_code."claude-sonnet-5"]

[models."claude-haiku-4-5"]
api-name = "claude-haiku-4-5"
max-context = 200000
tools-support = true
streaming = true
turn-timeout-s = 0

[claude_code."claude-haiku-4-5"]
|}
;;

let cli_primary = "claude_code.claude-sonnet-5"
let cli_secondary = "claude_code.claude-haiku-4-5"

let with_cli_runtimes f =
  let path = Filename.temp_file "hitl-cli-runtime" ".toml" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () ->
       let channel = open_out path in
       Fun.protect
         ~finally:(fun () -> close_out channel)
         (fun () -> output_string channel cli_runtime_fixture);
       match Runtime.init_default ~config_path:path with
       | Error detail -> failf "cli runtime fixture must initialize: %s" detail
       | Ok () -> f ())
;;

let publish_unreachable_lane_with_cli ~cli_slot_ids ~source =
  let fixtures : F.target_fixture list =
    [ { id = "hitl-cli-unreachable"; base_url = "http://127.0.0.1:1" } ]
  in
  publish_lane
    ~cli_slot_ids
    [ "hitl-cli-unreachable" ]
    (F.resolver_snapshot ~source fixtures)
;;

(* Self-review regression (2026-08-29): when the walk releases the exhausted
   catalog binding and then every cli bind is REJECTED (not a storage
   failure — that latches the store and the settle correctly signals
   persistence uncertainty), the pre-cli binding is left released. The
   caller's quarantine would be rejected on that state, so the walk must
   settle the entry itself: released -> quarantine is admitted for the
   execution-failure cause, and the run ends Executed, never raising. *)
let test_cli_bind_rejection_after_release_settles_the_entry () =
  run_eio @@ fun ~sw:_ ~net ~clock ->
  with_temp_dir "hitl-cli-bind-rejected" @@ fun base_path ->
  Fun.protect
    ~finally:Q.For_testing.reset_runtime_state
    (fun () ->
       install_queue base_path;
       Prompt_registry.set_markdown_dir
         (Masc_test_deps.source_path "config/prompts");
       with_cli_runtimes @@ fun () ->
       publish_unreachable_lane_with_cli
         ~cli_slot_ids:[ cli_primary; cli_secondary ]
         ~source:"hitl-cli-bind-rejected";
       let entry = pending_entry ~base_path () in
       let cli_bind_rejections = ref 0 in
       let bind
             ~id
             ~input_hash
             ~sequence
             ~slot_id
             ~call_id
             ~plan_fingerprint
             ~request_body_sha256
         =
         (* Reject exactly the cli binds — their identity carries the
            cli-oneshot plan fingerprint — as a typed queue rejection, the
            non-latching refusal class. *)
         if Astring.String.is_prefix ~affix:"cli-oneshot:" plan_fingerprint
         then (
           incr cli_bind_rejections;
           Error
             (Q.Exact_attempt_rejected (Q.Exact_attempt_summary_not_pending id)))
         else
           Q.bind_summary_exact_attempt
             ~id
             ~input_hash
             ~sequence
             ~slot_id
             ~call_id
             ~plan_fingerprint
             ~request_body_sha256
       in
       let runner ~runtime_id ~system_prompt:_ ~prompt:_ =
         failf "no cli slot may run without a durable binding (%s)" runtime_id
       in
       Worker.For_testing.execute_prepared_flow_with_queue_ops
         ~queue_ops:(Worker.For_testing.make_exact_queue_ops ~bind ())
         ~cli_runner:runner
         ~net
         ~clock
         ~on_summary:(fun _ -> fail "a rejected walk delivered a summary")
         (prepare_exn entry)
       |> require_executed;
       check int "both cli binds were rejected" 2 !cli_bind_rejections;
       match Q.For_testing.get_pending_entry_unchecked ~id:entry.id with
       | Some
           { exact_attempt =
               QT.Exact_bound
                 { slot_id
                 ; status = QT.Exact_quarantined QT.Exact_flow_execution_failed
                 ; _
                 }
           ; summary_attempt_disposition = QT.Summary_attempt_settled
           ; _
           } ->
         check string
           "the settled identity is the released catalog slot"
           "hitl-cli-unreachable"
           slot_id
       | _ ->
         fail
           "a rejected cli walk must settle the released binding, not leave it \
            dangling")
;;

let test_cli_slot_answers_after_catalog_exhaustion () =
  run_eio @@ fun ~sw:_ ~net ~clock ->
  with_temp_dir "hitl-cli-summary" @@ fun base_path ->
  Fun.protect
    ~finally:Q.For_testing.reset_runtime_state
    (fun () ->
       install_queue base_path;
       Prompt_registry.set_markdown_dir
         (Masc_test_deps.source_path "config/prompts");
       with_cli_runtimes @@ fun () ->
       publish_unreachable_lane_with_cli
         ~cli_slot_ids:[ cli_primary ]
         ~source:"hitl-cli-summary";
       let entry = pending_entry ~base_path () in
       let seen_runtime = ref None in
       let runner ~runtime_id ~system_prompt:_ ~prompt =
         seen_runtime := Some runtime_id;
         check bool
           "the cli prompt carries the judgment contract"
           true
           (Astring.String.is_infix ~affix:"judgment" prompt);
         Ok (Yojson.Safe.to_string (judgment_json "approve"))
       in
       let summary = ref None in
       Worker.For_testing.execute_prepared_flow_with_queue_ops
         ~queue_ops:(exact_queue_ops ())
         ~cli_runner:runner
         ~net
         ~clock
         ~on_summary:(fun observed -> summary := Some observed)
         (prepare_exn entry)
       |> require_executed;
       check (option string) "the declared cli slot ran" (Some cli_primary) !seen_runtime;
       check bool "the cli summary reached on_summary" true (Option.is_some !summary);
       match Q.For_testing.get_pending_entry_unchecked ~id:entry.id with
       | Some
           { exact_attempt =
               QT.Exact_bound { slot_id; status = QT.Exact_completed; _ }
           ; _
           } ->
         check string "completion is bound to the cli identity" cli_primary slot_id
       | _ -> fail "the cli summary did not complete the durable attempt")
;;

let test_cli_walk_advances_past_domain_invalid_output () =
  run_eio @@ fun ~sw:_ ~net ~clock ->
  with_temp_dir "hitl-cli-advance" @@ fun base_path ->
  Fun.protect
    ~finally:Q.For_testing.reset_runtime_state
    (fun () ->
       install_queue base_path;
       Prompt_registry.set_markdown_dir
         (Masc_test_deps.source_path "config/prompts");
       with_cli_runtimes @@ fun () ->
       publish_unreachable_lane_with_cli
         ~cli_slot_ids:[ cli_primary; cli_secondary ]
         ~source:"hitl-cli-advance";
       let entry = pending_entry ~base_path () in
       let runner ~runtime_id ~system_prompt:_ ~prompt:_ =
         if String.equal runtime_id cli_primary
         then Ok "{}" (* valid JSON, invalid judgment domain *)
         else Ok (Yojson.Safe.to_string (judgment_json "require_human"))
       in
       let summary = ref None in
       Worker.For_testing.execute_prepared_flow_with_queue_ops
         ~queue_ops:(exact_queue_ops ())
         ~cli_runner:runner
         ~net
         ~clock
         ~on_summary:(fun observed -> summary := Some observed)
         (prepare_exn entry)
       |> require_executed;
       check bool "the second cli slot answered" true (Option.is_some !summary);
       match Q.For_testing.get_pending_entry_unchecked ~id:entry.id with
       | Some
           { exact_attempt =
               QT.Exact_bound { slot_id; status = QT.Exact_completed; _ }
           ; _
           } ->
         check string
           "completion is bound to the advancing cli identity"
           cli_secondary
           slot_id
       | _ -> fail "the advancing cli walk did not complete the durable attempt")
;;

let test_cli_walk_exhaustion_quarantines_the_last_cli_identity () =
  run_eio @@ fun ~sw:_ ~net ~clock ->
  with_temp_dir "hitl-cli-exhausted" @@ fun base_path ->
  Fun.protect
    ~finally:Q.For_testing.reset_runtime_state
    (fun () ->
       install_queue base_path;
       Prompt_registry.set_markdown_dir
         (Masc_test_deps.source_path "config/prompts");
       with_cli_runtimes @@ fun () ->
       publish_unreachable_lane_with_cli
         ~cli_slot_ids:[ cli_primary; cli_secondary ]
         ~source:"hitl-cli-exhausted";
       let entry = pending_entry ~base_path () in
       let runner ~runtime_id:_ ~system_prompt:_ ~prompt:_ =
         Error "subscription window exhausted"
       in
       Worker.For_testing.execute_prepared_flow_with_queue_ops
         ~queue_ops:(exact_queue_ops ())
         ~cli_runner:runner
         ~net
         ~clock
         ~on_summary:(fun _ -> fail "an exhausted cli walk delivered a summary")
         (prepare_exn entry)
       |> require_executed;
       match Q.For_testing.get_pending_entry_unchecked ~id:entry.id with
       | Some
           { exact_attempt =
               QT.Exact_bound
                 { slot_id
                 ; status = QT.Exact_quarantined QT.Exact_flow_execution_failed
                 ; _
                 }
           ; summary_attempt_disposition = QT.Summary_attempt_settled
           ; _
           } ->
         check string
           "the quarantined identity is the last cli slot"
           cli_secondary
           slot_id
       | _ -> fail "cli exhaustion did not quarantine under the last cli identity")
;;


(* The metric label text is the contract with anything reading the
   [HitlSummaryOutcomes] counter, so this suite keeps its own copy of every
   pair and checks the module still spells them the same way.

   [pinned_label] is deliberately an exhaustive match rather than a lookup:
   a variant added to [flow_outcome] stops this file from compiling until
   someone decides what the new branch is called on the wire. The list below
   is not enforced the same way -- nothing makes you append to it -- but the
   compile error lands first, which is where both get noticed. *)
let pinned_label : Worker.flow_outcome -> string = function
  | Ok_summary -> "ok_summary"
  | Ok_summary_cli -> "ok_summary_cli"
  | Source_resolved -> "exact_source_resolved"
  | Identity_unbound -> "exact_identity_unbound"
  | Identity_unbound_source_changed -> "exact_identity_unbound_source_changed"
  | Terminal_sync_unconfirmed -> "exact_terminal_sync_unconfirmed"
  | Terminal_persistence_failure -> "exact_terminal_persistence_failure"
  | Terminal_rejected -> "exact_terminal_rejected"
  | Provenance_mismatch -> "exact_provenance_mismatch"
  | Domain_invalid_output -> "exact_domain_invalid_output"
  | Attempt_replay -> "exact_attempt_replay"
  | Attempt_start_failed -> "exact_attempt_start_failed"
  | Measurement_start_failed -> "exact_measurement_start_failed"
  | Measurement_callback_failed -> "exact_measurement_callback_failed"
  | Candidates_exhausted -> "exact_candidates_exhausted"
  | Bind_failed -> "exact_bind_failed"
  | Release_failed -> "exact_release_failed"
  | Execution_failed -> "exact_execution_failed"
  | Cli_slots_exhausted -> "exact_cli_slots_exhausted"
  | Cli_released_without_binding -> "exact_cli_released_without_binding"
  | Cli_walk_fell_back -> "exact_cli_walk_fell_back"
  | Cli_release_unconfirmed -> "exact_cli_release_unconfirmed"
  | Cli_bind_unconfirmed -> "exact_cli_bind_unconfirmed"
  | Cli_bind_failed -> "exact_cli_bind_failed"
  | Cancellation -> "exact_cancellation"
  | Cancellation_settlement_failed -> "exact_cancellation_settlement_failed"
  | Crashed -> "crashed"
;;

let all_outcomes =
  Worker.
    [ Ok_summary
    ; Ok_summary_cli
    ; Source_resolved
    ; Identity_unbound
    ; Identity_unbound_source_changed
    ; Terminal_sync_unconfirmed
    ; Terminal_persistence_failure
    ; Terminal_rejected
    ; Provenance_mismatch
    ; Domain_invalid_output
    ; Attempt_replay
    ; Attempt_start_failed
    ; Measurement_start_failed
    ; Measurement_callback_failed
    ; Candidates_exhausted
    ; Bind_failed
    ; Release_failed
    ; Execution_failed
    ; Cli_slots_exhausted
    ; Cli_released_without_binding
    ; Cli_walk_fell_back
    ; Cli_release_unconfirmed
    ; Cli_bind_unconfirmed
    ; Cli_bind_failed
    ; Cancellation
    ; Cancellation_settlement_failed
    ; Crashed ]
;;

let test_outcome_labels_are_stable () =
  Alcotest.(check int)
    "every flow_outcome is listed"
    27
    (List.length all_outcomes);
  List.iter
    (fun outcome ->
       let expected = pinned_label outcome in
       Alcotest.(check string)
         (Printf.sprintf "label for %s" expected)
         expected
         (Worker.outcome_label outcome))
    all_outcomes
;;

let test_outcome_labels_are_distinct () =
  let labels = List.sort_uniq String.compare (List.map pinned_label all_outcomes) in
  Alcotest.(check int)
    "no two outcomes share a label"
    (List.length all_outcomes)
    (List.length labels)
;;

let () =
  run
    "Hitl_summary_worker"
    [ ( "domain"
      , [ test_case "typed judgments" `Quick test_parse_typed_judgments
        ; test_case "invalid judgment fails loud" `Quick test_invalid_judgment_fails_loud
        ; test_case "exact context bundle" `Quick test_context_bundle_is_exact
        ; test_case "host context identifies registered clone" `Quick
            test_host_context_identifies_registered_clone_and_destination_state
        ; test_case "host context reports missing task link" `Quick
            test_host_context_reports_a_missing_durable_task_link
        ; test_case "the judge is not shown the Keeper's reasoning" `Quick
            test_the_judge_is_not_shown_the_keepers_reasoning
        ; test_case "a turn without reasoning reports nothing cut" `Quick
            test_a_turn_without_reasoning_reports_nothing_cut
        ; test_case "a context of another shape is carried through" `Quick
            test_a_context_of_another_shape_is_carried_through
        ; test_case "the newest reasoning can be kept" `Quick
            test_the_newest_reasoning_can_be_kept
        ; test_case "the budget keeps the newest, not the first" `Quick
            test_the_budget_keeps_the_newest_not_the_first
        ; test_case
            "missing context is reported as partial"
            `Quick
            test_missing_context_is_reported_as_partial
        ; test_case
            "missing context does not change flow admission"
            `Quick
            test_missing_context_does_not_change_flow_admission
        ; test_case
            "closed nonhierarchical schema"
            `Quick
            test_schema_is_closed_nonhierarchical_contract
        ; test_case
            "JSON-syntax request is prompt-only and carries canonical schema"
            `Quick
            test_json_syntax_request_is_prompt_only_and_carries_canonical_domain_schema
        ; test_case
            "prompt is registry-owned"
            `Quick
            test_judge_effect_prompt_comes_from_registry
        ] )
    ; ( "production exact flow"
      , [ test_case
            "order completion and replay"
            `Quick
            test_flow_order_completion_and_replay
        ; test_case
            "pre-dispatch failure advances to AGENT_CORE successor"
            `Quick
            test_predispatch_failure_advances_only_to_agent_core_successor
        ; test_case
            "Keeper preference reorders the HITL lane"
            `Quick
            test_keeper_preference_reorders_the_hitl_lane
        ; test_case
            "JSON-syntax candidate admits without structured capability"
            `Quick
            test_json_syntax_candidate_is_admitted_without_structured_capability
        ; test_case
            "between-candidate cancellation terminalizes released identity"
            `Quick
            test_cancellation_between_candidates_terminalizes_released_identity
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
            "completion identity conflict stays deterministic"
            `Quick
            test_completion_identity_conflict_stays_deterministic
        ; test_case
            "flow execution failure quarantines and allows successor"
            `Quick
            test_flow_execution_failure_quarantines_and_allows_successor
        ; test_case
            "manual resolution race is conclusive"
            `Quick
            test_manual_resolution_race_is_conclusive
        ; test_case
            "post-dispatch cancellation is terminal"
            `Quick
            test_cancellation_after_dispatch_is_terminal
        ; test_case
            "spawn preserves cancellation origin backtrace"
            `Quick
            test_spawn_preserves_cancellation_origin_backtrace
        ; test_case
            "pre-bind cancellation withholds production Gate drain"
            `Quick
            test_prebind_cancellation_withholds_production_gate_drain
        ; test_case
            "bound cancellation cleanup uncertainty preserves origin"
            `Quick
            test_bound_cancellation_cleanup_uncertainty_preserves_origin
        ; test_case
            "pre-worker start failure preserves unbound pending"
            `Quick
            test_pre_worker_start_failure_preserves_unbound_pending
        ; test_case
            "worker start survives Keeper turn stop"
            `Quick
            test_detached_worker_start_survives_keeper_turn_stop
        ; test_case
            "visible uncertainty withholds production drain"
            `Quick
            test_visible_uncertainty_withholds_production_drain
        ; test_case
            "same-owner workers run in parallel within the bound"
            `Quick
            test_same_owner_workers_run_in_parallel_with_bound
        ; test_case
            "Require_human head does not stop owner drain"
            `Quick
            test_require_human_head_does_not_stop_owner_drain
        ] )
    ; ( "cli_lane_slots"
      , [ test_case
            "cli bind rejection after release settles the entry"
            `Quick
            test_cli_bind_rejection_after_release_settles_the_entry
        ; test_case
            "a cli slot answers after catalog exhaustion"
            `Quick
            test_cli_slot_answers_after_catalog_exhaustion
        ; test_case
            "the cli walk advances past domain-invalid output"
            `Quick
            test_cli_walk_advances_past_domain_invalid_output
        ; test_case
            "cli exhaustion quarantines the last cli identity"
            `Quick
            test_cli_walk_exhaustion_quarantines_the_last_cli_identity
        ] )
    ; ( "flow_outcome_labels"
      , [ test_case
            "every outcome keeps its metric label"
            `Quick
            test_outcome_labels_are_stable
        ; test_case
            "no two outcomes share a label"
            `Quick
            test_outcome_labels_are_distinct
        ] )
    ; ( "run_registry_outcome"
      , [ test_case
            "an observed summary earns Succeeded"
            `Quick
            test_observed_summary_earns_succeeded
        ; test_case
            "a missing summary earns Failed"
            `Quick
            test_missing_summary_earns_failed
        ; test_case
            "a missing summary reports the branch it died on"
            `Quick
            test_missing_summary_reports_the_last_branch
        ] )
    ]
;;
