(** Tool_inline_dispatch_room — room lifecycle tool handlers.

    Handles: masc_start, masc_lock, masc_unlock, masc_set_room,
    masc_join, masc_leave.

    Extracted from tool_inline_dispatch.ml to reduce file size. *)

open Tool_inline_dispatch_types

(** Argument extraction helpers bound to ctx.arguments. *)
let arg_get_string ctx key default =
  Safe_ops.json_string ~default key ctx.arguments

let arg_get_string_list ctx key =
  Safe_ops.json_string_list key ctx.arguments

(** masc_start — compound onboarding (set project root + join + optional task) *)
let handle_start (ctx : context) : result option =
  let config = ctx.config in
  let agent_name = ctx.agent_name in
  let state = ctx.state in
  let path =
    let p = arg_get_string ctx "path" "" in
    if p = "" then arg_get_string ctx "room" "" else p
  in
  let task_title = arg_get_string ctx "task_title" "" in
  (* Step 1: set project root / coordination namespace *)
  let room_result =
    if path = "" then begin
      (* Use current project namespace if already set *)
      if Room.is_initialized state.Mcp_server.room_config then
        Ok config
      else
        Error "path is required when no project namespace is set. Provide the project directory path."
    end else begin
      let expanded =
        if String.length path >= 2 && path.[0] = '~' && path.[1] = '/' then
          let home = match Sys.getenv_opt "HOME" with Some h -> h | None -> "/tmp" in
          Filename.concat home (String.sub path 2 (String.length path - 2))
        else if String.length path = 1 && path.[0] = '~' then
          (match Sys.getenv_opt "HOME" with Some h -> h | None -> "/tmp")
        else if Filename.is_relative path then
          Filename.concat (Sys.getcwd ()) path
        else
          path
      in
      if not (Sys.file_exists expanded && Sys.is_directory expanded) then
        Error (Printf.sprintf "Directory not found: %s" expanded)
      else begin
        let cfg = Room.default_config expanded in
        if Room.is_initialized cfg then begin
          state.Mcp_server.room_config <- cfg;
          Ok cfg
        end else begin
          let _msg = Room.init cfg ~agent_name:None in
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
        let _msg = Room.join active_config ~agent_name ~capabilities:[] () in
        Ok ()
      with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
        let msg = Printexc.to_string exn in
        if String.length msg > 0 then Error msg else Error "join failed"
    in
    match join_result with
    | Error e -> Some (false, Printf.sprintf "masc_start failed at join: %s\nHint: try masc_join separately." e)
    | Ok () ->
      (* Step 3: add_task + claim + plan_set_task (if task_title provided) *)
      if task_title = "" then
        Some
          (true,
           Printf.sprintf
             "masc_start complete (project scope set + joined as %s). No task created — use masc_add_task to create one."
             agent_name)
      else begin
        let add_result = Room_task.add_task active_config ~title:task_title ~priority:3 ~description:"" in
        (* Extract task ID from result like "Added task-001: title" *)
        let task_id =
          try
            let prefix = "Added " in
            let idx = ref 0 in
            while !idx < String.length add_result - String.length prefix &&
                  String.sub add_result !idx (String.length prefix) <> prefix do
              incr idx
            done;
            let start = !idx + String.length prefix in
            let end_idx = try String.index_from add_result start ':' with Not_found -> String.length add_result in
            String.sub add_result start (end_idx - start)
          with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ""
        in
        if task_id = "" then
          Some
            (true,
             Printf.sprintf
               "masc_start partial: joined as %s, but task creation failed: %s"
               agent_name add_result)
        else begin
          let _claim_msg = Room_task.claim_task active_config ~agent_name ~task_id in
          Planning_eio.set_current_task active_config ~task_id;
          Some
            (true,
             Printf.sprintf
               "masc_start complete: project scope set, joined as %s, task %s created+claimed+set as current."
               agent_name task_id)
        end
      end

(** masc_lock — acquire a file lock *)
let handle_lock (ctx : context) : result option =
  let config = ctx.config in
  let agent_name = ctx.agent_name in
  let file = arg_get_string ctx "file" "" in
  if file = "" then
    Some (false, "file is required")
  else begin
    let expanded =
      if String.length file > 0 && file.[0] = '~' then
        match Sys.getenv_opt "HOME" with
        | Some home -> Filename.concat home (String.sub file 1 (String.length file - 1))
        | None -> file
      else if Filename.is_relative file then
        Filename.concat config.base_path file
      else
        file
    in
    match Room_utils.key_of_path_from_root config ~root:config.base_path expanded with
    | None ->
        Some (false, Printf.sprintf "file must be under base_path: %s" config.base_path)
    | Some key ->
        let ttl_seconds = config.lock_expiry_minutes * 60 in
        let now = Time_compat.now () in
        let expires_at = now +. float_of_int ttl_seconds in
        (match Room_utils.backend_acquire_lock config ~key ~ttl_seconds ~owner:agent_name with
         | Ok true ->
             let payload = `Assoc [
               ("status", `String "acquired");
               ("resource", `String expanded);
               ("key", `String key);
               ("owner", `String agent_name);
               ("acquired_at", `Float now);
               ("expires_at", `Float expires_at);
             ] in
             Some (true, Yojson.Safe.to_string payload)
         | Ok false ->
             Some (false, Printf.sprintf "Lock busy: %s" expanded)
         | Error e ->
             Some (false, Printf.sprintf "Lock error: %s" (Backend_types.show_error e)))
  end

(** masc_unlock — release a file lock *)
let handle_unlock (ctx : context) : result option =
  let config = ctx.config in
  let agent_name = ctx.agent_name in
  let file = arg_get_string ctx "file" "" in
  if file = "" then
    Some (false, "file is required")
  else begin
    let expanded =
      if String.length file > 0 && file.[0] = '~' then
        match Sys.getenv_opt "HOME" with
        | Some home -> Filename.concat home (String.sub file 1 (String.length file - 1))
        | None -> file
      else if Filename.is_relative file then
        Filename.concat config.base_path file
      else
        file
    in
    match Room_utils.key_of_path_from_root config ~root:config.base_path expanded with
    | None ->
        Some (false, Printf.sprintf "file must be under base_path: %s" config.base_path)
    | Some key ->
        (match Room_utils.backend_release_lock config ~key ~owner:agent_name with
         | Ok true ->
             let payload = `Assoc [
               ("status", `String "released");
               ("resource", `String expanded);
               ("key", `String key);
               ("owner", `String agent_name);
             ] in
             Some (true, Yojson.Safe.to_string payload)
         | Ok false ->
             Some (false, Printf.sprintf "Lock not held by %s: %s" agent_name expanded)
         | Error e ->
             Some (false, Printf.sprintf "Lock release error: %s" (Backend_types.show_error e)))
  end

(** masc_set_room — set the active MASC project root *)
let handle_set_room (ctx : context) : result option =
  let state = ctx.state in
  let path =
    let p = arg_get_string ctx "path" "" in
    if p = "" then arg_get_string ctx "room" "" else p
  in
  if path = "" then
    Some
      (false,
       "path is required: provide the absolute or relative path to your project directory")
  else
  let expanded =
    if String.length path >= 2 && path.[0] = '~' && path.[1] = '/' then
      let home = match Sys.getenv_opt "HOME" with Some h -> h | None -> "/tmp" in
      Filename.concat home (String.sub path 2 (String.length path - 2))
    else if String.length path = 1 && path.[0] = '~' then
      (match Sys.getenv_opt "HOME" with Some h -> h | None -> "/tmp")
    else if Filename.is_relative path then
      Filename.concat (Sys.getcwd ()) path
    else
      path
  in
  if not (Sys.file_exists expanded && Sys.is_directory expanded) then
    Some (false, Printf.sprintf "Directory not found: %s" expanded)
  else
    (* Resolve to git root so worktree paths find the shared .masc/ directory *)
    let resolved = Room_utils_backend_setup.resolve_masc_base_path expanded in
    let masc_dir = Filename.concat resolved ".masc" in
    if not (Sys.file_exists masc_dir && Sys.is_directory masc_dir) then
      Some (false, Printf.sprintf "No .masc/ directory found in: %s\nRun masc_init to initialize, or choose a MASC-enabled directory." resolved)
    else begin
      state.Mcp_server.room_config <- Room.default_config expanded;
      let rc = state.Mcp_server.room_config in
      (* GC: reap zombie agents when entering a room (uses newly resolved config).
         Best-effort: GC failure must not block set_room. *)
      (try ignore (Room.cleanup_zombies rc)
       with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
         Log.Gc.warn "set_room GC failed: %s" (Printexc.to_string exn));
      let status = if Room.is_initialized rc then "ok" else "(not initialized)" in
      let root_note =
        if rc.workspace_path <> rc.base_path then
          Printf.sprintf
            "MASC project scope set.\n   coordination root: %s\n   workspace: %s\n   shared scope: default (flattened)\n   .masc/ status: %s"
            rc.base_path rc.workspace_path status
        else
          Printf.sprintf
            "MASC project scope set to: %s\n   shared scope: default (flattened)\n   .masc/ status: %s"
            rc.base_path status
      in
      Some (true, root_note)
    end

(** masc_join — join the active MASC project namespace *)
let handle_join (ctx : context) : result option =
  let config = ctx.config in
  let agent_name = ctx.agent_name in
  let registry = ctx.registry in
  let state = ctx.state in
  let mcp_session_id = ctx.mcp_session_id in
  let caps = arg_get_string_list ctx "capabilities" in
  let result = Room.join config ~agent_name ~capabilities:caps () in
  (* GC: reap zombie agents on join. Best-effort. *)
  (try ignore (Room.cleanup_zombies config)
   with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
     Log.Gc.warn "join GC failed: %s" (Printexc.to_string exn));
  (* Extract nickname from join result (format: "  Nickname: xxx\n...") *)
  let nickname =
    try
      let prefix = "  Nickname: " in
      let start_idx =
        let idx = ref 0 in
        while !idx < String.length result - String.length prefix &&
              String.sub result !idx (String.length prefix) <> prefix do
          incr idx
        done;
        !idx + String.length prefix
      in
      let end_idx = String.index_from result start_idx '\n' in
      String.sub result start_idx (end_idx - start_idx)
    with Not_found | Invalid_argument _ -> agent_name
  in
  let _ = Session.register registry ~agent_name:nickname in
  ctx.write_mcp_session_agent nickname;
  Log.Misc.debug "masc_join: saved nickname=%s to MCP session (original=%s)" nickname agent_name;
  (* Deprecated: /tmp file agent identity. Agent_identity system is primary.
     Remove when deprecation log shows zero hits over a release cycle. *)
  if Option.is_none mcp_session_id then begin
    Log.Misc.warn "[deprecated] writing agent name to /tmp file for TERM session — migrate to Agent_identity";
    let term_session_id = Option.value ~default:"default" (Sys.getenv_opt "TERM_SESSION_ID") in
    let agent_file = Printf.sprintf "/tmp/.masc_agent_%s" term_session_id in
    (try
      Fs_compat.save_file agent_file nickname
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e ->
      Log.Misc.error "Failed to write agent file %s: %s" agent_file (Printexc.to_string e))
  end;
  (* Cultural Inheritance: append institution welcome to join response *)
  let institution_welcome = match state.Mcp_server.fs with
    | Some fs ->
        (try Institution_eio.load_and_format_for_welcome ~fs config
         with
         | Eio.Io _ | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> ""
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | exn ->
             Log.Institution.warn "Unexpected institution error: %s" (Printexc.to_string exn); "")
    | None -> ""
  in
  let final_result = if institution_welcome = "" then result
    else result ^ institution_welcome in
  let join_event = `Assoc [
    ("type", `String "masc/agent_joined");
    ("agent_name", `String nickname);
    ("timestamp", `Float (Time_compat.now ()));
  ] in
  let _pushed = Session.push_notification_to_active_agents registry ~event:join_event in
  Mcp_server.sse_broadcast state join_event;
  Some (true, final_result)

(** masc_leave — leave a MASC room *)
let handle_leave (ctx : context) : result option =
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
  let result = Room.leave config ~agent_name in
  Session.unregister registry ~agent_name;
  if Option.is_none mcp_session_id then begin
    let session_id = Option.value ~default:"default" (Sys.getenv_opt "TERM_SESSION_ID") in
    let agent_file = Printf.sprintf "/tmp/.masc_agent_%s" session_id in
    Safe_ops.remove_file_logged ~context:"masc_leave" agent_file
  end;
  Some (true, result)
