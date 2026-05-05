open Masc_mcp

module Types = Masc_domain

let () = Mirage_crypto_rng_unix.use_default ()
let () = Server_startup_state.mark_state_ready ~backend_mode:"test"

let temp_dir () =
  let dir = Filename.temp_file "test_operator_control_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

(** Ensure Fs_compat has the Eio fs handle set.
    Call inside Eio_main.run before creating Coord config. *)
let ensure_fs env =
  Masc_test_deps.init_eio_clock env;
  if not (Fs_compat.has_fs ()) then
    Fs_compat.set_fs (Eio.Stdenv.fs env)

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let parse_json_exn body =
  try Yojson.Safe.from_string body
  with Yojson.Json_error err -> failwith ("invalid json: " ^ err)

let result_field json = Yojson.Safe.Util.member "result" json

let operator_ctx ?mcp_session_id env sw config agent_name :
    _ Operator_control.context =
  {
    config;
    agent_name;
    sw;
    clock = Eio.Stdenv.clock env;
    proc_mgr = Some (Eio.Stdenv.process_mgr env);
    net = Some (Eio.Stdenv.net env);
    mcp_session_id;
  }

let dispatch_keeper_exn ctx ~name ~args =
  match Tool_keeper.dispatch ctx ~name ~args with
  | Some result -> result
  | None -> failwith ("keeper dispatch missing: " ^ name)

(* unit_update_exn / start_operation_exn removed (CP purge: Command_plane_v2 deleted) *)

let iso_of_unix unix_ts =
  let tm = Unix.gmtime unix_ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let record_operator_judgment config ~surface ~target_type ~target_id ~summary
    ?recommended_action ~fresh_for_sec () =
  let now_unix = Unix.gettimeofday () in
  ignore
    (Operator_judgment.record config ~surface ~target_type ~target_id ~summary
       ~confidence:0.91 ?recommended_action ~generated_at:(Types.now_iso ())
       ~generated_at_unix:now_unix
       ~fresh_until:(iso_of_unix (now_unix +. fresh_for_sec))
       ~fresh_until_unix:(now_unix +. fresh_for_sec)
       ~keeper_name:"operator-judge" ())

(* setup_swarm_run_env removed (CP purge: Command_plane_v2 deleted) *)
