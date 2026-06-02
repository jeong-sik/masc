(** Mcp_server_eio_helpers — Small utility functions extracted from mcp_server_eio.ml

    Provides functions needed by both mcp_server_eio.ml and tool_inline_dispatch.ml
    without circular dependencies.
*)

(** Log an MCP server error with [UNEXPECTED] tag for unrecognized exceptions. *)
let log_mcp_exn ~label exn =
  let tag = match exn with
    | Sys_error _ | Failure _ | Not_found | End_of_file
    | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> ""
    | _ -> "[UNEXPECTED] "
  in
  Log.Mcp.info "%s%s: %s" tag label (Printexc.to_string exn)

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
