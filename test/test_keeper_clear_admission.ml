open Masc
open Alcotest

module Context = Keeper_context_core

let require_ok = function
  | Ok value -> value
  | Error detail -> fail detail
;;

let with_keeper ~paused ~install_owner f =
  Eio_main.run @@ fun env ->
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "keeper-clear-admission-" "" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.For_testing.clear ();
      Fs_compat.remove_tree base_path)
  @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let config = Workspace.default_config base_path in
  ignore (Workspace.init config ~agent_name:(Some "operator"));
  let meta =
    Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String "clear-admission-fixture"
              ; "trace_id", `String "trace-clear-admission-fixture"
              ; "activation_mode", `String "manual" ])
    |> require_ok
  in
  let meta = { meta with paused } in
  Keeper_meta_store.replace_snapshot config meta |> require_ok;
  ignore (Keeper_registry.register_offline ~base_path meta.name meta);
  if install_owner then (
    match Keeper_owner_registry.install_from_store ~sw ~operation_runner:None
      ~on_turn_slot_released:None config with
    | Ok _ -> ()
    | Error error -> fail (Keeper_owner_registry.install_error_to_string error));
  let base_dir = Keeper_types_profile.session_base_dir config in
  let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  let session = Context.create_session ~session_id:trace_id ~base_dir in
  let saved =
    Context.append_many (Context.create ~eio:true ~system_prompt:"pinned")
      [ Agent_core.Types.user_msg "work already done"
      ; Agent_core.Types.assistant_msg "saved result" ]
  in
  let save ctx =
    match Context.save_agent_core_checkpoint_classified
      ~runtime_id:"fixture-runtime" ~keeper_name:meta.name ~session
      ~agent_name:meta.name ~ctx with
    | Ok (_, Keeper_checkpoint_store.Saved _) -> ()
    | Ok (_, Keeper_checkpoint_store.Stale_noop _) -> fail "save was stale"
    | Error error ->
      fail (Context.checkpoint_write_error_to_string
        ~persistence_error_to_string:Fun.id error)
  in
  save saved;
  let load () =
    match Context.load_context_from_checkpoint ~trace_id ~base_dir with
    | _, Some context -> context
    | _, None -> fail "checkpoint disappeared"
  in
  let ctx : _ Keeper_tool_surface.context =
    { config; agent_name = "operator"; sw; clock = Eio.Stdenv.clock env
    ; proc_mgr = None; net = None
    ; publication_recovery_provider =
        Keeper_publication_recovery_availability.non_runtime_provider }
  in
  let clear () =
    match Keeper_tool_surface.dispatch ctx ~name:"masc_keeper_clear"
      ~args:(`Assoc [ "name", `String meta.name; "reason", `String "operator reset" ]) with
    | Some result -> result
    | None -> fail "clear tool was not dispatched"
  in
  f ~config ~meta ~saved ~save ~load ~clear
;;

let check_refused result =
  check bool "clear was refused" true (Tool_result.is_failed result);
  match result with
  | Tool_result.Failed { effect_disposition = Proven_pre_effect; _ } -> ()
  | _ -> fail "refusal did not prove that no effect started"
;;

let check_empty load =
  let messages = Context.messages_of_context (load ()) in
  check bool "conversation is empty" true
    (List.for_all (fun (message : Agent_core.Types.message) ->
       message.role = Agent_core.Types.System) messages)
;;

let test_clear_does_not_race_the_active_turn () =
  with_keeper ~paused:false ~install_owner:true
  @@ fun ~config ~meta ~saved ~save ~load ~clear ->
  (match Keeper_owner_registry.run_autonomous_if_idle
    ~base_path:config.base_path ~keeper_name:meta.name (fun () ->
      let before = Context.messages_of_context (load ()) in
      check_refused (clear ());
      check bool "busy clear left canonical history untouched" true
        (before = Context.messages_of_context (load ()));
      (* The turn still owns its original history and is allowed to finish. *)
      save saved) with
   | Ok (`Ran ()) -> ()
   | Ok (`Busy _ | `Interrupted) -> fail "fixture turn did not run"
   | Error error -> fail (Keeper_owner_registry.command_error_to_string error));
  let result = clear () in
  check bool (Tool_result.message result) true (Tool_result.is_success result);
  check_empty load;
  (match Keeper_owner_registry.run_autonomous_if_idle
    ~base_path:config.base_path ~keeper_name:meta.name (fun () -> check_empty load) with
   | Ok (`Ran ()) -> ()
   | Ok (`Busy _ | `Interrupted) -> fail "next turn did not run"
   | Error error -> fail (Keeper_owner_registry.command_error_to_string error))
;;

let test_paused_keeper_can_clear_without_resuming () =
  with_keeper ~paused:true ~install_owner:true
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load ~clear ->
  let result = clear () in
  check bool (Tool_result.message result) true (Tool_result.is_success result);
  check_empty load;
  match Keeper_meta_store.read_meta config meta.name |> require_ok with
  | Some current -> check bool "clear does not resume the keeper" true current.paused
  | None -> fail "keeper metadata disappeared"
;;

let test_missing_owner_does_not_clear () =
  with_keeper ~paused:false ~install_owner:false
  @@ fun ~config:_ ~meta:_ ~saved ~save:_ ~load ~clear ->
  check_refused (clear ());
  check bool "unavailable owner left history untouched" true
    (Context.messages_of_context saved = Context.messages_of_context (load ()))
;;

let () =
  run "keeper clear admission"
    [ "owner", [ test_case "active turn, clear, next turn" `Quick test_clear_does_not_race_the_active_turn
               ; test_case "paused keeper remains paused" `Quick test_paused_keeper_can_clear_without_resuming
               ; test_case "missing owner leaves history" `Quick test_missing_owner_does_not_clear ] ]
