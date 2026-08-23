open Alcotest

module Fence = Masc.Keeper_shutdown_intake_fence
module Operation_id = Masc.Keeper_shutdown_types.Operation_id
module Owner_registry = Masc.Keeper_owner_registry
module Profile = Masc.Keeper_types_profile
module Store = Masc.Keeper_meta_store
module Turn_up = Masc.Keeper_turn_up
module Workspace = Masc.Workspace

let temp_dir prefix =
  let path = Filename.temp_file prefix "" in
  Unix.unlink path;
  Unix.mkdir path 0o755;
  path
;;

let rec mkdir_p path =
  if not (Sys.file_exists path)
  then (
    let parent = Filename.dirname path in
    if not (String.equal parent path) then mkdir_p parent;
    Unix.mkdir path 0o755)
;;

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error _ -> ()
;;

let write_file path content =
  let channel = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel content)
;;

let read_file path =
  let channel = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))
;;

let runtime_toml =
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
;;

let restore_env name = function
  | Some value -> Unix.putenv name value
  | None -> Unix.putenv name ""
;;

let sorted_dir_entries path =
  Sys.readdir path |> Array.to_list |> List.sort String.compare
;;

let with_workspace f =
  let base_path = temp_dir "keeper-create-admission-" in
  let config_dir = Filename.concat base_path ".masc/config" in
  let runtime_path = Filename.concat config_dir "runtime.toml" in
  let previous_config_dir = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Fun.protect
    ~finally:(fun () ->
      restore_env "MASC_CONFIG_DIR" previous_config_dir;
      Config_dir_resolver.reset ();
      Fence.For_testing.reset ();
      Masc.Keeper_registry.For_testing.clear ();
      remove_tree base_path)
    (fun () ->
       mkdir_p config_dir;
       write_file runtime_path runtime_toml;
       Unix.putenv "MASC_CONFIG_DIR" config_dir;
       Config_dir_resolver.reset ();
       let keepers_dir =
         Config_dir_resolver.keepers_dir_for_base_path ~base_path
       in
       mkdir_p keepers_dir;
       Eio_main.run @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       Fun.protect
         ~finally:Fs_compat.clear_fs
         (fun () ->
            let config = Workspace.default_config base_path in
            ignore (Workspace.init config ~agent_name:None : string);
            (match Runtime.init_default ~config_path:runtime_path with
             | Ok () -> ()
             | Error error -> failf "runtime fixture rejected: %s" error);
            Eio.Switch.run @@ fun sw ->
            (match
               Owner_registry.install_from_store
                 ~sw
                 ~operation_runner:None
                 ~on_turn_slot_released:None
                 config
             with
             | Ok 0 -> ()
             | Ok count -> failf "unexpected initial owner count: %d" count
             | Error error ->
               fail (Owner_registry.install_error_to_string error));
            f ~env ~sw ~config ~keepers_dir ~runtime_path))
;;

let test_shutdown_rejection_precedes_all_creation_writes () =
  with_workspace @@ fun ~env ~sw ~config ~keepers_dir ~runtime_path ->
  let keeper_name = "admission-transaction-probe" in
  let trace_root = Filename.concat (Workspace.masc_root_dir config) "traces" in
  mkdir_p trace_root;
  let trace_entries_before = sorted_dir_entries trace_root in
  let runtime_config_before = read_file runtime_path in
  let runtime_assignment_before = Runtime.runtime_id_for_keeper keeper_name in
  let toml_path = Filename.concat keepers_dir (keeper_name ^ ".toml") in
  let operation_id = Operation_id.generate () in
  (match
     Fence.begin_shutdown
       ~base_path:config.base_path
       ~keeper_name
       ~operation_id
   with
   | Fence.Reserved _ -> ()
   | Fence.Already_reserved _ -> fail "fresh shutdown fence was already reserved");
  Fun.protect
    ~finally:(fun () ->
      ignore
        (Fence.rollback_shutdown
           ~base_path:config.base_path
           ~keeper_name
           ~operation_id
          : Fence.rollback_result))
    (fun () ->
       let ctx : _ Profile.context =
         { config
         ; agent_name = "test-agent"
         ; sw
         ; clock = Eio.Stdenv.clock env
         ; proc_mgr = None
         ; net = None
         ; publication_recovery_provider =
             Masc_test_deps.non_runtime_publication_recovery_provider
         }
       in
       let result =
         Turn_up.handle_keeper_up
           ctx
           (`Assoc
             [ "name", `String keeper_name
             ; "instructions", `String "must not be persisted"
             ; "sandbox_profile", `String "local"
             ; "runtime_id", `String "test_provider.test_model"
             ; "proactive_enabled", `Bool false
             ; "autoboot_enabled", `Bool false
             ])
       in
       check bool "keeper_up is rejected" false (Profile.tool_result_success result);
       check (list string)
         "no session or checkpoint directory is created"
         trace_entries_before
         (sorted_dir_entries trace_root);
       check bool "keeper TOML is absent" false (Sys.file_exists toml_path);
       (match Store.read_meta config keeper_name with
        | Ok None -> ()
        | Ok (Some _) -> fail "runtime metadata was created before admission"
        | Error error -> failf "metadata absence check failed: %s" error);
       (match Owner_registry.get ~base_path:config.base_path ~keeper_name with
        | Error (Owner_registry.Owner_not_found actual) ->
          check string "no owner actor is installed" keeper_name actual
        | Error error ->
          failf
            "unexpected owner lookup result: %s"
            (Owner_registry.lookup_error_to_string error)
        | Ok _ -> fail "owner actor was installed before admission");
       check bool
         "no live registry entry is installed"
         true
         (Option.is_none
            (Masc.Keeper_registry.get ~base_path:config.base_path keeper_name));
       check (option string)
         "runtime assignment is unchanged"
         runtime_assignment_before
         (Runtime.runtime_id_for_keeper keeper_name);
       check string
         "runtime configuration is unchanged"
         runtime_config_before
         (read_file runtime_path);
       match Fence.shutdown_operation_id ~base_path:config.base_path ~keeper_name with
       | Some actual ->
         check bool
           "rejected create does not release the shutdown owner"
           true
           (Operation_id.equal operation_id actual)
       | None -> fail "rejected create released the shutdown fence")
;;

let test_create_wins_intake_fence_overlap_through_production_handoff () =
  with_workspace @@ fun ~env ~sw ~config ~keepers_dir ~runtime_path:_ ->
  let keeper_name = "admission-handoff-probe" in
  let toml_path = Filename.concat keepers_dir (keeper_name ^ ".toml") in
  let lock_held, resolve_lock_held = Eio.Promise.create () in
  let release_lock, resolve_release_lock = Eio.Promise.create () in
  let create_done, resolve_create_done = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Masc.Keeper_lifecycle_reservation.with_key_lock
      ~base_path:config.base_path
      ~keeper_name
      (fun () ->
         Eio.Promise.resolve resolve_lock_held ();
         Eio.Promise.await release_lock));
  Eio.Promise.await lock_held;
  let ctx : _ Profile.context =
    { config
    ; agent_name = "test-agent"
    ; sw
    ; clock = Eio.Stdenv.clock env
    ; proc_mgr = None
    ; net = None
    ; publication_recovery_provider =
        Masc_test_deps.non_runtime_publication_recovery_provider
    }
  in
  Eio.Fiber.fork ~sw (fun () ->
    let result =
      Turn_up.handle_keeper_up
        ctx
        (`Assoc
          [ "name", `String keeper_name
          ; "instructions", `String "create must retain its admission epoch"
          ; "sandbox_profile", `String "local"
          ; "proactive_enabled", `Bool false
          ; "autoboot_enabled", `Bool false
          ])
    in
    Eio.Promise.resolve resolve_create_done result);
  let rec await_config_write () =
    if Sys.file_exists toml_path
    then ()
    else
      match Eio.Promise.peek create_done with
      | Some result ->
        failf
          "production create returned before the persistence barrier: %s"
          (Profile.tool_result_body result)
      | None ->
        Eio.Fiber.yield ();
        await_config_write ()
  in
  await_config_write ();
  let operation_id = Operation_id.generate () in
  (match
     Fence.begin_shutdown
      ~base_path:config.base_path
      ~keeper_name
      ~operation_id
   with
   | Fence.Reserved _ -> ()
   | Fence.Already_reserved _ -> fail "fresh shutdown fence was already reserved");
  Eio.Promise.resolve resolve_release_lock ();
  Fun.protect
    ~finally:(fun () ->
      ignore
        (Fence.rollback_shutdown
           ~base_path:config.base_path
           ~keeper_name
           ~operation_id
          : Fence.rollback_result);
      Masc.Keeper_keepalive.stop_keepalive keeper_name)
    (fun () ->
       let result = Eio.Promise.await create_done in
       check bool
         "production create keeps its admitted epoch through launch"
         true
         (Profile.tool_result_success result);
       (match Masc.Keeper_registry.get ~base_path:config.base_path keeper_name with
        | Some entry ->
          check string "exact launched keeper registered" keeper_name entry.name
        | None -> fail "production create returned without a registry lane");
       match Fence.shutdown_operation_id ~base_path:config.base_path ~keeper_name with
       | Some actual ->
         check bool
           "create handoff does not erase the later shutdown reservation"
           true
           (Operation_id.equal operation_id actual)
       | None -> fail "create handoff erased the later shutdown reservation")
;;

let () =
  Alcotest.run
    "keeper_create_admission_transaction"
    [ ( "feature"
      , [ test_case
            "shutdown rejection precedes session config runtime and owner writes"
            `Quick
            test_shutdown_rejection_precedes_all_creation_writes
        ; test_case
    "production create keeps create-wins intake admission through lane fork"
    `Quick
    test_create_wins_intake_fence_overlap_through_production_handoff
        ] )
    ]
;;
