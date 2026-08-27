open Alcotest
open Masc

let yojson = testable Yojson.Safe.pp Yojson.Safe.equal

let temp_dir prefix =
  let path = Filename.temp_file prefix "" in
  Unix.unlink path;
  Unix.mkdir path 0o755;
  path
;;

let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Unix.unlink path
;;

let make_meta ?(always_allow = false) name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         [ "name", `String name
         ; "agent_name", `String (Masc.Keeper_identity.keeper_agent_name name)
         ; "trace_id", `String ("trace-" ^ name)
         ; "allowed_paths", `List [ `String "*" ]
         ])
  with
  | Error error -> fail ("meta fixture rejected: " ^ error)
  | Ok meta ->
    if always_allow then { meta with always_allow = Some true } else meta
;;

let expect_completed label (result : Keeper_tool_execution.t) =
  match result.disposition with
  | Tool_result.Completed () -> ()
  | Tool_result.Deferred () | Tool_result.Failed _ -> fail (label ^ ": not completed")
;;

let expect_deferred label (result : Keeper_tool_execution.t) =
  match result.disposition with
  | Tool_result.Deferred () -> ()
  | Tool_result.Completed () | Tool_result.Failed _ -> fail (label ^ ": not deferred")
;;

let expect_failed label expected (result : Keeper_tool_execution.t) =
  match result.disposition with
  | Tool_result.Failed actual ->
    check string
      label
      (Tool_result.tool_failure_class_to_string expected)
      (Tool_result.tool_failure_class_to_string actual)
  | Tool_result.Completed () | Tool_result.Deferred () -> fail (label ^ ": not failed")
;;

let with_clean_gate_runtime f =
  Keeper_approval_queue.For_testing.reset_runtime_state ();
  Fun.protect
    ~finally:Keeper_approval_queue.For_testing.reset_runtime_state
    f
;;

let install_exn ~base_path =
  match Keeper_approval_queue.install_persistence ~base_path with
  | Ok report -> report
  | Error error -> fail (Keeper_approval_queue.install_error_to_string error)
;;

let with_publication_recovery
      ~registry_root
      ~(meta : Keeper_meta_contract.keeper_meta)
      f
  =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.with_publication_recovery_registry
    ~sw
    ~fs:(Eio.Stdenv.fs env)
    ~registry_root
    (fun publication_recovery_registry ->
       let publication_recovery =
         Keeper_publication_recovery_availability.
           { provider =
               Masc_test_deps.publication_recovery_provider
                 publication_recovery_registry
           ; keeper_name = meta.name
           }
       in
       f publication_recovery)
;;

let with_keeper_dispatch_probe f =
  let original = !Keeper_dispatch_ref.dispatch in
  let calls = ref [] in
  let dispatch
        ~config:_
        ~agent_name:_
        ~publication_recovery_provider:_
        ?sw:_
        ?clock:_
        ?proc_mgr:_
        ?net:_
        ?mcp_session_id:_
        ?authorize_external_effect
        ~name
        ~args
        ()
    =
    let continue () =
      calls := (name, args) :: !calls;
      Some
        (Tool_result.make_ok
           ~tool_name:name
           ~start_time:0.0
           ~data:(`Assoc [ "effect", `String "ran" ])
           ())
    in
    match authorize_external_effect with
    | None -> continue ()
    | Some authorize -> authorize ~operation:name ~input:args ~continue
  in
  Keeper_dispatch_ref.dispatch := dispatch;
  Fun.protect
    ~finally:(fun () -> Keeper_dispatch_ref.dispatch := original)
    (fun () -> f calls)
;;

let keeper_effect_names =
  [ "masc_keeper_sandbox_start"
  ; "masc_keeper_sandbox_stop"
  ; "masc_keeper_down"
  ; "masc_keeper_clear"
  ]
;;

let test_second_tool_snapshot_contains_first_tool_result () =
  let context =
    Keeper_gate_causal_context.create
      ~turn_id:(Some 17)
      ~initial:(`Assoc [ "user_message", `String "inspect, then act" ])
  in
  let first_input = `Assoc [ "path", `String "README.md" ] in
  let first_result =
    Tool_result.ok
      ~tool_name:"tool_read_file"
      ~start_time:0.0
      {|{"ok":true,"content":"exact evidence"}|}
  in
  Keeper_gate_causal_context.record_tool_result
    context
    ~operation:"tool_read_file"
    ~input:first_input
    first_result;
  let second_call_context = Keeper_gate_causal_context.snapshot context in
  check (option int) "same turn" (Some 17) second_call_context.turn_id;
  let calls =
    second_call_context.snapshot
    |> Yojson.Safe.Util.member "completed_tool_calls"
    |> Yojson.Safe.Util.to_list
  in
  match calls with
  | [ call ] ->
    check string
      "first operation"
      "tool_read_file"
      Yojson.Safe.Util.(call |> member "operation" |> to_string);
    check yojson "first input" first_input Yojson.Safe.Util.(call |> member "input");
    check
      string
      "first disposition"
      (Tool_result.string_of_disposition first_result)
      Yojson.Safe.Util.(call |> member "disposition" |> to_string);
    (* [result] is deliberately absent from this rendering. The cell records the
       typed result, but the judge is asked to weigh operation identity and
       input, never the payload a previous tool returned; rendering it put whole
       tool outputs into a prompt about a different call and the judge slot
       refused them. [disposition] carries the part the judgment turns on.
       Asserting absence rather than dropping the check keeps a re-added
       [result] failing here instead of silently restoring that shape. *)
    check
      bool
      "first result stays out of the judge rendering"
      true
      (match Yojson.Safe.Util.(call |> member "result") with
       | `Null -> true
       | _ -> false)
  | _ -> failf "expected one completed call, got %d" (List.length calls)
;;

(* Per-keeper overrides. The point is which way they move: a keeper an
   operator singled out is one they want held to a higher bar, and an
   override asking for less than the workspace has to stay ineffective. *)
let with_workspace f =
  let base_path = temp_dir "keeper-gate-mode" in
  Fun.protect ~finally:(fun () -> remove_tree base_path) @@ fun () ->
  f (base_path, Workspace.default_config base_path)

let select_workspace config mode =
  match Keeper_gate_mode.set config ~actor:"test" mode with
  | Ok _ -> ()
  | Error error -> fail ("failed to select workspace Gate mode: " ^ error)

let single_out config ~keeper_name mode =
  match Keeper_gate_mode.set_for_keeper config ~actor:"test" ~keeper_name mode with
  | Ok change -> change
  | Error error -> fail ("failed to set a keeper Gate mode: " ^ error)

let resolved ~base_path ~keeper_name =
  match Keeper_gate_mode.resolve ~base_path ~keeper_name with
  | Ok mode -> Keeper_gate_mode.to_string mode
  | Error error -> fail ("failed to resolve a Gate mode: " ^ error)

let test_a_keeper_with_no_override_follows_the_workspace () =
  with_workspace @@ fun (base_path, config) ->
  select_workspace config Keeper_gate_mode.Auto_judge;
  check string "the workspace answer" "auto_judge"
    (resolved ~base_path ~keeper_name:"unmentioned")

let test_an_override_can_hold_one_keeper_higher () =
  (* The reason this exists: one keeper attached to somebody else's Jira
     while the rest of the workspace is not. *)
  with_workspace @@ fun (base_path, config) ->
  select_workspace config Keeper_gate_mode.Auto_judge;
  ignore (single_out config ~keeper_name:"kidsnote" (Some Keeper_gate_mode.Manual));
  check string "the singled-out keeper asks a person" "manual"
    (resolved ~base_path ~keeper_name:"kidsnote");
  check string "and nobody else moved" "auto_judge"
    (resolved ~base_path ~keeper_name:"rondo")

let test_an_override_cannot_lower_one_keeper () =
  (* Turning the workspace stricter must not be undoable one keeper at a
     time by an older row nobody remembers writing. *)
  with_workspace @@ fun (base_path, config) ->
  select_workspace config Keeper_gate_mode.Manual;
  ignore
    (single_out config ~keeper_name:"kidsnote" (Some Keeper_gate_mode.Always_allow));
  check string "the workspace still decides" "manual"
    (resolved ~base_path ~keeper_name:"kidsnote")

let test_a_lower_override_waits_rather_than_being_lost () =
  (* Kept on disk, ignored on read. An operator who set one and then
     tightened the workspace should find it again when they loosen back,
     rather than silently having lost it. *)
  with_workspace @@ fun (base_path, config) ->
  select_workspace config Keeper_gate_mode.Manual;
  ignore
    (single_out config ~keeper_name:"kidsnote" (Some Keeper_gate_mode.Auto_judge));
  (match Keeper_gate_mode.keeper_override ~base_path ~keeper_name:"kidsnote" with
   | Ok (Some o) ->
     check string "what was asked for is still recorded" "auto_judge"
       (Keeper_gate_mode.to_string o.Keeper_gate_mode.mode)
   | Ok None -> fail "the override was dropped instead of kept"
   | Error error -> fail ("failed to read the override: " ^ error))

let test_clearing_an_override_removes_it () =
  with_workspace @@ fun (base_path, config) ->
  select_workspace config Keeper_gate_mode.Auto_judge;
  ignore (single_out config ~keeper_name:"kidsnote" (Some Keeper_gate_mode.Manual));
  ignore (single_out config ~keeper_name:"kidsnote" None);
  (match Keeper_gate_mode.keeper_overrides ~base_path with
   | Ok [] -> ()
   | Ok rows ->
     failf "clearing left %d override(s) behind" (List.length rows)
   | Error error -> fail ("failed to read the overrides: " ^ error));
  check string "and the keeper is back on the workspace answer" "auto_judge"
    (resolved ~base_path ~keeper_name:"kidsnote")

let test_an_unreadable_override_file_is_not_an_empty_list () =
  (* An empty list answers with the workspace mode, which is the looser one.
     A file that cannot be read must not be the quiet way back to it. *)
  with_workspace @@ fun (base_path, _config) ->
  let file = Keeper_gate_path.keeper_modes ~base_path in
  Fs_compat.mkdir_p (Keeper_gate_path.dir ~base_path);
  (match Fs_compat.save_file_atomic file "{ not a list" with
   | Ok () -> ()
   | Error detail -> fail ("could not write the fixture: " ^ detail));
  match Keeper_gate_mode.resolve ~base_path ~keeper_name:"kidsnote" with
  | Error _ -> ()
  | Ok mode ->
    failf "an unreadable override file resolved to %s"
      (Keeper_gate_mode.to_string mode)

let test_keeper_effects_defer_without_dispatch () =
  with_clean_gate_runtime @@ fun () ->
  let base_path = temp_dir "keeper-gate-deferred" in
  Fun.protect ~finally:(fun () -> remove_tree base_path) @@ fun () ->
  let config = Workspace.default_config base_path in
  (match Keeper_gate_mode.set config ~actor:"test" Keeper_gate_mode.Manual with
   | Ok _ -> ()
   | Error error -> fail ("failed to select manual Gate mode: " ^ error));
  ignore (install_exn ~base_path);
  let meta = make_meta "gate-deferred-keeper" in
  with_publication_recovery
    ~registry_root:base_path
    ~meta
  @@ fun publication_recovery ->
  with_keeper_dispatch_probe @@ fun calls ->
  List.iter
    (fun name ->
       let args = `Assoc [ "opaque", `String name ] in
         let result =
           Keeper_tool_in_process_runtime.handle_masc_keeper_with_outcome
           ~publication_recovery_provider:publication_recovery.provider
           ~config
           ~meta
           ~name
           ~args
           ()
       in
       expect_deferred (name ^ " defers") result)
    keeper_effect_names;
  check int "no Keeper effect dispatched" 0 (List.length !calls)
;;

let test_keeper_effects_unavailable_without_dispatch () =
  with_clean_gate_runtime @@ fun () ->
  let config = Workspace.default_config "/dev/null" in
  let meta = make_meta "gate-unavailable-keeper" in
  let registry_root = temp_dir "keeper-gate-unavailable-registry" in
  Fun.protect ~finally:(fun () -> remove_tree registry_root) @@ fun () ->
  with_publication_recovery
    ~registry_root
    ~meta
  @@ fun publication_recovery ->
  with_keeper_dispatch_probe @@ fun calls ->
  List.iter
    (fun name ->
         let result =
           Keeper_tool_in_process_runtime.handle_masc_keeper_with_outcome
           ~publication_recovery_provider:publication_recovery.provider
           ~config
           ~meta
           ~name
           ~args:(`Assoc [ "opaque", `String name ])
           ()
       in
       expect_failed
         (name ^ " unavailable")
         Tool_result.Runtime_failure
         result)
    keeper_effect_names;
  check int "unavailable Gate executes no Keeper effect" 0 (List.length !calls)
;;

let test_keeper_effects_allow_exact_dispatch () =
  with_clean_gate_runtime @@ fun () ->
  let base_path = temp_dir "keeper-gate-allow" in
  Fun.protect ~finally:(fun () -> remove_tree base_path) @@ fun () ->
  let config = Workspace.default_config base_path in
  let meta = make_meta ~always_allow:true "gate-allow-keeper" in
  with_publication_recovery
    ~registry_root:base_path
    ~meta
  @@ fun publication_recovery ->
  with_keeper_dispatch_probe @@ fun calls ->
  List.iter
    (fun name ->
       let args = `Assoc [ "opaque", `String name ] in
         let result =
           Keeper_tool_in_process_runtime.handle_masc_keeper_with_outcome
           ~publication_recovery_provider:publication_recovery.provider
           ~config
           ~meta
           ~name
           ~args
           ()
       in
       expect_completed (name ^ " proceeds") result;
       let data = Option.value ~default:`Null result.data in
       check string
         (name ^ " proceeds")
         "ran"
         Yojson.Safe.Util.(member "effect" data |> to_string))
    keeper_effect_names;
  let observed = List.rev !calls in
  check
    (list (pair string string))
    "each exact operation and complete input dispatched once"
    (List.map (fun name -> name, name) keeper_effect_names)
    (List.map
       (fun (name, input) ->
          name,
          Yojson.Safe.Util.(member "opaque" input |> to_string))
       observed)
;;

let ollama_probe_name = "masc_runtime_ollama_probe"
let ollama_probe_input =
  `Assoc
    [ "server_url", `String "http://127.0.0.1:1"
    ; "run_generate", `Bool false
    ; "timeout_sec", `Int 3
    ]

let test_ollama_probe_defer_and_unavailable_do_not_dispatch () =
  with_clean_gate_runtime @@ fun () ->
  let deferred_base = temp_dir "ollama-gate-deferred" in
  Fun.protect ~finally:(fun () -> remove_tree deferred_base) @@ fun () ->
  let deferred_config = Workspace.default_config deferred_base in
  (match
     Keeper_gate_mode.set
       deferred_config
       ~actor:"test"
       Keeper_gate_mode.Manual
   with
   | Ok _ -> ()
   | Error error -> fail ("failed to select manual Gate mode: " ^ error));
  ignore (install_exn ~base_path:deferred_base);
  let meta = make_meta "ollama-gate-deferred-keeper" in
  let deferred =
    Keeper_tool_in_process_runtime.handle_masc_local_runtime_with_outcome
      ~config:deferred_config
      ~meta
      ~name:ollama_probe_name
      ~args:ollama_probe_input
      ()
  in
  expect_deferred "probe defers" deferred;
  let unavailable =
    Keeper_tool_in_process_runtime.handle_masc_local_runtime_with_outcome
      ~config:(Workspace.default_config "/dev/null")
      ~meta
      ~name:ollama_probe_name
      ~args:ollama_probe_input
      ()
  in
  expect_failed "probe unavailable" Tool_result.Runtime_failure unavailable;
  ()
;;

let test_ollama_probe_allow_dispatches_exact_input () =
  with_clean_gate_runtime @@ fun () ->
  let base_path = temp_dir "ollama-gate-allow" in
  Fun.protect ~finally:(fun () -> remove_tree base_path) @@ fun () ->
  let config = Workspace.default_config base_path in
  let meta = make_meta ~always_allow:true "ollama-gate-allow-keeper" in
  ignore (Keeper_registry.For_testing.register ~base_path meta.name meta);
  Fun.protect
    ~finally:(fun () -> Keeper_registry.For_testing.unregister ~base_path meta.name)
  @@ fun () ->
  let result =
    Keeper_tool_in_process_runtime.handle_masc_local_runtime_with_outcome
      ~config
      ~meta
      ~name:ollama_probe_name
      ~args:ollama_probe_input
    ()
  in
  expect_completed "Always Allow proceeds" result;
  let json = Option.value ~default:`Null result.data in
  check bool
    "Always Allow proceeds into the runtime handler"
    true
    Yojson.Safe.Util.(member "result" json <> `Null)
;;

let test_ollama_probe_leaf_requests_exact_authorization () =
  let calls = ref [] in
  let authorize_external_effect ~operation ~input ~continue:_ =
    calls := (operation, input) :: !calls;
    Tool_result.ok
      ~tool_name:operation
      ~start_time:0.0
      {|{"ok":true,"effect":"intercepted"}|}
  in
  let result =
    Tool_local_runtime.dispatch
      { Tool_local_runtime_core.config = Workspace.default_config "/tmp"
      ; agent_name = "leaf-probe"
      ; authorize_external_effect = Some authorize_external_effect
      }
      ~name:ollama_probe_name
      ~args:ollama_probe_input
  in
  (match result with
   | Some result ->
     check bool "authorizer intercepts before network" true (Tool_result.is_success result)
   | None -> fail "Ollama probe handler was not selected");
  match !calls with
  | [ operation, input ] ->
    check string "exact operation" ollama_probe_name operation;
    check string
      "complete input"
      (Yojson.Safe.to_string ollama_probe_input)
      (Yojson.Safe.to_string input)
  | calls -> failf "expected one authorization request, got %d" (List.length calls)
;;

let test_voice_effect_defers_without_gating_local_reads () =
  with_clean_gate_runtime @@ fun () ->
  let base_path = temp_dir "voice-gate-effect" in
  Fun.protect ~finally:(fun () -> remove_tree base_path) @@ fun () ->
  let config = Workspace.default_config base_path in
  (match Keeper_gate_mode.set config ~actor:"test" Keeper_gate_mode.Manual with
   | Ok _ -> ()
   | Error error -> fail ("failed to select manual Gate mode: " ^ error));
  ignore (install_exn ~base_path);
  let meta = make_meta "voice-gate-keeper" in
  let listen_input =
    `Assoc
      [ "timeout_seconds", `Float 3.0
      ; "language_code", `String "ko-KR"
      ]
  in
  let listen =
    Keeper_tool_in_process_runtime.handle_voice_with_outcome
      ~config
      ~meta
      ~name:"keeper_voice_listen"
      ~args:listen_input
      ()
  in
  expect_deferred "microphone/STT effect defers before execution" listen;
  let pending_entries () =
    match
      Keeper_approval_queue.list_pending_entries_for_workspace
        ~base_path:config.base_path
    with
    | Ok entries -> entries
    | Error error ->
      fail (Keeper_approval_queue.storage_error_to_string error)
  in
  check int "one exact voice effect is pending" 1 (List.length (pending_entries ()));
  (match pending_entries () with
   | [ pending ] ->
     check string "request belongs to the calling Keeper" meta.name pending.keeper_name;
     check string "opaque operation is preserved" "keeper_voice_listen" pending.tool_name;
     check yojson "complete input is preserved" listen_input pending.input
   | pending -> failf "expected one pending voice effect, got %d" (List.length pending));
  let capability_read =
    Keeper_tool_in_process_runtime.handle_voice_with_outcome
      ~config
      ~meta
      ~name:"keeper_voice_agent"
      ~args:(`Assoc [])
      ()
  in
  expect_completed "local voice capability read remains ungated" capability_read;
  check int
    "local read creates no second Gate request"
    1
    (List.length (pending_entries ()))
;;

let () =
  run
    "keeper_gate_effect_coverage"
    [ ( "per-keeper mode"
      , [ test_case "no override follows the workspace" `Quick
            test_a_keeper_with_no_override_follows_the_workspace
        ; test_case "an override can hold one keeper higher" `Quick
            test_an_override_can_hold_one_keeper_higher
        ; test_case "an override cannot lower one keeper" `Quick
            test_an_override_cannot_lower_one_keeper
        ; test_case "a lower override waits rather than being lost" `Quick
            test_a_lower_override_waits_rather_than_being_lost
        ; test_case "clearing an override removes it" `Quick
            test_clearing_an_override_removes_it
        ; test_case "an unreadable override file is not an empty list" `Quick
            test_an_unreadable_override_file_is_not_an_empty_list
        ] )
    ; ( "causal_context"
      , [ test_case
            "second tool snapshot contains first tool result"
            `Quick
            test_second_tool_snapshot_contains_first_tool_result
        ] )
    ; ( "keeper_effects"
      , [ test_case
            "Deferred executes no sandbox/lifecycle effect"
            `Quick
            test_keeper_effects_defer_without_dispatch
        ; test_case
            "Unavailable executes no sandbox/lifecycle effect"
            `Quick
            test_keeper_effects_unavailable_without_dispatch
        ; test_case
            "Allow dispatches exact sandbox/lifecycle effect"
            `Quick
            test_keeper_effects_allow_exact_dispatch
        ] )
    ; ( "network_probe"
      , [ test_case
            "Deferred and Unavailable execute no network probe"
            `Quick
            test_ollama_probe_defer_and_unavailable_do_not_dispatch
        ; test_case
            "Allow dispatches exact network probe"
            `Quick
            test_ollama_probe_allow_dispatches_exact_input
        ; test_case
            "effect leaf requests exact authorization"
            `Quick
            test_ollama_probe_leaf_requests_exact_authorization
        ] )
    ; ( "voice"
      , [ test_case
            "external effect defers without gating local reads"
            `Quick
            test_voice_effect_defers_without_gating_local_reads
        ] )
    ]
;;
