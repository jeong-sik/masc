(** Tool_inline_dispatch — Remaining inline tool handlers

    Extracted from mcp_server_eio.ml to reduce file size.
    Handles tools that have not yet been moved to their own Tool_xxx modules:

    - masc_lock / masc_unlock
    - masc_set_room
    - masc_join / masc_leave
    - masc_bounded_run
    - masc_broadcast
    - masc_messages / masc_listen / masc_who
    - masc_verify_*
    - masc_mcp_session
    - masc_cancellation / masc_subscription / masc_progress
    - masc_interrupt / masc_approve / masc_reject / masc_pending_interrupts
    - masc_branch
    - masc_governance_set
    - masc_spawn
    - masc_memento_mori
    - masc_episode_flush / masc_episode_list
    - masc_self_introspect
    - masc_recall_search
    - masc_board_post / masc_board_comment / masc_board_*
    - lodge_*
    - masc_convo_*
*)

type result = bool * string

(** Context record capturing all bindings from execute_tool_eio
    that the inline dispatch block needs. *)
type context = {
  config : Room.config;
  agent_name : string;
  registry : Session.registry;
  state : Mcp_server.server_state;
  sw : Eio.Switch.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t;
  arguments : Yojson.Safe.t;
  mcp_session_id : string option;
  (** Write agent name to MCP session file for HTTP persistence *)
  write_mcp_session_agent : string -> unit;
  (** Wait for a message from a given agent *)
  wait_for_message :
    Session.registry ->
    agent_name:string ->
    timeout:float ->
    Yojson.Safe.t option;
  (** Governance types/helpers — passed in to avoid circular deps *)
  governance_defaults : string -> Mcp_server_eio_governance.governance_config;
  save_governance :
    Room.config -> Mcp_server_eio_governance.governance_config -> unit;
  load_mcp_sessions : Room.config -> Mcp_server_eio_governance.mcp_session_record list;
  save_mcp_sessions :
    Room.config -> Mcp_server_eio_governance.mcp_session_record list -> unit;
}

(** Helper: run subprocess with 60s timeout *)
let safe_exec args =
  match Process_eio.run_argv_with_status ~timeout_sec:60.0 args with
  | Unix.WEXITED 0, output -> (true, output)
  | _, output -> (false, if output = "" then "Command failed" else output)

(** Dispatch a tool call.
    Returns [Some (success, message)] if the tool name is handled,
    [None] if the tool name is not recognized by this module. *)
let dispatch (ctx : context) ~(name : string) : result option =
  let config = ctx.config in
  let agent_name = ctx.agent_name in
  let registry = ctx.registry in
  let state = ctx.state in
  let sw = ctx.sw in
  let clock = ctx.clock in
  let arguments = ctx.arguments in
  let mcp_session_id = ctx.mcp_session_id in

  (* Argument extraction helpers — delegate to Safe_ops *)
  let arg_get_string key default =
    Safe_ops.json_string ~default key arguments
  in
  let arg_get_int key default =
    Safe_ops.json_int ~default key arguments
  in
  let arg_get_float key default =
    Safe_ops.json_float ~default key arguments
  in
  let arg_get_bool key default =
    Safe_ops.json_bool ~default key arguments
  in
  let arg_get_string_list key =
    Safe_ops.json_string_list key arguments
  in
  let arg_get_string_opt key =
    match Safe_ops.json_string_opt key arguments with
    | Some "" -> None
    | other -> other
  in
  let _arg_get_int_opt _key = () in  (* unused but kept for symmetry *)
  let _arg_get_float_opt key =
    Safe_ops.json_float_opt key arguments
  in

  match name with
  (* ── Compound onboarding: masc_start ──────────────────────────── *)
  | "masc_start" ->
      let path =
        let p = arg_get_string "path" "" in
        if p = "" then arg_get_string "room" "" else p
      in
      let task_title = arg_get_string "task_title" "" in
      (* Step 1: set_room *)
      let room_result =
        if path = "" then begin
          (* Use current room if already set *)
          if Room.is_initialized state.Mcp_server.room_config then
            Ok config
          else
            Error "path is required when no room is set. Provide the project directory path."
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
          else
            let masc_dir = Filename.concat expanded ".masc" in
            if not (Sys.file_exists masc_dir && Sys.is_directory masc_dir) then
              Error (Printf.sprintf "No .masc/ directory in %s. Use masc_init first." expanded)
            else begin
              state.Mcp_server.room_config <- Room.default_config expanded;
              Ok state.Mcp_server.room_config
            end
        end
      in
      begin match room_result with
      | Error e -> Some (false, Printf.sprintf "masc_start failed at set_room: %s" e)
      | Ok active_config ->
        (* Step 2: join (idempotent — skip if already joined) *)
        let join_result =
          try
            let _msg = Room.join active_config ~agent_name ~capabilities:[] () in
            Ok ()
          with exn ->
            let msg = Printexc.to_string exn in
            if String.length msg > 0 then Error msg else Error "join failed"
        in
        match join_result with
        | Error e -> Some (false, Printf.sprintf "masc_start failed at join: %s\nHint: try masc_join separately." e)
        | Ok () ->
          (* Step 3: add_task + claim + plan_set_task (if task_title provided) *)
          if task_title = "" then
            Some (true, Printf.sprintf "masc_start complete (room set + joined as %s). No task created — use masc_add_task to create one." agent_name)
          else begin
            let add_result = Room_task.add_task active_config ~title:task_title ~priority:3 ~description:"" in
            (* Extract task ID from result like "✅ Added task-001: title" *)
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
              with _ -> ""
            in
            if task_id = "" then
              Some (true, Printf.sprintf "masc_start partial: joined as %s, but task creation failed: %s" agent_name add_result)
            else begin
              let _claim_msg = Room_task.claim_task active_config ~agent_name ~task_id in
              Planning_eio.set_current_task active_config ~task_id;
              Some (true, Printf.sprintf "masc_start complete: room set, joined as %s, task %s created+claimed+set as current." agent_name task_id)
            end
          end
      end

  | "masc_lock" ->
      let file = arg_get_string "file" "" in
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
                 Some (false, Printf.sprintf "Lock error: %s" (Backend.show_error e)))
      end

  | "masc_unlock" ->
      let file = arg_get_string "file" "" in
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
                 Some (false, Printf.sprintf "Lock release error: %s" (Backend.show_error e)))
      end

  | "masc_set_room" ->
      let path =
        let p = arg_get_string "path" "" in
        if p = "" then arg_get_string "room" "" else p
      in
      if path = "" then
        Some (false, "path is required: provide the absolute or relative path to your project directory")
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
        let masc_dir = Filename.concat expanded ".masc" in
        if not (Sys.file_exists masc_dir && Sys.is_directory masc_dir) then
          Some (false, Printf.sprintf "No .masc/ directory found in: %s\nRun masc_init to initialize, or choose a MASC-enabled directory." expanded)
        else begin
          state.Mcp_server.room_config <- Room.default_config expanded;
          let status = if Room.is_initialized state.Mcp_server.room_config then "ok" else "(not initialized)" in
          Some (true, Printf.sprintf "MASC room set to: %s\n   .masc/ status: %s" expanded status)
        end

  | "masc_join" ->
      let caps = arg_get_string_list "capabilities" in
      let result = Room.join config ~agent_name ~capabilities:caps () in
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
      if Option.is_none mcp_session_id then begin
        let term_session_id = Option.value ~default:"default" (Sys.getenv_opt "TERM_SESSION_ID") in
        let agent_file = Printf.sprintf "/tmp/.masc_agent_%s" term_session_id in
        (try
          Fs_compat.save_file agent_file nickname
        with e ->
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
                 Eio.traceln "[WARN] Unexpected institution error: %s" (Printexc.to_string exn); "")
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
      Audit_log.log_join config ~agent_id:nickname
        ~room_id:(Filename.basename config.base_path) ();
      Prometheus.inc_gauge "masc_active_agents" ();
      (match state.Mcp_server.fs with
       | Some fs ->
           (try Telemetry_eio.track_agent_joined ~fs config ~agent_id:nickname ()
            with
            | Eio.Cancel.Cancelled _ as exn -> raise exn
            | exn ->
              Log.Telemetry.debug "track_agent_joined (join): %s" (Printexc.to_string exn))
       | None -> ());
      Some (true, final_result)

  | "masc_leave" ->
      let leave_event = `Assoc [
        ("type", `String "masc/agent_left");
        ("agent_name", `String agent_name);
        ("timestamp", `Float (Time_compat.now ()));
      ] in
      let _pushed = Session.push_notification_to_active_agents registry ~event:leave_event in
      Mcp_server.sse_broadcast state leave_event;
      let result = Room.leave config ~agent_name in
      Session.unregister_sync registry ~agent_name;
      if Option.is_none mcp_session_id then begin
        let session_id = Option.value ~default:"default" (Sys.getenv_opt "TERM_SESSION_ID") in
        let agent_file = Printf.sprintf "/tmp/.masc_agent_%s" session_id in
        Safe_ops.remove_file_logged ~context:"masc_leave" agent_file
      end;
      Audit_log.log_leave config ~agent_id:agent_name
        ~room_id:(Filename.basename config.base_path) ();
      Prometheus.dec_gauge "masc_active_agents" ();
      (match state.Mcp_server.fs with
       | Some fs ->
           (try Telemetry_eio.track_agent_left ~fs config ~agent_id:agent_name ~reason:"leave"
            with
            | Eio.Cancel.Cancelled _ as exn -> raise exn
            | exn ->
              Log.Telemetry.debug "track_agent_left: %s" (Printexc.to_string exn))
       | None -> ());
      Some (true, result)

  | "masc_bounded_run" ->
      let module U = Yojson.Safe.Util in
      let agents = match arguments |> U.member "agents" with
        | `List l -> List.filter_map (function `String s -> Some s | _ -> None) l
        | _ -> []
      in
      let prompt = arg_get_string "prompt" "" in
      let constraints_json = arguments |> U.member "constraints" in
      let goal_json = arguments |> U.member "goal" in
      let constraints = Bounded.constraints_of_json constraints_json in
      let goal = Bounded.goal_of_json goal_json in
      (match state.Mcp_server.proc_mgr with
       | Some _pm ->
           let spawn_fn agent_name prompt =
             Spawn_eio.spawn ~sw ~agent_name ~prompt
               ~timeout_seconds:Env_config.Spawn.timeout_seconds
               ~room_config:state.Mcp_server.room_config ()
           in
           let result = Bounded.bounded_run ~constraints ~goal ~agents ~prompt ~spawn_fn in
           let json = Bounded.result_to_json result in
           Some (result.Bounded.status = `Goal_reached, Yojson.Safe.pretty_to_string json)
       | None ->
           Some (false, "Process manager not available"))

  | "masc_broadcast" ->
      let message = arg_get_string "message" "" in
      let allowed, wait_secs = Session.check_rate_limit registry ~agent_name in
      if not allowed then
        Some (false, Printf.sprintf "Rate limited. %d sec remaining." wait_secs)
      else begin
        let result = Room.broadcast config ~from_agent:agent_name ~content:message in
        let mention = Mention.extract message in
        let _ = Session.push_message registry ~from_agent:agent_name ~content:message ~mention in
        let notification = `Assoc [
          ("type", `String "masc/broadcast");
          ("from", `String agent_name);
          ("content", `String message);
          ("mention", match mention with Some m -> `String m | None -> `Null);
          ("timestamp", `Float (Time_compat.now ()));
        ] in
        Mcp_server.sse_broadcast state notification;
        Subscriptions.push_event_to_sessions notification;
        (match mention with
         | Some target -> Notify.notify_mention ~from_agent:agent_name ~target_agent:target ~message ()
         | None -> ());
        A2a_tools.notify_event
          ~event_type:A2a_tools.Broadcast
          ~agent:agent_name
          ~data:(`Assoc [
            ("message", `String message);
            ("mention", match mention with Some m -> `String m | None -> `Null);
          ]);
        let _ = Auto_responder.maybe_respond
          ~sw
          ~base_path:config.base_path
          ~from_agent:agent_name
          ~content:message
          ~mention
        in
        Team_session_engine_eio.increment_broadcast_from_external config
          ~agent_name;
        Audit_log.log_broadcast config ~agent_id:agent_name
          ~room_id:(Filename.basename config.base_path)
          ~message_preview:message ();
        Some (true, result)
      end

  | "masc_messages" ->
      let since_seq = arg_get_int "since_seq" 0 in
      let limit = arg_get_int "limit" 10 in
      Some (true, Room.get_messages config ~since_seq ~limit)

  | "masc_listen" ->
      let timeout = float_of_int (arg_get_int "timeout" 300) in
      Log.Mcp.info "%s is now listening (timeout: %.0fs)..." agent_name timeout;
      let msg_opt = ctx.wait_for_message registry ~agent_name ~timeout in
      (match msg_opt with
       | Some msg ->
           let from = match Json_util.get_string msg "from" with Some v -> v | None -> raise Not_found in
           let content = match Json_util.get_string msg "content" with Some v -> v | None -> raise Not_found in
           let timestamp = match Json_util.get_string msg "timestamp" with Some v -> v | None -> raise Not_found in
           Some (true, Printf.sprintf {|
MESSAGE RECEIVED
From: %s
Time: %s

%s

Call masc_listen again to continue listening.
|} from timestamp content)
       | None ->
           Some (true, Printf.sprintf "Listening timed out after %.0fs. No messages received." timeout))

  | "masc_who" ->
      Some (true, Session.status_string registry)

  | "masc_verify_request" | "masc_verify_submit" | "masc_verify_status"
  | "masc_verify_pending" | "masc_verify_auto" ->
      Some (Tool_verification.dispatch config agent_name name arguments)

  | "masc_mcp_session" ->
      let action = arg_get_string "action" "" in
      let now = Time_compat.now () in
      let sessions = ctx.load_mcp_sessions config in
      let save sessions = ctx.save_mcp_sessions config sessions in
      let response =
        match action with
        | "create" ->
            let agent_name = arg_get_string_opt "agent_name" in
            let id = Mcp_session.generate () in
            let record : Mcp_server_eio_governance.mcp_session_record =
              { id; agent_name; created_at = now; last_seen = now } in
            save (record :: sessions);
            Ok (`Assoc [
              ("status", `String "created");
              ("session", Mcp_server_eio_governance.mcp_session_to_json record);
            ])
        | "get" ->
            let session_id = arg_get_string "session_id" "" in
            (match List.find_opt (fun (s : Mcp_server_eio_governance.mcp_session_record) -> s.id = session_id) sessions with
             | None -> Error (Printf.sprintf "MCP session '%s' not found" session_id)
             | Some s ->
                 let updated = { s with last_seen = now } in
                 let others = List.filter (fun (x : Mcp_server_eio_governance.mcp_session_record) -> x.id <> session_id) sessions in
                 save (updated :: others);
                 Ok (`Assoc [
                   ("status", `String "ok");
                   ("session", Mcp_server_eio_governance.mcp_session_to_json updated);
                 ]))
        | "list" ->
            Ok (`Assoc [
              ("count", `Int (List.length sessions));
              ("sessions", `List (List.map Mcp_server_eio_governance.mcp_session_to_json sessions));
            ])
        | "cleanup" ->
            let cutoff = now -. (7.0 *. 86400.0) in
            let remaining = List.filter (fun (s : Mcp_server_eio_governance.mcp_session_record) -> s.last_seen >= cutoff) sessions in
            let removed = List.length sessions - List.length remaining in
            save remaining;
            Ok (`Assoc [
              ("status", `String "cleaned");
              ("removed", `Int removed);
              ("remaining", `Int (List.length remaining));
            ])
        | "remove" ->
            let session_id = arg_get_string "session_id" "" in
            let remaining = List.filter (fun (s : Mcp_server_eio_governance.mcp_session_record) -> s.id <> session_id) sessions in
            if List.length remaining = List.length sessions then
              Error (Printf.sprintf "MCP session '%s' not found" session_id)
            else begin
              save remaining;
              Ok (`Assoc [
                ("status", `String "removed");
                ("session_id", `String session_id);
              ])
            end
        | other ->
            Error (Printf.sprintf "Unknown action: %s" other)
      in
      (match response with
       | Ok json -> Some (true, Yojson.Safe.pretty_to_string json)
       | Error e -> Some (false, e))

  | "masc_cancellation" ->
      Some (Cancellation.handle_cancellation_tool arguments)

  | "masc_subscription" ->
      Some (Subscriptions.handle_subscription_tool arguments)

  | "masc_progress" ->
      Progress.set_sse_callback (Mcp_server.sse_broadcast state);
      Some (Progress.handle_progress_tool arguments)

  | "masc_interrupt" ->
      let task_id = arg_get_string "task_id" "" in
      let step = arg_get_int "step" 1 in
      let action = arg_get_string "action" "" in
      let message = arg_get_string "message" "" in
      Notify.notify_interrupt ~agent:agent_name ~action;
      Some (safe_exec ["masc-checkpoint"; "--masc-dir"; Room.masc_dir config;
                 "--task-id"; task_id; "--step"; string_of_int step;
                 "--action"; action; "--agent"; agent_name; "--interrupt"; message])

  | "masc_approve" ->
      let task_id = arg_get_string "task_id" "" in
      Some (safe_exec ["masc-checkpoint"; "--masc-dir"; Room.masc_dir config;
                 "--task-id"; task_id; "--approve"])

  | "masc_reject" ->
      let task_id = arg_get_string "task_id" "" in
      let reason = arg_get_string "reason" "" in
      let args = if reason = "" then
        ["masc-checkpoint"; "--masc-dir"; Room.masc_dir config; "--task-id"; task_id; "--reject"]
      else
        ["masc-checkpoint"; "--masc-dir"; Room.masc_dir config; "--task-id"; task_id; "--reject"; "--reason"; reason]
      in
      Some (safe_exec args)

  | "masc_pending_interrupts" ->
      Some (safe_exec ["masc-checkpoint"; "--masc-dir"; Room.masc_dir config; "--pending"])

  | "masc_branch" ->
      let task_id = arg_get_string "task_id" "" in
      let source_step = arg_get_int "source_step" 0 in
      let branch_name = arg_get_string "branch_name" "" in
      if task_id = "" || source_step = 0 || branch_name = "" then
        Some (false, "task_id, source_step, and branch_name are required")
      else
        Some (safe_exec ["masc-checkpoint"; "--masc-dir"; Room.masc_dir config;
                   "--task-id"; task_id; "--branch"; string_of_int source_step;
                   "--branch-name"; branch_name; "--agent"; agent_name])

  | "masc_governance_set" ->
      let level = arg_get_string "level" "production" in
      let defaults = ctx.governance_defaults level in
      let audit_enabled = arg_get_bool "audit_enabled" defaults.audit_enabled in
      let anomaly_detection = arg_get_bool "anomaly_detection" defaults.anomaly_detection in
      let g : Mcp_server_eio_governance.governance_config = {
        level = String.lowercase_ascii level;
        audit_enabled;
        anomaly_detection;
      } in
      ctx.save_governance config g;
      let json = `Assoc [
        ("status", `String "ok");
        ("governance", `Assoc [
          ("level", `String g.level);
          ("audit_enabled", `Bool g.audit_enabled);
          ("anomaly_detection", `Bool g.anomaly_detection);
        ]);
      ] in
      Some (true, Yojson.Safe.pretty_to_string json)

  | "masc_spawn" ->
      let spawn_agent_name = arg_get_string "agent_name" "" in
      let prompt = arg_get_string "prompt" "" in
      let timeout_seconds = arg_get_int "timeout_seconds" 300 in
      let model_name =
        match arguments |> Yojson.Safe.Util.member "model" with
        | `String s ->
            let trimmed = String.trim s in
            if trimmed = "" then None else Some trimmed
        | _ -> None
      in
      let runtime_model =
        match (spawn_agent_name, model_name) with
        | "llama", None -> Error "model is required when agent_name=llama"
        | "llama", Some raw ->
            let spec_name =
              if String.contains raw ':' then raw else "llama:" ^ raw
            in
            Llm.model_spec_of_string spec_name
        | _, Some _ -> Llm.default_execution_model_spec ()
        | _, None -> Llm.default_execution_model_spec ()
      in
      let module U = Yojson.Safe.Util in
      let working_dir = match arguments |> U.member "working_dir" with
        | `String s when s <> "" -> Some s
        | _ -> None
      in
      let execution_scope =
        match arguments |> U.member "execution_scope" with
        | `String s when s <> "" ->
            Some (Team_session_types.execution_scope_of_string s)
        | _ -> None
      in
       (match runtime_model with
       | Error e -> Some (false, e)
       | Ok runtime_model ->
           (match state.Mcp_server.proc_mgr with
            | Some _pm ->
                let result =
                  Spawn_eio.spawn ~sw ~agent_name:spawn_agent_name
                    ~prompt ~timeout_seconds ?working_dir ?execution_scope
                    ~room_config:state.Mcp_server.room_config
                    ~runtime_model ()
                in
                Some (result.Spawn_eio.success, Spawn_eio.result_to_human_string result)
            | None ->
                Some (false, "Process manager not available in this environment")))

  | "masc_memento_mori" ->
      let context_ratio = arg_get_float "context_ratio" 0.0 in
      let full_context = arg_get_string "full_context" "" in
      let summary = arg_get_string "summary" "" in
      let current_task = arg_get_string "current_task" "" in
      let target_agent = arg_get_string "target_agent" "claude" in
      let cell = !(Mcp_server.current_cell) in
      let mitosis_config = Mitosis.default_config in

      let should_prepare_now = Mitosis.should_prepare ~config:mitosis_config ~cell ~context_ratio in
      let should_handoff_now = Mitosis.should_handoff ~config:mitosis_config ~cell ~context_ratio in

      if not should_prepare_now && not should_handoff_now then begin
        let warning = if context_ratio = 0.0 then
          [("warning", `String "context_ratio is 0.0 - did you forget to provide it?")]
        else [] in
        let status, message =
          if context_ratio >= mitosis_config.prepare_threshold then
            "warning", Printf.sprintf "Context at %.0f%% (above prepare threshold %.0f%%). Consider preparing." (context_ratio *. 100.0) (mitosis_config.prepare_threshold *. 100.0)
          else
            "continue", Printf.sprintf "Context healthy (%.0f%%). Continue working." (context_ratio *. 100.0)
        in
        let response = `Assoc ([
          ("status", `String status);
          ("context_ratio", `Float context_ratio);
          ("threshold_prepare", `Float mitosis_config.prepare_threshold);
          ("threshold_handoff", `Float mitosis_config.handoff_threshold);
          ("message", `String message);
        ] @ warning) in
        Some (true, Yojson.Safe.pretty_to_string response)
      end
      else if should_prepare_now && not should_handoff_now then begin
        if full_context = "" then
          Some (false, "full_context required when context_ratio > 50%")
        else begin
          let prepared_cell = Mitosis.prepare_for_division ~config:mitosis_config ~cell ~full_context in
          Mcp_server.current_cell := prepared_cell;
          let response = `Assoc [
            ("status", `String "prepared");
            ("context_ratio", `Float context_ratio);
            ("phase", `String (Mitosis.phase_to_string prepared_cell.phase));
            ("dna_extracted", `Bool (prepared_cell.prepared_dna <> None));
            ("message", `String (Printf.sprintf "Context at %.0f%%. DNA prepared. Handoff at 80%%." (context_ratio *. 100.0)));
          ] in
          Some (true, Yojson.Safe.pretty_to_string response)
        end
      end
      else begin
        if full_context = "" then
          Some (false, "full_context required for handoff")
        else begin
          let last_words = Printf.sprintf
            "LAST WORDS from Generation %d\n\n\
             I am %s, about to divide.\n\
             %s\n\n\
             Tasks completed: %d | Tool calls: %d\n\
             Age: %.1f minutes\n\n\
             My context is full (%.0f%%), but my work continues through Generation %d.\n\
             Carry on, successors."
            cell.Mitosis.generation
            cell.Mitosis.id
            (if summary = "" then "My time has come." else summary)
            cell.Mitosis.task_count
            cell.Mitosis.tool_call_count
            ((Time_compat.now () -. cell.Mitosis.born_at) /. 60.0)
            (context_ratio *. 100.0)
            (cell.Mitosis.generation + 1)
          in
          let _ = Room.broadcast config ~from_agent:agent_name ~content:last_words in

          match state.Mcp_server.proc_mgr with
          | None ->
              Some (false, "Process manager not available for mitosis spawn")
          | Some _pm ->
              let spawn_fn ~prompt =
                let result = Spawn_eio.spawn ~sw ~agent_name:target_agent
                  ~prompt ~timeout_seconds:Env_config.Spawn.timeout_seconds
                  ~room_config:state.Mcp_server.room_config ()
                in
                { Spawn.success = result.Spawn_eio.success;
                  output = result.Spawn_eio.output;
                  exit_code = result.Spawn_eio.exit_code;
                  elapsed_ms = result.Spawn_eio.elapsed_ms;
                  input_tokens = result.Spawn_eio.input_tokens;
                  output_tokens = result.Spawn_eio.output_tokens;
                  cache_creation_tokens = result.Spawn_eio.cache_creation_tokens;
                  cache_read_tokens = result.Spawn_eio.cache_read_tokens;
                  cost_usd = result.Spawn_eio.cost_usd }
              in

              let (spawn_result, new_cell, new_pool, _handoff_dna) =
                Mitosis.execute_mitosis
                  ~config:mitosis_config
                  ~pool:!(Mcp_server.stem_pool)
                  ~parent:cell
                  ~full_context:(Printf.sprintf "Summary: %s\n\nCurrent Task: %s\n\nContext:\n%s"
                      (if summary = "" then "Memento mori - context limit reached" else summary)
                      current_task full_context)
                  ~spawn_fn
              in
              Mcp_server.current_cell := new_cell;
              Mcp_server.stem_pool := new_pool;

              let response = `Assoc [
                ("status", `String "divided");
                ("context_ratio", `Float context_ratio);
                ("previous_generation", `Int cell.generation);
                ("new_generation", `Int new_cell.generation);
                ("successor_spawned", `Bool spawn_result.Spawn.success);
                ("successor_agent", `String target_agent);
                ("successor_output", `String (String.sub spawn_result.Spawn.output 0 (min 500 (String.length spawn_result.Spawn.output))));
                ("message", `String (Printf.sprintf "Context critical (%.0f%%). Cell divided. %s successor spawned." (context_ratio *. 100.0) target_agent));
              ] in
              Some (true, Yojson.Safe.pretty_to_string response)
        end
      end

  | "masc_episode_flush" ->
      Tool_inline_dispatch_episode.handle_episode_flush ~config ~arguments ~state ~sw

  | "masc_episode_list" ->
      Tool_inline_dispatch_episode.handle_episode_list ~config ~arguments


  | "masc_discover_tools" ->
      let query = String.lowercase_ascii (arg_get_string "query" "") in
      let limit = arg_get_int "limit" 20 in
      if query = "" then
        Some (false, "query is required")
      else
        let all_schemas = Config.visible_tool_schemas ~include_hidden:true ~include_deprecated:false () in
        let words = String.split_on_char ' ' query |> List.filter (fun w -> String.length w > 0) in
        let matches =
          all_schemas
          |> List.filter (fun (schema : Types.tool_schema) ->
                 let name_l = String.lowercase_ascii schema.name in
                 let desc_l = String.lowercase_ascii schema.description in
                 let haystack = name_l ^ " " ^ desc_l in
                 words |> List.exists (fun w ->
                   try ignore (Str.search_forward (Str.regexp_string w) haystack 0); true
                   with Not_found -> false))
          |> List.filteri (fun i _ -> i < limit)
        in
        let results = List.map (fun (schema : Types.tool_schema) ->
          `Assoc [
            ("name", `String schema.name);
            ("description", `String schema.description);
            ("category", `String (Mode.category_to_string (Mode.tool_category schema.name)));
            ("tier", `String (Tool_catalog.tier_to_string (Tool_catalog.tool_tier schema.name)));
          ]
        ) matches in
        Some (true, Yojson.Safe.to_string (`Assoc [
          ("query", `String query);
          ("count", `Int (List.length results));
          ("tools", `List results);
          ("hint", `String "These tools are callable via tools/call even if not in the default tools/list.");
        ]))

  | _ -> Tool_inline_dispatch_extra.dispatch ~config ~agent_name ~arguments ~state ~sw ~clock ~name
