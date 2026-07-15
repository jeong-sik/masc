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
         ; "agent_name", `String name
         ; "trace_id", `String ("trace-" ^ name)
         ; "allowed_paths", `List [ `String "*" ]
         ])
  with
  | Error error -> fail ("meta fixture rejected: " ^ error)
  | Ok meta ->
    if always_allow then { meta with always_allow = Some true } else meta
;;

let json_error raw =
  Yojson.Safe.from_string raw
  |> Yojson.Safe.Util.member "error"
  |> Yojson.Safe.Util.to_string
;;

let with_clean_gate_runtime f =
  Keeper_approval_queue.For_testing.reset_runtime_state ();
  Fun.protect
    ~finally:Keeper_approval_queue.For_testing.reset_runtime_state
    f
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
        (Tool_result.ok
           ~tool_name:name
           ~start_time:0.0
           {|{"ok":true,"effect":"ran"}|})
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
    check yojson
      "first result"
      (Tool_result.data first_result)
      Yojson.Safe.Util.(call |> member "result")
  | _ -> failf "expected one completed call, got %d" (List.length calls)
;;

let test_keeper_effects_defer_without_dispatch () =
  with_clean_gate_runtime @@ fun () ->
  let base_path = temp_dir "keeper-gate-deferred" in
  Fun.protect ~finally:(fun () -> remove_tree base_path) @@ fun () ->
  let config = Workspace.default_config base_path in
  (match Keeper_gate_mode.set config ~actor:"test" Keeper_gate_mode.Manual with
   | Ok _ -> ()
   | Error error -> fail ("failed to select manual Gate mode: " ^ error));
  let meta = make_meta "gate-deferred-keeper" in
  with_publication_recovery
    ~registry_root:base_path
    ~meta
  @@ fun publication_recovery ->
  with_keeper_dispatch_probe @@ fun calls ->
  List.iter
    (fun name ->
       let args = `Assoc [ "opaque", `String name ] in
         let raw =
           Keeper_tool_in_process_runtime.handle_masc_keeper
           ~publication_recovery_provider:publication_recovery.provider
           ~config
           ~meta
           ~name
           ~args
           ()
       in
       check string (name ^ " defers") "gate_deferred" (json_error raw))
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
         let raw =
           Keeper_tool_in_process_runtime.handle_masc_keeper
           ~publication_recovery_provider:publication_recovery.provider
           ~config
           ~meta
           ~name
           ~args:(`Assoc [ "opaque", `String name ])
           ()
       in
       check string (name ^ " unavailable") "gate_unavailable" (json_error raw))
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
         let raw =
           Keeper_tool_in_process_runtime.handle_masc_keeper
           ~publication_recovery_provider:publication_recovery.provider
           ~config
           ~meta
           ~name
           ~args
           ()
       in
       check string
         (name ^ " proceeds")
         "ran"
         Yojson.Safe.Util.(member "effect" (Yojson.Safe.from_string raw) |> to_string))
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
  let meta = make_meta "ollama-gate-deferred-keeper" in
  let deferred =
    Keeper_tool_in_process_runtime.handle_masc_local_runtime
      ~config:deferred_config
      ~meta
      ~name:ollama_probe_name
      ~args:ollama_probe_input
      ()
  in
  check string "probe defers" "gate_deferred" (json_error deferred);
  let unavailable =
    Keeper_tool_in_process_runtime.handle_masc_local_runtime
      ~config:(Workspace.default_config "/dev/null")
      ~meta
      ~name:ollama_probe_name
      ~args:ollama_probe_input
      ()
  in
  check string "probe unavailable" "gate_unavailable" (json_error unavailable);
  ()
;;

let test_ollama_probe_allow_dispatches_exact_input () =
  with_clean_gate_runtime @@ fun () ->
  let base_path = temp_dir "ollama-gate-allow" in
  Fun.protect ~finally:(fun () -> remove_tree base_path) @@ fun () ->
  let config = Workspace.default_config base_path in
  let meta = make_meta ~always_allow:true "ollama-gate-allow-keeper" in
  ignore (Keeper_registry.register ~base_path meta.name meta);
  Fun.protect
    ~finally:(fun () -> Keeper_registry.unregister ~base_path meta.name)
  @@ fun () ->
  let raw =
    Keeper_tool_in_process_runtime.handle_masc_local_runtime
      ~config
      ~meta
      ~name:ollama_probe_name
      ~args:ollama_probe_input
      ()
  in
  let json = Yojson.Safe.from_string raw in
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

let () =
  run
    "keeper_gate_effect_coverage"
    [ ( "causal_context"
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
    ]
;;
