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
  ignore (single_out config ~keeper_name:"echo" (Some Keeper_gate_mode.Manual));
  check string "the singled-out keeper asks a person" "manual"
    (resolved ~base_path ~keeper_name:"echo");
  check string "and nobody else moved" "auto_judge"
    (resolved ~base_path ~keeper_name:"delta")

let test_an_override_cannot_lower_one_keeper () =
  (* Turning the workspace stricter must not be undoable one keeper at a
     time by an older row nobody remembers writing. *)
  with_workspace @@ fun (base_path, config) ->
  select_workspace config Keeper_gate_mode.Manual;
  ignore
    (single_out config ~keeper_name:"echo" (Some Keeper_gate_mode.Always_allow));
  check string "the workspace still decides" "manual"
    (resolved ~base_path ~keeper_name:"echo")

let test_a_lower_override_waits_rather_than_being_lost () =
  (* Kept on disk, ignored on read. An operator who set one and then
     tightened the workspace should find it again when they loosen back,
     rather than silently having lost it. *)
  with_workspace @@ fun (base_path, config) ->
  select_workspace config Keeper_gate_mode.Manual;
  ignore
    (single_out config ~keeper_name:"echo" (Some Keeper_gate_mode.Auto_judge));
  (match Keeper_gate_mode.keeper_override ~base_path ~keeper_name:"echo" with
   | Ok (Some o) ->
     check string "what was asked for is still recorded" "auto_judge"
       (Keeper_gate_mode.to_string o.Keeper_gate_mode.mode)
   | Ok None -> fail "the override was dropped instead of kept"
   | Error error -> fail ("failed to read the override: " ^ error))

let test_clearing_an_override_removes_it () =
  with_workspace @@ fun (base_path, config) ->
  select_workspace config Keeper_gate_mode.Auto_judge;
  ignore (single_out config ~keeper_name:"echo" (Some Keeper_gate_mode.Manual));
  ignore (single_out config ~keeper_name:"echo" None);
  (match Keeper_gate_mode.keeper_overrides ~base_path with
   | Ok [] -> ()
   | Ok rows ->
     failf "clearing left %d override(s) behind" (List.length rows)
   | Error error -> fail ("failed to read the overrides: " ^ error));
  check string "and the keeper is back on the workspace answer" "auto_judge"
    (resolved ~base_path ~keeper_name:"echo")

let test_an_unreadable_override_file_is_not_an_empty_list () =
  (* An empty list answers with the workspace mode, which is the looser one.
     A file that cannot be read must not be the quiet way back to it. *)
  with_workspace @@ fun (base_path, _config) ->
  let file = Keeper_gate_path.keeper_modes ~base_path in
  Fs_compat.mkdir_p (Keeper_gate_path.dir ~base_path);
  (match Fs_compat.save_file_atomic file "{ not a list" with
   | Ok () -> ()
   | Error detail -> fail ("could not write the fixture: " ^ detail));
  match Keeper_gate_mode.resolve ~base_path ~keeper_name:"echo" with
  | Error _ -> ()
  | Ok mode ->
    failf "an unreadable override file resolved to %s"
      (Keeper_gate_mode.to_string mode)

(* Which admitted slot a Keeper reaches first in one exact-output lane. The
   lane keeps its failover, so this is an ordering question. *)
let slot_ids = [ "glm.turbo"; "ollama.flash"; "ollama.qwen" ]

let preferred_order preferred =
  Keeper_exact_lane_preference.prefer
    ~slots:slot_ids
    ~slot_id_of:Fun.id
    ~preferred

let test_a_preference_moves_one_judge_to_the_front () =
  match preferred_order "ollama.qwen" with
  | Ok order ->
    check (list string) "asked-for judge first, the rest in order"
      [ "ollama.qwen"; "glm.turbo"; "ollama.flash" ] order
  | Error detail -> fail ("a declared slot was refused: " ^ detail)

let test_the_rest_of_the_lane_stays_behind_it () =
  (* Not a restriction. The lane has failover because a weekly quota runs out
     and a bundle outgrows a context window, and both still happen. *)
  match preferred_order "ollama.flash" with
  | Ok order ->
    check int "every judge is still reachable" (List.length slot_ids)
      (List.length order)
  | Error detail -> fail ("a declared slot was refused: " ^ detail)

let test_a_slot_the_lane_does_not_offer_is_refused () =
  (* Quietly falling back would leave an operator believing this Keeper is
     judged by a model it has never been judged by. *)
  match preferred_order "some.model" with
  | Ok _ -> fail "accepted a slot the lane never declared"
  | Error detail ->
    check bool "and the refusal names what is on offer" true
      (List.for_all
         (fun slot_id ->
           try ignore (Str.search_forward (Str.regexp_string slot_id) detail 0); true
           with Not_found -> false)
         slot_ids)

let test_a_preference_survives_a_round_trip () =
  with_workspace @@ fun (base_path, config) ->
  (match
     Keeper_exact_lane_preference.set
       config
       ~actor:"test"
       ~keeper_name:"echo"
       ~lane_id:"hitl_auto_judge"
       (Some "ollama.qwen")
   with
   | Ok _ -> ()
   | Error detail -> fail ("could not set an exact-lane preference: " ^ detail));
  (match
     Keeper_exact_lane_preference.find
       ~base_path
       ~keeper_name:"echo"
       ~lane_id:"hitl_auto_judge"
   with
   | Ok (Some row) ->
     check string "what was set comes back" "ollama.qwen"
       row.Keeper_exact_lane_preference.slot_id
   | Ok None -> fail "the preference was not stored"
   | Error detail -> fail ("could not read it back: " ^ detail));
  match
    Keeper_exact_lane_preference.find
      ~base_path
      ~keeper_name:"delta"
      ~lane_id:"hitl_auto_judge"
  with
  | Ok None -> ()
  | Ok (Some _) -> fail "one Keeper's preference reached another"
  | Error detail -> fail ("could not read another keeper: " ^ detail)

let test_clearing_a_preference_removes_it () =
  with_workspace @@ fun (base_path, config) ->
  let set value =
    match
      Keeper_exact_lane_preference.set
        config
        ~actor:"test"
        ~keeper_name:"echo"
        ~lane_id:"hitl_auto_judge"
        value
    with
    | Ok _ -> ()
    | Error detail -> fail ("could not set a judge preference: " ^ detail)
  in
  set (Some "ollama.qwen");
  set None;
  match Keeper_exact_lane_preference.all ~base_path with
  | Ok [] -> ()
  | Ok rows -> failf "clearing left %d preference(s) behind" (List.length rows)
  | Error detail -> fail ("could not read the preferences: " ^ detail)

let test_an_unreadable_preference_file_is_not_an_empty_list () =
  with_workspace @@ fun (base_path, _config) ->
  Fs_compat.mkdir_p (Keeper_gate_path.dir ~base_path);
  (match
     Fs_compat.save_file_atomic
       (Keeper_exact_lane_preference.path ~base_path)
       "{ not a list"
   with
   | Ok () -> ()
   | Error detail -> fail ("could not write the fixture: " ^ detail));
  match
    Keeper_exact_lane_preference.find
      ~base_path
      ~keeper_name:"echo"
      ~lane_id:"hitl_auto_judge"
  with
  | Error _ -> ()
  | Ok _ -> fail "an unreadable preference file read as no preference"

let test_legacy_judge_row_is_not_a_current_exact_lane_row () =
  with_workspace @@ fun (base_path, _config) ->
  Fs_compat.mkdir_p (Keeper_gate_path.dir ~base_path);
  let legacy =
    `List
      [ `Assoc
          [ "keeper_name", `String "echo"
          ; "slot_id", `String "ollama.qwen"
          ; "updated_by", `String "test"
          ; "updated_at", `String "2026-08-28T00:00:00Z"
          ]
      ]
  in
  (match
     Fs_compat.save_file_atomic
       (Keeper_exact_lane_preference.path ~base_path)
       (Yojson.Safe.to_string legacy)
   with
   | Ok () -> ()
   | Error detail -> fail detail);
  match Keeper_exact_lane_preference.all ~base_path with
  | Error _ -> ()
  | Ok _ -> fail "legacy Judge-only row was accepted as a current exact-lane row"

let test_duplicate_exact_lane_owner_is_rejected () =
  with_workspace @@ fun (base_path, _config) ->
  Fs_compat.mkdir_p (Keeper_gate_path.dir ~base_path);
  let row slot_id =
    `Assoc
      [ "keeper_name", `String "echo"
      ; "lane_id", `String "hitl_auto_judge"
      ; "slot_id", `String slot_id
      ; "updated_by", `String "test"
      ; "updated_at", `String "2026-08-28T00:00:00Z"
      ]
  in
  (match
     Fs_compat.save_file_atomic
       (Keeper_exact_lane_preference.path ~base_path)
       (Yojson.Safe.to_string (`List [ row "a"; row "b" ]))
   with
   | Ok () -> ()
   | Error detail -> fail detail);
  match Keeper_exact_lane_preference.all ~base_path with
  | Error _ -> ()
  | Ok _ -> fail "duplicate Keeper x lane owner was accepted"

let test_preferences_are_scoped_by_exact_lane () =
  with_workspace @@ fun (base_path, config) ->
  let set lane_id slot_id =
    match
      Keeper_exact_lane_preference.set
        config
        ~actor:"test"
        ~keeper_name:"echo"
        ~lane_id
        (Some slot_id)
    with
    | Ok _ -> ()
    | Error detail -> fail ("could not set exact-lane preference: " ^ detail)
  in
  set "hitl_auto_judge" "glm.turbo";
  set "librarian_exact" "ollama.qwen";
  match
    ( Keeper_exact_lane_preference.find
        ~base_path
        ~keeper_name:"echo"
        ~lane_id:"hitl_auto_judge"
    , Keeper_exact_lane_preference.find
        ~base_path
        ~keeper_name:"echo"
        ~lane_id:"librarian_exact" )
  with
  | Ok (Some hitl), Ok (Some librarian) ->
    check string "HITL owns its slot" "glm.turbo" hitl.slot_id;
    check string "Librarian owns its slot" "ollama.qwen" librarian.slot_id
  | _ -> fail "one Keeper's exact lanes did not retain independent preferences"

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
  Keeper_tool_approval_mode.set
    (Keeper_tool_approval_mode.shared ())
    ~keeper_name:"gate-yolo-keeper" Keeper_tool_approval_mode.Yolo;
  Fun.protect
    ~finally:(fun () ->
      Keeper_tool_approval_mode.set
        (Keeper_tool_approval_mode.shared ())
        ~keeper_name:"gate-yolo-keeper" Keeper_tool_approval_mode.Auto)
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
      fail (Keeper_approval_queue.storage_error_to_string error)
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
    ; ( "per-keeper exact lane"
      , [ test_case "a preference moves one judge to the front" `Quick
            test_a_preference_moves_one_judge_to_the_front
        ; test_case "the rest of the lane stays behind it" `Quick
            test_the_rest_of_the_lane_stays_behind_it
        ; test_case "a slot the lane does not offer is refused" `Quick
            test_a_slot_the_lane_does_not_offer_is_refused
        ; test_case "a preference survives a round trip" `Quick
            test_a_preference_survives_a_round_trip
        ; test_case "clearing a preference removes it" `Quick
            test_clearing_a_preference_removes_it
        ; test_case "an unreadable preference file is not an empty list" `Quick
            test_an_unreadable_preference_file_is_not_an_empty_list
        ; test_case "legacy Judge row is not a current row" `Quick
            test_legacy_judge_row_is_not_a_current_exact_lane_row
        ; test_case "duplicate exact-lane owner rejects" `Quick
            test_duplicate_exact_lane_owner_is_rejected
        ; test_case "preferences are scoped by exact lane" `Quick
            test_preferences_are_scoped_by_exact_lane
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
        ] )
    ]
;;
