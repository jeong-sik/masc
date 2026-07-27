open Masc

module Types = Masc_domain

let () = Mirage_crypto_rng_unix.use_default ()
let () =
  Server_startup_state.mark_state_ready
    ~backend:Server_startup_state.Filesystem_backend
  |> Result.get_ok

external unsetenv : string -> unit = "masc_test_unsetenv"

let temp_base_path_scopes = Hashtbl.create 8

let restore_env name = function
  | Some value -> Unix.putenv name value
  | None -> unsetenv name

let temp_dir () =
  let dir = Filename.temp_file "test_operator_control_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  Hashtbl.replace
    temp_base_path_scopes
    dir
    ( Sys.getenv_opt Env_config_core.base_path_env_key
    , Sys.getenv_opt Env_config_core.base_path_input_env_key );
  Unix.putenv Env_config_core.base_path_env_key dir;
  Unix.putenv Env_config_core.base_path_input_env_key dir;
  dir

(** Ensure Fs_compat has the Eio fs handle set.
    Call inside Eio_main.run before creating Workspace config. *)
let ensure_fs env =
  Masc_test_deps.init_eio_clock env;
  (* An Eio filesystem capability is owned by the current scheduler. This test
     executable creates a fresh [Eio_main.run] per case, so retaining the first
     capability would leak a dead scheduler resource into later cases. *)
  Fs_compat.set_fs (Eio.Stdenv.fs env)

let with_fd_backed_lifecycle_head_parents fn =
  Keeper_lifecycle_admission.Durable_transaction.For_testing
  .with_fd_backed_parent_opening
  @@ fun () ->
  Keeper_lifecycle_nonce.For_testing.with_fd_backed_parent_opening
  @@ fun () ->
  Keeper_dead_revival_transaction.For_testing.with_fd_backed_parent_opening fn
;;

let publication_recovery_registry env sw config =
  let registry_root =
    Eio.Path.(Eio.Stdenv.fs env / Workspace.masc_root_dir config)
  in
  match
    Fs_compat.Publication_recovery.open_registry
      ~sw
      ~fs:(Eio.Stdenv.fs env)
      ~registry_root
  with
  | Ok registry -> registry
  | Error error ->
    Alcotest.fail
      (Fs_compat.Publication_recovery.registry_error_to_string error)

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  Fun.protect
    ~finally:(fun () ->
      match Hashtbl.find_opt temp_base_path_scopes dir with
      | None -> ()
      | Some (base_path, base_path_input) ->
        Hashtbl.remove temp_base_path_scopes dir;
        restore_env Env_config_core.base_path_env_key base_path;
        restore_env Env_config_core.base_path_input_env_key base_path_input)
    (fun () -> try rm dir with _ -> ())

let parse_json_exn body =
  try Yojson.Safe.from_string body
  with Yojson.Json_error err -> failwith ("invalid json: " ^ err)

let result_field json = Yojson.Safe.Util.member "result" json

let operator_ctx ?mcp_session_id env sw config agent_name :
    _ Operator_control.context =
  let publication_recovery_provider =
    Masc_test_deps.publication_recovery_provider
      (publication_recovery_registry env sw config)
  in
  {
    config;
    agent_name;
    sw;
    clock = Eio.Stdenv.clock env;
    proc_mgr = Some (Eio.Stdenv.process_mgr env);
    net = Some (Eio.Stdenv.net env);
    delegated_dispatch =
      Some
        (Masc.Keeper_tool_boundary.delegated_dispatch
           ~config
           ~agent_name
           ~sw
           ~clock:(Eio.Stdenv.clock env)
           ~proc_mgr:(Some (Eio.Stdenv.process_mgr env))
           ~net:(Some (Eio.Stdenv.net env))
           ~publication_recovery_provider
           ());
    mcp_session_id;
  }

let dispatch_keeper_exn ctx ~name ~args =
  match Keeper_tool_surface.dispatch ctx ~name ~args with
  | Some result -> Tool_result.is_success result, Tool_result.message result
  | None -> failwith ("keeper dispatch missing: " ^ name)

let iso_of_unix unix_ts =
  let tm = Unix.gmtime unix_ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let record_operator_judgment config ~surface ~target_type ~target_id ~summary ?recommended_action ~fresh_for_sec () =
  let now_unix = Unix.gettimeofday () in
  ignore
    (Operator_judgment.record config ~surface ~target_type ~target_id ~summary
       ~confidence:0.91 ?recommended_action ~generated_at:(Masc_domain.now_iso ())
       ~generated_at_unix:now_unix
       ~fresh_until:(iso_of_unix (now_unix +. fresh_for_sec))
       ~fresh_until_unix:(now_unix +. fresh_for_sec)
       ~keeper_name:"operator-judge" ())
