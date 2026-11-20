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
         ; "trace_id", `String ("trace-" ^ name)
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
  | Error error -> fail (Masc.Keeper_approval_queue_result.install_error_to_string error)
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
           ~start_time:(Tool_timing.start ())
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
    Keeper_gate_causal_context.create ~origin:Keeper_approval_origin.unavailable
      ~turn_id:(Some 17)
      ~initial:(`Assoc [ "user_message", `String "inspect, then act" ])
  in
  let first_input = `Assoc [ "path", `String "README.md" ] in
  let first_result =
    Tool_result.ok
      ~tool_name:"tool_read_file"
      ~start_time:(Tool_timing.start ())
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

let select_workspace config mode =
  match Keeper_gate_mode.set config ~actor:"test" mode with
  | Ok _ -> ()
  | Error error -> fail ("failed to select workspace Gate mode: " ^ error)

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

(* YOLO is read in one place -- the PreToolUse hook that asks over the open
   chat stream -- and the Gate is not it. Before 2026-08-27 those happened to
   look like the same setting, because writing to somebody else's Jira did not
   reach the Gate at all. Now it does, and an operator who pressed `g yolo`
   must not be able to believe otherwise. *)
let test_yolo_does_not_carry_a_call_past_the_gate () =
  with_clean_gate_runtime @@ fun () ->
  let base_path = temp_dir "keeper-gate-yolo" in
  Fun.protect ~finally:(fun () -> remove_tree base_path) @@ fun () ->
  let config = Workspace.default_config base_path in
  (match Keeper_gate_mode.set config ~actor:"test" Keeper_gate_mode.Manual with
   | Ok _ -> ()
   | Error error -> fail ("failed to select manual Gate mode: " ^ error));
  ignore (install_exn ~base_path);
  let meta = make_meta "gate-yolo-keeper" in
  ignore
    (Keeper_tool_approval_mode.set
       (Keeper_tool_approval_mode.shared ())
       ~base_path ~actor:"test" ~keeper_name:"gate-yolo-keeper"
       Keeper_tool_approval_mode.Yolo);
  Fun.protect
    ~finally:(fun () ->
      ignore
        (Keeper_tool_approval_mode.set
           (Keeper_tool_approval_mode.shared ())
           ~base_path ~actor:"test" ~keeper_name:"gate-yolo-keeper"
           Keeper_tool_approval_mode.Auto))
  @@ fun () ->
  (* The stance is in force -- otherwise this test would pass by not having
     set anything. *)
  check bool "the keeper is on YOLO" true
    (Keeper_tool_approval_mode.resolve
       (Keeper_tool_approval_mode.shared ())
       ~keeper_name:"gate-yolo-keeper"
     = Keeper_tool_approval_mode.Yolo);
  with_publication_recovery ~registry_root:base_path ~meta
  @@ fun publication_recovery ->
  with_keeper_dispatch_probe @@ fun calls ->
  List.iter
    (fun name ->
      let args = `Assoc [ "opaque", `String name ] in
      let result =
        Keeper_tool_in_process_runtime.handle_masc_keeper_with_outcome
          ~publication_recovery_provider:publication_recovery.provider
          ~config ~meta ~name ~args ()
      in
      expect_deferred (name ^ " still defers under YOLO") result)
    keeper_effect_names;
  check int "no Keeper effect dispatched under YOLO" 0 (List.length !calls)
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
       (* The approval machinery was unavailable, so the effect provably did
          not run. That is a missing dependency, not a fault in the call:
          Runtime_failure would reach the model as an uncertain outcome. *)
       expect_failed
         (name ^ " unavailable")
         Tool_result.Dependency_unavailable
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
  expect_failed "probe unavailable" Tool_result.Dependency_unavailable unavailable;
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
      ~start_time:(Tool_timing.start ())
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

(* Speak reaches the Gate only from a runtime that could actually speak: its
   handler asks the Eio context for a switch, a clock and a net first, and
   without all three it returns a text-fallback payload and never authorizes
   anything. That is the right shape -- nothing left the process, so there was
   no external effect to review -- but it means a test with no Eio context
   measures the fallback instead of the boundary. The Gate defers before it
   runs the continuation, so installing the context here queues the request
   without any speech being synthesized. *)
let test_voice_effect_defers_without_gating_local_reads () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  Eio_context.set_switch sw;
  Eio_context.set_clock (Eio.Stdenv.clock env);
  Eio_context.set_net (Eio.Stdenv.net env);
  with_clean_gate_runtime @@ fun () ->
  let base_path = temp_dir "voice-gate-effect" in
  Fun.protect ~finally:(fun () -> remove_tree base_path) @@ fun () ->
  (* Voice refuses an unconfigured provider before asking for approval. Give
     this effect-boundary test a real configuration; Manual Gate must prevent
     its loopback endpoint from being dispatched. Keep the config root isolated
     from the runner's environment and restore the resolver afterward. *)
  let config_root = Filename.concat base_path "voice-config" in
  Unix.mkdir config_root 0o755;
  let runtime_path = Filename.concat config_root "runtime.toml" in
  Out_channel.with_open_text runtime_path (fun channel ->
    output_string channel
      {|[voice.tts]
default_model = "gate-test-tts"
default_voice = "gate-test-voice"
[[voice.tts.endpoints]]
id = "gate-test-tts"
kind = "openai_compat"
base_url = "http://127.0.0.1:1/v1"
|});
  let previous_config_root = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Unix.putenv "MASC_CONFIG_DIR" config_root;
  Config_dir_resolver.reset ();
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "MASC_CONFIG_DIR" (Option.value ~default:"" previous_config_root);
      Config_dir_resolver.reset ())
  @@ fun () ->
  (match Voice_config.load_detailed () with
   | Ok _ -> ()
   | Error error -> fail ("voice fixture failed: " ^ Voice_config.load_error_to_string error));
  let config = Workspace.default_config base_path in
  (match Keeper_gate_mode.set config ~actor:"test" Keeper_gate_mode.Manual with
   | Ok _ -> ()
   | Error error -> fail ("failed to select manual Gate mode: " ^ error));
  ignore (install_exn ~base_path);
  let meta = make_meta "voice-gate-keeper" in
  let pending_entries () =
    match
      Keeper_approval_queue.list_pending_entries_for_workspace
        ~base_path:config.base_path
    with
    | Ok entries -> entries
    | Error error ->
      fail (Masc.Keeper_approval_queue_result.storage_error_to_string error)
  in
  let speak_input = `Assoc [ "message", `String "gate coverage probe" ] in
  let speak =
    Keeper_tool_in_process_runtime.handle_voice_with_outcome
      ~config
      ~meta
      ~name:"keeper_voice_speak"
      ~args:speak_input
      ()
  in
  expect_deferred "TTS/playback effect defers before execution" speak;
  check int "one exact voice effect is pending" 1 (List.length (pending_entries ()));
  (match pending_entries () with
   | [ pending ] ->
     check string "request belongs to the calling Keeper" meta.name pending.keeper_name;
     check string "opaque operation is preserved" "keeper_voice_speak" pending.tool_name;
     check yojson "complete input is preserved" speak_input pending.input
   | pending -> failf "expected one pending voice effect, got %d" (List.length pending));
  (* The microphone window cannot survive the approval cycle, so listening
     never becomes a Gate request: it runs directly and its outcome belongs
     to the microphone — a failure here (CI has none) must not queue an
     approval either. *)
  ignore
    (Keeper_tool_in_process_runtime.handle_voice_with_outcome
       ~config
       ~meta
       ~name:"keeper_voice_listen"
       ~args:(`Assoc [ "timeout_seconds", `Float 0.05 ])
       ());
  check int "listen runs without a Gate request" 1 (List.length (pending_entries ()));
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

(* Under Auto_judge a speak is sorted before the judge is paid: its effect
   lands on the operator's own outputs, so the Gate allows it as
   [Local_output] with no queue row and no judge turn. Only speak is sorted
   that way — a connector post from the same keeper under the same mode still
   goes to the judge lane — and Manual is untouched: the case above parks
   the same speak. Listen never reaches the Gate at all (also above). *)
let test_auto_judge_allows_speak_as_local_output_without_a_judge () =
  with_clean_gate_runtime @@ fun () ->
  let base_path = temp_dir "voice-gate-local-output" in
  Fun.protect ~finally:(fun () -> remove_tree base_path) @@ fun () ->
  let config = Workspace.default_config base_path in
  select_workspace config Keeper_gate_mode.Auto_judge;
  ignore (install_exn ~base_path);
  let request operation =
    { Keeper_gate.keeper_name = "voice-gate-keeper"
    ; operation
    ; input = `Assoc [ "message", `String "gate coverage probe" ]
    ; call_summary = None
    ; base_path
    ; causal_context = None
    ; task_id = None
    ; continuation_channel = None
    ; sandbox_profile = None
    }
  in
  (match
     Keeper_gate.decide
       ~keeper_always_allow:false
       (request Keeper_gate.voice_speak_gate_operation)
   with
   | Keeper_gate.Allow { source = Keeper_gate.Local_output; _ } -> ()
   | Keeper_gate.Allow { source; _ } ->
     failf
       "speak was allowed through the wrong source: %s"
       (Keeper_gate.authorization_source_to_string source)
   | Keeper_gate.Deferred _ -> fail "speak paid a judge turn under auto_judge"
   | Keeper_gate.Unavailable _ -> fail "speak made the queue unavailable");
  (match Keeper_approval_queue.list_pending_entries_for_workspace ~base_path with
   | Ok [] -> ()
   | Ok pending ->
     failf "speak left %d pending approval(s) behind" (List.length pending)
   | Error error -> fail (Masc.Keeper_approval_queue_result.storage_error_to_string error));
  match
    Keeper_gate.decide
      ~keeper_always_allow:false
      (request Keeper_gate.connector_post_gate_operation)
  with
  | Keeper_gate.Deferred { reason = Keeper_gate.Judge_requested; _ }
  | Keeper_gate.Deferred { reason = Keeper_gate.Auto_judge_unavailable _; _ } -> ()
  | Keeper_gate.Deferred { reason = Keeper_gate.Human_requested; _ } ->
    fail "a connector post went to the human queue under auto_judge"
  | Keeper_gate.Deferred { reason = Keeper_gate.Mode_state_invalid detail; _ } ->
    fail ("connector post: mode_state_invalid: " ^ detail)
  | Keeper_gate.Allow { source; _ } ->
    failf
      "a connector post was allowed without a judge through %s"
      (Keeper_gate.authorization_source_to_string source)
  | Keeper_gate.Unavailable _ -> fail "a connector post made the queue unavailable"
;;

(* Task-635 (#26058) narrow gap, owner-conditioned, then owner-narrowed:
   review 5192723206 — until a path can observe attempts AFTER "A"
   (SECCOMP_RET_USER_NOTIF / audit logs), every [Observed_refused] keeps
   the judge: the setup channel can only report the box failing to apply,
   never the payload being blocked, so no refusal kind stands in for the
   route the boundary forecloses. [Observation_unavailable] also always
   defers: silence about what a box would have reached says nothing about
   what it would have touched (a plain filesystem write inside the
   keeper's own tree is as unproven as a network route). Review
   5192723206 also closed the narrower shortcut this PR tried first (an
   [Observed_refused] bypass keyed on the keeper's own [network_mode]):
   that field and its allow-source were never built after the narrowing,
   so removed rather than left as an unreachable promise (review
   5195604213). *)
let observed_refused_once ~refusal_kind =
  let stderr =
    match refusal_kind with
    | Keeper_gate.Socket_rule_not_applied | Keeper_gate.Write_rule_not_applied -> ""
    | Keeper_gate.Setup_failed ->
      "masc-exec-shim: Failure(\"box setup refused by unknown rule: \")\n"
    | Keeper_gate.Unattributed -> "" in
  Keeper_gate.Observed_refused
    { status = Unix.WEXITED 127; stderr; refusal_kind }
;;

let observation_unavailable_once () =
  Keeper_gate.Observation_unavailable "no box could be built for this profile"
;;

let network_probe_request base_path =
  { Keeper_gate.keeper_name = "network-gate-keeper"
  ; operation = Keeper_gate.tool_execute_gate_operation
  ; input =
      `Assoc
        [ ( "input"
          , `Assoc
              [ ( "argv"
                , `List [ `String "rm"; `String "-rf"; `String "/scratch/x" ] )
              ] )
        ]
  ; call_summary = None
  ; base_path
  ; causal_context = None
  ; task_id = None
  ; continuation_channel = None
  ; sandbox_profile = Some Keeper_types_profile_sandbox.Docker
  }
;;

let with_network_probe_workspace f =
  let base_path = temp_dir "network-isolated-gate" in
  Fun.protect ~finally:(fun () -> remove_tree base_path) @@ fun () ->
  let config = Workspace.default_config base_path in
  select_workspace config Keeper_gate_mode.Auto_judge;
  ignore (install_exn ~base_path);
  f base_path
;;

let test_observed_refused_still_defers_without_network_isolation () =
  with_clean_gate_runtime @@ fun () ->
  (* The owner's narrowing (review 5192723206): the setup channel can
     only report the box failing to apply — even a socket-rule refusal
     says "the filter never engaged", so no refusal kind may stand in
     for the route the boundary forecloses. Every refusal keeps the
     judge until a path can observe attempts after "A"
     (SECCOMP_RET_USER_NOTIF / audit logs, separate PR). *)
  List.iter
    (fun refusal_kind ->
       with_clean_gate_runtime @@ fun () ->
       with_network_probe_workspace @@ fun base_path ->
       let request = network_probe_request base_path in
       match
         Keeper_gate.decide
           ~keeper_always_allow:false
           ~observe:(fun () -> observed_refused_once ~refusal_kind)
           request
       with
       | Keeper_gate.Deferred { reason = Keeper_gate.Judge_requested; _ } -> ()
       | Keeper_gate.Deferred { reason = Keeper_gate.Auto_judge_unavailable _; _ } -> ()
       | Keeper_gate.Deferred { reason = Keeper_gate.Human_requested; _ } ->
         fail "a refused observe went to the human queue under auto_judge"
       | Keeper_gate.Deferred { reason = Keeper_gate.Mode_state_invalid detail; _ } ->
         fail ("refused observe: mode_state_invalid: " ^ detail)
       | Keeper_gate.Allow { source; _ } ->
         failf
           "a refused observe bypassed the judge via %s — no refusal \
            kind proves the payload was blocked"
           (Keeper_gate.authorization_source_to_string source)
       | Keeper_gate.Unavailable _ -> fail "the queue was unavailable")
    Keeper_approval_queue_rules_types.observed_refusal_kinds
;;

let test_observation_unavailable_always_defers () =
  with_clean_gate_runtime @@ fun () ->
  with_network_probe_workspace @@ fun base_path ->
  let request = network_probe_request base_path in
  match
    Keeper_gate.decide
      ~keeper_always_allow:false
      ~observe:observation_unavailable_once
      request
  with
  | Keeper_gate.Deferred { reason = Keeper_gate.Judge_requested; _ } -> ()
  | Keeper_gate.Deferred { reason = Keeper_gate.Auto_judge_unavailable _; _ } -> ()
  | Keeper_gate.Deferred { reason = Keeper_gate.Human_requested; _ } ->
    fail "an unbuildable box went to the human queue under auto_judge"
  | Keeper_gate.Deferred { reason = Keeper_gate.Mode_state_invalid detail; _ } ->
    fail ("observation_unavailable: mode_state_invalid: " ^ detail)
  | Keeper_gate.Allow { source; _ } ->
    failf
      "an unbuildable box was allowed through %s — no box means no proof \
       of what the request would have reached"
      (Keeper_gate.authorization_source_to_string source)
  | Keeper_gate.Unavailable _ -> fail "the queue was unavailable"
;;

(* Task-1568 (#36032 follow-up, review 5192723206): [Exec_shim] now carries
   a capability probe for the observation path a shortcut would eventually
   need ([Exec_shim.user_notif_supported]). Nothing wires that probe's
   result into this gate yet — that link is deferred to the PR that also
   adds the listener-fd plumbing and the supervisor loop. This test proves
   the two additions are inert together: calling the probe, in the same
   process that then runs [decide_after_observation] on a refused observe,
   still cannot make the decision skip the judge. It fails loudly if a
   future edit ever makes [Keeper_gate] read [Exec_shim]'s capability
   result as an allow condition without updating this pin. *)
let test_user_notif_capability_does_not_change_observed_refused_decision () =
  with_clean_gate_runtime @@ fun () ->
  with_network_probe_workspace @@ fun base_path ->
  let request = network_probe_request base_path in
  let (_ : bool) = Exec_shim.user_notif_supported () in
  match
    Keeper_gate.decide
      ~keeper_always_allow:false
      ~observe:(fun () -> observed_refused_once ~refusal_kind:Keeper_gate.Socket_rule_not_applied)
      request
  with
  | Keeper_gate.Deferred { reason = Keeper_gate.Judge_requested; _ } -> ()
  | Keeper_gate.Deferred { reason = Keeper_gate.Auto_judge_unavailable _; _ } -> ()
  | Keeper_gate.Deferred { reason = Keeper_gate.Human_requested; _ } ->
    fail "a refused observe went to the human queue under auto_judge"
  | Keeper_gate.Deferred { reason = Keeper_gate.Mode_state_invalid detail; _ } ->
    fail ("refused observe: mode_state_invalid: " ^ detail)
  | Keeper_gate.Allow { source; _ } ->
    failf
      "a refused observe bypassed the judge via %s once Exec_shim.user_notif_supported \
       was called in-process — the capability probe must stay unread by decide_after_observation"
      (Keeper_gate.authorization_source_to_string source)
  | Keeper_gate.Unavailable _ -> fail "the queue was unavailable"
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
            "YOLO does not carry a call past the Gate"
            `Quick
            test_yolo_does_not_carry_a_call_past_the_gate
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
        ; test_case
            "auto_judge allows speak as local output without a judge"
            `Quick
            test_auto_judge_allows_speak_as_local_output_without_a_judge
        ] )
    ; ( "narrow gap (task-635, #26058)"
      , [ test_case
            "Observed_refused always keeps the judge, no shortcut by refusal kind"
            `Quick
            test_observed_refused_still_defers_without_network_isolation
        ; test_case
            "Observation_unavailable always defers"
            `Quick
            test_observation_unavailable_always_defers
        ; test_case
            "task-1568: user_notif capability probe does not change the decision"
            `Quick
            test_user_notif_capability_does_not_change_observed_refused_decision
        ] )
    ]
;;
