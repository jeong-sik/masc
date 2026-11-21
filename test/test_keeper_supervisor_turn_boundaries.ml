(** Test suite for Keeper_supervisor — fiber liveness tracking and recovery.
    Pure tests for backoff/helpers. Fiber health queries now delegate to
    Keeper_registry (tested in test_keeper_registry.ml). *)

open Alcotest
module Sup = Masc.Keeper_supervisor
module Keeper_meta_contract = Masc.Keeper_meta_contract
module Keeper_meta_store = Masc.Keeper_meta_store
module Keeper_types_profile = Masc.Keeper_types_profile
module Workspace = Masc.Workspace
module Reg = Masc.Keeper_registry
module KSM = Keeper_state_machine
module Lane = Masc.Keeper_lane
module Memory_lane = Masc.Keeper_memory_lane
module Lifecycle_reservation = Masc.Keeper_lifecycle_reservation
module Launch_transaction = Masc.Keeper_keepalive_launch_transaction
module Librarian_boundaries = Masc.Keeper_turn_boundaries
module Librarian_checkpoint_store = Masc.Keeper_checkpoint_store

let supervisor_agent_name = Sup.supervisor_agent_name

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_supervisor_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let ensure_fs env =
  if not (Fs_compat.has_fs ()) then
    Fs_compat.set_fs (Eio.Stdenv.fs env)

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun name -> rm (Filename.concat path name));
        Unix.rmdir path
      end else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let rec mkdir_p path =
  if path = "" || path = "." || path = "/" then ()
  else if Sys.file_exists path then ()
  else begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755
  end

let write_file path content =
  Out_channel.with_open_bin path (fun oc -> output_string oc content)

let write_keeper_toml config_dir ~name =
  let profile_dir = Filename.concat (Filename.concat config_dir "keepers") name in
  mkdir_p profile_dir;
  write_file
    (Filename.concat (Filename.concat config_dir "keepers") (name ^ ".toml"))
    (Printf.sprintf
       {|
[keeper]
name = "%s"
instructions = "test keeper"
sandbox_profile = "docker"
sandbox_image = "base"
|}
       name)

(* sandbox_profile and network_mode left the meta JSON wire schema -- they
   arrive from keeper.toml now, and meta_of_json rejects a document that still
   carries them ("fields outside the current schema ... runtime reset
   required"). This fixture only ever set them to the record defaults
   ("local" / "inherit"), so dropping them changes nothing these cases assert.
   test_keeper_keepalive_helpers made the same edit; this suite was outside CI,
   so its copy kept the old shape (#28131). *)
let make_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ ("name", `String name)
        ; ("trace_id", `String ("trace-" ^ name))
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("make_meta: " ^ err)

let seed_durable_librarian_baseline
  config
  (meta : Keeper_meta_contract.keeper_meta)
  =
  let config_dir = Filename.concat (Workspace.masc_dir config) "config" in
  write_keeper_toml config_dir ~name:meta.name;
  Keeper_types_profile.invalidate_keeper_profile_snapshots ();
  (match Keeper_meta_store.replace_snapshot config meta with
   | Ok () -> ()
   | Error detail -> fail ("write Librarian fixture metadata: " ^ detail));
  let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  let messages =
    [ Agent_core.Types.make_message
        ~role:Agent_core.Types.User
        [ Agent_core.Types.Text "durable baseline" ]
    ]
  in
  let checkpoint : Agent_core.Checkpoint.t =
    { provider_binding = None; version = Agent_core.Checkpoint.checkpoint_version
    ; session_id = trace_id
    ; agent_name = meta.name
    ; model = "fixture-model"
    ; system_prompt = None
    ; messages
    ; usage = Agent_core.Types.empty_usage
    ; turn_count = 1
    ; created_at = 1.0
    ; tools = []
    ; tool_choice = None
    ; disable_parallel_tool_use = false
    ; temperature = None
    ; top_p = None
    ; top_k = None
    ; min_p = None
    ; reasoning_effort = None
    ; enable_thinking = None
    ; preserve_thinking = None
    ; response_format = Agent_core.Types.Off
    ; cache_system_prompt = false
    ; context = Agent_core.Context.create_sync ()
    ; pending_input = None
    ; working_context = None
    }
  in
  let session_dir = Masc.Keeper_fs.keeper_session_dir config trace_id in
  (match
     Librarian_checkpoint_store.save_agent_core_classified ~boundary:Agent_core.Checkpoint_objects.Turn_closes
       ~session_dir
       ~history_retained:0
       checkpoint
   with
   | Ok (Librarian_checkpoint_store.Saved _) -> ()
   | Ok (Librarian_checkpoint_store.Stale_noop _) ->
     fail "Librarian fixture checkpoint was stale"
   | Error detail -> fail ("save Librarian fixture checkpoint: " ^ detail));
  let position =
    match Librarian_boundaries.position_of_messages messages with
    | Ok position -> position
    | Error detail -> fail ("Librarian fixture boundary: " ^ detail)
  in
  let record : Librarian_boundaries.record =
    { recorded_at = 1.0
    ; event =
        Librarian_boundaries.Turn_ended
          { task_context = Masc.Keeper_turn_task_context.No_task; turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:1
          ; history_at_start = Librarian_boundaries.Continued_history
          ; position
          }
    }
  in
  match
    Librarian_boundaries.append
      ~keepers_dir:(Workspace.keepers_runtime_dir config)
      ~keeper_id:meta.name
      record
  with
  | Ok () -> ()
  | Error error -> fail (Librarian_boundaries.append_error_to_string error)

let with_librarian_enabled f =
  Masc_test_deps.with_process_env
    Env_config.KeeperMemoryOs.librarian_env_key
    (Some "true")
    f
;;

(* Sweep paths that resolve a keeper's runtime id reach
   [Keeper_meta_contract.runtime_id_of_meta], which falls back to
   [Runtime.get_default_runtime_id ()] for keepers without an explicit
   [[runtime.assignments]] entry.  That fallback fail-fasts until
   [Runtime.init_default] has run (no silent fallback).
   In a booted server [init_default] runs at startup
   (server_runtime_bootstrap.ml); a bare [dune exec] test binary must
   stand the default runtime up itself.  Mirrors the established pattern in
   test_keeper_lifecycle_registry_dispatch.ml. *)
let test_runtime_toml =
  {|
[runtime]
default = "test_provider.test_model"

[providers.test_provider]
display-name = "Test Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true

[test_provider.test_model]
is-default = true
max-concurrent = 1
|}

let ensure_test_runtime =
  let initialized = ref false in
  fun () ->
    if not !initialized then (
      let path = Filename.temp_file "keeper_supervisor_runtime_" ".toml" in
      let oc = open_out path in
      Fun.protect
        ~finally:(fun () -> close_out_noerr oc)
        (fun () -> output_string oc test_runtime_toml);
      Fun.protect
        ~finally:(fun () ->
          try Sys.remove path with
          | Sys_error _ -> ())
        (fun () ->
          match Runtime.init_default ~config_path:path with
          | Ok () -> initialized := true
          | Error msg -> fail msg))

let crashed_restart_fixture ~base_path name meta =
  let initial = Reg.For_testing.register ~base_path name meta in
  (match
     Reg.dispatch_event_exact
       initial
       (KSM.Fiber_terminated
          { outcome = "fixture crash" })
   with
   | Ok _ -> ()
   | Error error -> fail (KSM.transition_error_to_string error));
  match Reg.get ~base_path name with
  | Some entry -> entry
  | None -> fail "crashed restart fixture disappeared"
;;

let register_restart ~base_path ~name ~meta token intake_token =
  Reg.register_restarting_for_lifecycle
    ~intake_token
    token
    ~base_path
    name
    meta
;;

let test_launch_callback_failure_rolls_back_restart_transaction () =
  with_librarian_enabled @@ fun () ->
  Eio_main.run @@ fun env ->
  ensure_fs env;
  ensure_test_runtime ();
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.For_testing.clear ();
      Memory_lane.For_testing.reset ();
      Masc.Keeper_shutdown_intake_fence.For_testing.reset ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
       let config = Masc.Workspace.default_config base_dir in
       ignore (Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name));
       Memory_lane.For_testing.reset ();
       Memory_lane.init ~sw;
       let name = "librarian-launch-exception-rollback" in
       let meta = make_meta name in
       seed_durable_librarian_baseline config meta;
       let crashed = crashed_restart_fixture ~base_path:config.base_path name meta in
       (match
          Launch_transaction.run
            ~base_path:config.base_path
            ~keeper_name:name
            ~register:(register_restart ~base_path:config.base_path ~name ~meta)
            ~rollback:(Launch_transaction.Restore_previous crashed)
            (fun _intake_token _token _replacement ->
              failwith "injected launch callback failure")
        with
        | Error
            (Launch_transaction.Launch_failed { rollback_error = None; _ }) -> ()
        | Error _ -> fail "launch exception produced the wrong transaction outcome"
        | Ok _ -> fail "launch exception unexpectedly committed");
       (match Reg.get ~base_path:config.base_path name with
        | Some current ->
          check bool "launch exception restores exact crashed authority" true
            (Lane.Id.equal (Lane.id current.lane) (Lane.id crashed.lane))
        | None -> fail "launch exception removed the durable restart authority");
       (* I7: a failed launch closes nothing on the Librarian lane. *)
       (match Memory_lane.submit ~base_path:config.base_path ~keeper_name:name ignore with
        | Memory_lane.Submitted | Memory_lane.Coalesced | Memory_lane.Ran_inline -> ()
        | Memory_lane.Dropped -> fail "failed launch left the Librarian lane unusable");
       Memory_lane.For_testing.await_idle ~base_path:config.base_path ~keeper_name:name;
       match
         Launch_transaction.run
           ~base_path:config.base_path
           ~keeper_name:name
           ~register:(register_restart ~base_path:config.base_path ~name ~meta)
           ~rollback:(Launch_transaction.Restore_previous crashed)
           (fun _intake_token _token replacement -> replacement)
       with
       | Ok replacement ->
         check bool "retry installs a fresh restart lane" false
           (Lane.Id.equal (Lane.id replacement.lane) (Lane.id crashed.lane))
       | Error _ -> fail "retry did not reopen the rolled-back Librarian lifecycle")
;;

let test_launch_callback_cancellation_rolls_back_restart_transaction () =
  with_librarian_enabled @@ fun () ->
  Eio_main.run @@ fun env ->
  ensure_fs env;
  ensure_test_runtime ();
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.For_testing.clear ();
      Memory_lane.For_testing.reset ();
      Masc.Keeper_shutdown_intake_fence.For_testing.reset ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
       let config = Masc.Workspace.default_config base_dir in
       ignore (Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name));
       Memory_lane.For_testing.reset ();
       Memory_lane.init ~sw;
       let name = "librarian-launch-cancellation-rollback" in
       let meta = make_meta name in
       seed_durable_librarian_baseline config meta;
       let crashed = crashed_restart_fixture ~base_path:config.base_path name meta in
       let cancel_context, resolve_cancel_context = Eio.Promise.create () in
       let launch_entered, resolve_launch_entered = Eio.Promise.create () in
       let cancelled, resolve_cancelled = Eio.Promise.create () in
       let never, _resolve_never = Eio.Promise.create () in
       Eio.Fiber.fork ~sw (fun () ->
         let saw_cancellation =
           try
             Eio.Cancel.sub (fun context ->
               Eio.Promise.resolve resolve_cancel_context context;
               ignore
                 (Launch_transaction.run
                    ~base_path:config.base_path
                    ~keeper_name:name
                    ~register:
                      (register_restart ~base_path:config.base_path ~name ~meta)
                    ~rollback:(Launch_transaction.Restore_previous crashed)
                    (fun _intake_token _token _replacement ->
                       Eio.Promise.resolve resolve_launch_entered ();
                       Eio.Promise.await never)
                   : (_, _) result);
               false)
           with
           | Eio.Cancel.Cancelled _ -> true
         in
         Eio.Promise.resolve resolve_cancelled saw_cancellation);
       let context = Eio.Promise.await cancel_context in
       Eio.Promise.await launch_entered;
       Eio.Cancel.cancel context (Failure "cancel injected launch callback");
       check bool "launch cancellation propagates after rollback" true
         (Eio.Promise.await cancelled);
       (match Reg.get ~base_path:config.base_path name with
        | Some current ->
          check bool "launch cancellation restores exact crashed authority" true
            (Lane.Id.equal (Lane.id current.lane) (Lane.id crashed.lane))
        | None -> fail "launch cancellation removed the durable restart authority");
       (match
          Lifecycle_reservation.current
            ~base_path:config.base_path
            ~keeper_name:name
        with
        | None -> ()
        | Some owner ->
          fail
            ("launch cancellation leaked lifecycle reservation: "
             ^ Lifecycle_reservation.snapshot_to_string owner));
       (* I7: a cancelled launch closes nothing on the Librarian lane. *)
       match Memory_lane.submit ~base_path:config.base_path ~keeper_name:name ignore with
       | Memory_lane.Submitted | Memory_lane.Coalesced | Memory_lane.Ran_inline -> ()
       | Memory_lane.Dropped -> fail "cancelled launch left the Librarian lane unusable")
;;

let () =
  run "keeper_supervisor_turn_boundaries" [
    "restart_metrics", [
      test_case "launch callback failure rolls back restart transaction" `Quick
        test_launch_callback_failure_rolls_back_restart_transaction;
      test_case "launch callback cancellation rolls back restart transaction" `Quick
        test_launch_callback_cancellation_rolls_back_restart_transaction;
    ];
  ]
