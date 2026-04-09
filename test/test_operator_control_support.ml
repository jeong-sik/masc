open Masc_mcp

let () = Mirage_crypto_rng_unix.use_default ()
let () = Server_startup_state.mark_state_ready ~backend_mode:"test"

let temp_dir () =
  let dir = Filename.temp_file "test_operator_control_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

(** Ensure Fs_compat has the Eio fs handle set.
    Call inside Eio_main.run before creating Room config. *)
let ensure_fs env =
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

(** Team session context stub — team session tools are removed.
    Uses unit type to satisfy callers that still reference team_ctx. *)
let team_ctx _env _sw _config _agent_name = ()

let dispatch_team_exn _ctx ~name ~args:_ =
  failwith ("team session tools removed: " ^ name)

let start_session_exn _ctx =
  failwith "team session tools removed: cannot start session"

let dispatch_keeper_exn ctx ~name ~args =
  match Tool_keeper.dispatch ctx ~name ~args with
  | Some result -> result
  | None -> failwith ("keeper dispatch missing: " ^ name)

let unit_update_exn config ~actor args =
  match Command_plane_v2.unit_update_json config ~actor args with
  | Ok _ -> ()
  | Error message -> failwith message

let start_operation_exn config ~actor args =
  match Command_plane_v2.start_operation config ~actor args with
  | Ok operation -> operation
  | Error message -> failwith message

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

let setup_swarm_run_env config ~owner ~worker_one ~worker_two ~run_id =
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:owner ~capabilities:[] ());
  ignore (Room.join config ~agent_name:worker_one ~capabilities:[] ());
  ignore (Room.join config ~agent_name:worker_two ~capabilities:[] ());
  unit_update_exn config ~actor:owner
    (`Assoc
      [
        ("unit_id", `String "company-main");
        ("kind", `String "company");
        ("label", `String "Main Company");
        ("leader_id", `String owner);
        ("roster", `List [ `String owner; `String worker_one; `String worker_two ]);
      ]);
  unit_update_exn config ~actor:owner
    (`Assoc
      [
        ("unit_id", `String "platoon-alpha");
        ("kind", `String "platoon");
        ("label", `String "Alpha Platoon");
        ("parent_unit_id", `String "company-main");
        ("leader_id", `String worker_one);
        ("roster", `List [ `String worker_one; `String worker_two ]);
      ]);
  let operation =
    start_operation_exn config ~actor:owner
      (`Assoc
        [
          ("assigned_unit_id", `String "company-main");
          ("objective", `String "Operator swarm resolution test");
          ("note", `String (Printf.sprintf "run_id=%s" run_id));
          ("policy_class", `String "guarded");
          ("budget_class", `String "standard");
        ])
  in
  ignore
    (match
       Command_plane_v2.dispatch_tick_json config ~actor:owner
         (`Assoc [ ("operation_id", `String operation.operation_id) ])
     with
    | Ok _ -> ()
    | Error message -> failwith message);
  operation
