module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Tool_inline_dispatch_coord — room lifecycle tool handlers.

    Handles: masc_start, masc_join, masc_leave.

    Extracted from tool_inline_dispatch.ml to reduce file size. *)

open Tool_inline_dispatch_types

(** Argument extraction helpers bound to ctx.arguments. *)
let arg_get_string ctx key default =
  Safe_ops.json_string ~default key ctx.arguments

let arg_get_string_list ctx key =
  Safe_ops.json_string_list key ctx.arguments

(** masc_start — compound onboarding (set project root + join + optional task) *)
let handle_start (ctx : context) : tool_result option =
  let config = ctx.config in
  let agent_name = ctx.agent_name in
  let state = ctx.state in
  let path =
    let p = arg_get_string ctx "path" "" in
    if String.equal p "" then arg_get_string ctx "room" "" else p
  in
  let task_title = arg_get_string ctx "task_title" "" in
  (* Step 1: set project root *)
  let room_result =
    if String.equal path "" then begin
      if Coord.is_initialized state.Mcp_server.room_config then
        Ok config
      else
        Error "path is required when no project scope is set. Provide the project directory path."
    end else begin
      let expanded =
        if String.length path >= 2 && Char.equal path.[0] '~' && Char.equal path.[1] '/' then
          let home = match Sys.getenv_opt "HOME" with Some h -> h | None -> "/tmp" in
          Filename.concat home (String.sub path 2 (String.length path - 2))
        else if String.length path = 1 && Char.equal path.[0] '~' then
          (match Sys.getenv_opt "HOME" with Some h -> h | None -> "/tmp")
        else if Filename.is_relative path then
          Filename.concat (Sys.getcwd ()) path
        else
          path
      in
      if not (Sys.file_exists expanded && Sys.is_directory expanded) then
        Error (Printf.sprintf "Directory not found: %s" expanded)
      else begin
        let cfg = Coord.default_config expanded in
        if Coord.is_initialized cfg then begin
          state.Mcp_server.room_config <- cfg;
          Ok cfg
        end else begin
          let _msg = Coord.init cfg ~agent_name:None in
          state.Mcp_server.room_config <- cfg;
          Ok cfg
        end
      end
    end
  in
  match room_result with
  | Error e ->
      Some
        (false,
         Printf.sprintf "masc_start failed while setting project scope: %s" e)
  | Ok active_config ->
    (* Step 2: join (idempotent — skip if already joined) *)
    let join_result =
      try
        let _msg = Coord.join active_config ~agent_name ~capabilities:[] () in
        Ok ()
      with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
        let msg = Stdlib.Printexc.to_string exn in
        if String.length msg > 0 then Error msg else Error "join failed"
    in
    match join_result with
    | Error e -> Some (false, Printf.sprintf "masc_start failed at join: %s\nHint: try masc_join separately." e)
    | Ok () ->
      (* Step 3: add_task + claim + plan_set_task (if task_title provided) *)
      if String.equal task_title "" then
        Some
          (true,
           Printf.sprintf
             "masc_start complete (project scope set + joined as %s). No task created — use masc_add_task to create one."
             agent_name)
      else begin
        let add_result = Coord_task.add_task active_config ~title:task_title ~priority:3 ~description:"" in
        (* Extract task ID from result like "Added task-001: title" *)
        let task_id =
          try
            let prefix = "Added " in
            let idx = ref 0 in
            while !idx < String.length add_result - String.length prefix &&
                  not (String.equal (Stdlib.String.sub add_result !idx (String.length prefix)) prefix) do
              Stdlib.incr idx
            done;
            let start = !idx + String.length prefix in
            let end_idx = match String.index_from_opt add_result start ':' with
              | Some idx -> idx
              | None -> String.length add_result
            in
            String.sub add_result start (end_idx - start)
          with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ""
        in
        if String.equal task_id "" then
          Some
            (true,
             Printf.sprintf
               "masc_start partial: joined as %s, but task creation failed: %s"
               agent_name add_result)
        else begin
          let _claim_msg = Coord_task.claim_task active_config ~agent_name ~task_id in
          Planning_eio.set_current_task active_config ~task_id;
          Some
            (true,
             Printf.sprintf
               "masc_start complete: project scope set, joined as %s, task %s created+claimed+set as current."
               agent_name task_id)
        end
      end

(** masc_join — join the active MASC project *)
let handle_join (ctx : context) : tool_result option =
  let config = ctx.config in
  let agent_name = ctx.agent_name in
  let registry = ctx.registry in
  let state = ctx.state in
  let mcp_session_id = ctx.mcp_session_id in
  let sid = Option.value ~default:"-" mcp_session_id in
  let caps = arg_get_string_list ctx "capabilities" in
  let proceed_with_join resolved_name =
    let result =
      Coord.join config ~agent_name:resolved_name ~capabilities:caps ()
    in
    (* GC: reap zombie agents on join. Best-effort. *)
    (try let _ = Coord.cleanup_zombies config in ()
     with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
       Log.Gc.warn "[sid=%s] join GC failed: %s" sid (Stdlib.Printexc.to_string exn));
    (* Extract nickname from join result (format: "  Nickname: xxx\n...") *)
    let nickname =
      try
        let prefix = "  Nickname: " in
        let start_idx =
          let idx = ref 0 in
          while !idx < String.length result - String.length prefix &&
                not (String.equal (Stdlib.String.sub result !idx (String.length prefix)) prefix) do
            Stdlib.incr idx
          done;
          !idx + String.length prefix
        in
        let end_idx = match String.index_from_opt result start_idx '\n' with
          | Some idx -> idx
          | None -> String.length result
        in
        String.sub result start_idx (end_idx - start_idx)
      with Invalid_argument _ -> agent_name
    in
    let _ = Session.register registry ~agent_name:nickname in
    ctx.write_mcp_session_agent nickname;
    Log.Misc.debug "[sid=%s] masc_join: saved nickname=%s to MCP session (original=%s)" sid nickname agent_name;
    if Option.is_none mcp_session_id then begin
      Log.Misc.warn "[sid=%s] [deprecated] writing agent name to /tmp file for TERM session — migrate to Agent_identity" sid;
      let term_session_id = Option.value ~default:"default" (Sys.getenv_opt "TERM_SESSION_ID") in
      let agent_file = Printf.sprintf "/tmp/.masc_agent_%s" term_session_id in
      (try
        Fs_compat.save_file agent_file nickname
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | e ->
        Log.Misc.error "[sid=%s] Failed to write agent file %s: %s" sid agent_file (Stdlib.Printexc.to_string e))
    end;
    let institution_welcome = match state.Mcp_server.fs with
      | Some fs ->
          (try Institution_eio.load_and_format_for_welcome ~fs config
           with
           | Eio.Io _ | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> ""
           | Eio.Cancel.Cancelled _ as exn -> raise exn
           | exn ->
               Log.Institution.warn "[sid=%s] Unexpected institution error: %s" sid (Stdlib.Printexc.to_string exn); "")
      | None -> ""
    in
    let final_result = if String.equal institution_welcome "" then result
      else result ^ institution_welcome in
    let join_event = `Assoc [
      ("type", `String "masc/agent_joined");
      ("agent_name", `String nickname);
      ("timestamp", `Float (Time_compat.now ()));
    ] in
    let _pushed = Session.push_notification_to_active_agents registry ~event:join_event in
    Mcp_server.sse_broadcast state join_event;
    Some (true, final_result)
  in
  (* RFC P3-a — fail-closed identity gate.
     Keeper_identity.normalize_all_names validates the agent identity
     against persona + credential filesystem checks.  When validation
     fails, the join is rejected rather than silently accepted.
     Previously, normalize errors were logged and the join proceeded
     with the original agent_name (fail-open), causing persona drift
     and downstream credential resolution failures. *)
  match
    Keeper_identity.normalize_all_names
      ~input_agent_name:agent_name
      ~base_path:config.base_path
      ~check_persona:true ~check_credential:true ()
  with
  | Ok bundle ->
      Prometheus.inc_counter Prometheus.metric_coord_join_normalize_outcome
        ~labels:[ ("outcome", "ok") ] ();
      proceed_with_join bundle.keeper_name
  | Error err ->
      let outcome = Keeper_identity.validation_error_outcome_label err in
      Prometheus.inc_counter Prometheus.metric_coord_join_normalize_outcome
        ~labels:[ ("outcome", outcome) ] ();
      Log.Misc.warn
        "[sid=%s] [fail-closed:coord_join_normalize] agent=%s outcome=%s \
         detail=%s - join rejected"
        sid agent_name outcome
        (Keeper_identity.show_validation_error err);
      Some
        ( false,
          Printf.sprintf
            "masc_join rejected: identity validation failed for '%s' — %s. \
             Ensure the persona and credential files exist for this agent."
            agent_name (Keeper_identity.show_validation_error err) )

(** masc_leave — leave a MASC room *)
let handle_leave (ctx : context) : tool_result option =
  let config = ctx.config in
  let agent_name = ctx.agent_name in
  let registry = ctx.registry in
  let state = ctx.state in
  let mcp_session_id = ctx.mcp_session_id in
  let leave_event = `Assoc [
    ("type", `String "masc/agent_left");
    ("agent_name", `String agent_name);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  let _pushed = Session.push_notification_to_active_agents registry ~event:leave_event in
  Mcp_server.sse_broadcast state leave_event;
  let result = Coord.leave config ~agent_name in
  Session.unregister registry ~agent_name;
  if Option.is_none mcp_session_id then begin
    let session_id = Option.value ~default:"default" (Sys.getenv_opt "TERM_SESSION_ID") in
    let agent_file = Printf.sprintf "/tmp/.masc_agent_%s" session_id in
    Safe_ops.remove_file_logged ~context:"masc_leave" agent_file
  end;
  Some (true, result)
