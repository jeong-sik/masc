(** Mcp_server_eio_helpers — Small utility functions extracted from mcp_server_eio.ml

    Provides functions needed by both mcp_server_eio.ml and mcp_tool_runtime.ml
    without circular dependencies.
*)

(** Severity and grep tag for an exception logged via {!log_mcp_exn}.

    Recognised exceptions ([Sys_error] / [Failure] / [Not_found] /
    [End_of_file] / [Yojson.Json_error] / [Yojson.Safe.Util.Type_error]) are
    expected I/O / parse / control-flow outcomes in best-effort side channels
    (telemetry, identity resolution, activity-graph emit) and stay at [Info].
    Any other exception is unrecognised: tagged ["[UNEXPECTED] "] and raised to
    [Warn] so it surfaces above the [Info] noise floor.  It stays at [Warn]
    rather than [Error] because the caller still recovers (the side channel is
    swallowed and the SSE loop continues), and [Error] is reserved for
    unrecoverable faults (docs/spec/18-log-severity-taxonomy.md § 2 / § 3.6). *)
let mcp_exn_level_and_tag exn : Log.level * string =
  match exn with
  | Sys_error _ | Failure _ | Not_found | End_of_file
  | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> (Log.Info, "")
  | _ -> (Log.Warn, "[UNEXPECTED] ")

(** Log an MCP server-side exception at a severity derived from the exception
    class (see {!mcp_exn_level_and_tag}) rather than a hardcoded level.  Emits
    exactly one line. *)
let log_mcp_exn ~label exn =
  let level, tag = mcp_exn_level_and_tag exn in
  Log.Mcp.emit level (Printf.sprintf "%s%s: %s" tag label (Printexc.to_string exn))

(** Wait for message using Eio sleep - adapter for Session.registry *)
let wait_for_message_eio ~clock (registry : Session.registry) ~agent_name ~timeout =
  let start_time = Time_compat.now () in
  let check_interval = 2.0 in
  (match Session.get_session registry ~agent_name with
   | Some _ -> ()
   | None ->
       (try
          let _session = Session.register registry ~agent_name in
          ()
        with Eio.Cancel.Cancelled _ as e -> raise e | exn -> log_mcp_exn ~label:"session register (SSE) failed" exn));
  Session.update_activity registry ~agent_name ~is_listening:true ();
  let rec wait_loop () =
    let elapsed = Time_compat.now () -. start_time in
    if elapsed >= timeout then begin
      Session.update_activity registry ~agent_name ~is_listening:false ();
      None
    end else begin
      match Session.pop_message registry ~agent_name with
      | Some msg ->
          Session.update_activity registry ~agent_name ~is_listening:false ();
          Some msg
      | None ->
          Eio.Time.sleep clock check_interval;
          wait_loop ()
    end
  in
  try wait_loop ()
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    log_mcp_exn ~label:"listen wait_loop interrupted" exn;
    Session.update_activity registry ~agent_name ~is_listening:false ();
    None
