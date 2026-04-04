(** Tool_inline_dispatch_room — project lifecycle tool handlers.

    Handles: masc_start, masc_lock, masc_unlock, masc_set_project.

    Extracted from tool_inline_dispatch.ml to reduce file size.
    Room concept removed: join/leave presence tracking is gone.
    masc_start now just sets project root and optionally creates+claims a task. *)

open Tool_inline_dispatch_types

(** Argument extraction helpers bound to ctx.arguments. *)
let arg_get_string ctx key default =
  Safe_ops.json_string ~default key ctx.arguments

let extract_nickname_from_join_result ~fallback result =
  try
    let prefix = "  Nickname: " in
    let start_idx =
      let idx = ref 0 in
      while !idx < String.length result - String.length prefix
            && String.sub result !idx (String.length prefix) <> prefix
      do
        incr idx
      done;
      !idx + String.length prefix
    in
    let end_idx = String.index_from result start_idx '\n' in
    String.sub result start_idx (end_idx - start_idx)
  with Not_found | Invalid_argument _ ->
    fallback

let write_term_session_agent nickname =
  match Sys.getenv_opt "TERM_SESSION_ID" with
  | None -> ()
  | Some sid ->
      let file = Printf.sprintf "/tmp/.masc_agent_%s" sid in
      (try Fs_compat.save_file file nickname
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | e ->
           Log.Misc.error "Failed to write agent file %s: %s" file
             (Printexc.to_string e))

let cleanup_zombies_best_effort config ~label =
  try
    ignore (Room.cleanup_zombies config)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Log.Gc.warn "%s GC failed: %s" label (Printexc.to_string exn)

let ensure_agent_presence (ctx : context) active_config =
  let join_result = Room.join active_config ~agent_name:ctx.agent_name ~capabilities:[] () in
  let fallback = Room.resolve_agent_name active_config ctx.agent_name in
  let nickname = extract_nickname_from_join_result ~fallback join_result in
  let _ = Session.register ctx.registry ~agent_name:nickname in
  ctx.write_mcp_session_agent nickname;
  if Option.is_none ctx.mcp_session_id then begin
    Log.Misc.warn
      "[deprecated] writing agent name to /tmp file for TERM session in masc_start — migrate to Agent_identity";
    write_term_session_agent nickname
  end;
  let join_event =
    `Assoc
      [
        ("type", `String "masc/agent_joined");
        ("agent_name", `String nickname);
        ("timestamp", `Float (Time_compat.now ()));
      ]
  in
  let _ =
    Session.push_notification_to_active_agents ctx.registry ~event:join_event
  in
  Mcp_server.sse_broadcast ctx.state join_event;
  nickname

(** masc_start — set project root, register the caller, and optionally create+claim a task *)
let handle_start (ctx : context) : result option =
  let config = ctx.config in
  let _agent_name = ctx.agent_name in
  let state = ctx.state in
  let path =
    let p = arg_get_string ctx "path" "" in
    if p = "" then arg_get_string ctx "room" "" else p
  in
  let task_title = arg_get_string ctx "task_title" "" in
  (* Step 1: set project root *)
  let project_result =
    if path = "" then begin
      if Room.is_initialized state.Mcp_server.room_config then
        Ok config
      else
        Error "path is required when no project scope is set. Provide the project directory path."
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
  match project_result with
  | Error e ->
      Some
        (false,
         Printf.sprintf "masc_start failed while setting project scope: %s" e)
  | Ok active_config ->
      cleanup_zombies_best_effort active_config ~label:"masc_start";
      let nickname =
        try Ok (ensure_agent_presence ctx active_config)
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
            let msg = Printexc.to_string exn in
            if msg = "" then Error "agent registration failed" else Error msg
      in
      match nickname with
      | Error e ->
          Some
            (false,
             Printf.sprintf
               "masc_start failed while registering agent presence: %s" e)
      | Ok nickname ->
      (* Step 2: add_task + claim + plan_set_task (if task_title provided) *)
      if task_title = "" then
        Some
          (true,
           Printf.sprintf
             "masc_start complete (project scope set, registered as %s). No task created — use masc_add_task to create one."
             nickname)
      else begin
        let add_result = Room_task.add_task active_config ~title:task_title ~priority:3 ~description:"" in
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
               "masc_start partial: project scope set and registered as %s, but task creation failed: %s"
               nickname add_result)
        else begin
          let _claim_msg =
            Room_task.claim_task active_config ~agent_name:nickname ~task_id
          in
          Planning_eio.set_current_task active_config ~task_id;
          Some
            (true,
             Printf.sprintf
               "masc_start complete: project scope set, registered as %s, task %s created+claimed+set as current."
               nickname task_id)
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
             Some (true, Yojson.Safe.pretty_to_string payload)
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
             Some (true, Yojson.Safe.pretty_to_string payload)
         | Ok false ->
             Some (false, Printf.sprintf "Lock not held by %s: %s" agent_name expanded)
         | Error e ->
             Some (false, Printf.sprintf "Lock release error: %s" (Backend_types.show_error e)))
  end

(** masc_set_project — set the active MASC project root *)
let handle_set_project (ctx : context) : result option =
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
    let resolved = Room_utils_backend_setup.resolve_masc_base_path expanded in
    let masc_dir = Filename.concat resolved ".masc" in
    if not (Sys.file_exists masc_dir && Sys.is_directory masc_dir) then
      Some (false, Printf.sprintf "No .masc/ directory found in: %s\nRun masc_init to initialize, or choose a MASC-enabled directory." resolved)
    else begin
      state.Mcp_server.room_config <- Room.default_config expanded;
      let rc = state.Mcp_server.room_config in
      cleanup_zombies_best_effort rc ~label:"masc_set_project";
      let status = if Room.is_initialized rc then "ok" else "(not initialized)" in
      let root_note =
        if rc.workspace_path <> rc.base_path then
          Printf.sprintf
            "MASC project scope set.\n   coordination root: %s\n   workspace: %s\n   .masc/ status: %s"
            rc.base_path rc.workspace_path status
        else
          Printf.sprintf
            "MASC project scope set to: %s\n   .masc/ status: %s"
            rc.base_path status
      in
      Some (true, root_note)
    end
