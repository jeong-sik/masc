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
  let arg_get_float_opt key =
    Safe_ops.json_float_opt key arguments
  in

  match name with
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
      let path = arg_get_string "path" "" in
      let expanded =
        if String.length path > 0 && path.[0] = '~' then
          let home = match Sys.getenv_opt "HOME" with Some h -> h | None -> "/tmp" in
          Filename.concat home (String.sub path 1 (String.length path - 1))
        else if Filename.is_relative path then
          Filename.concat (Sys.getcwd ()) path
        else
          path
      in
      if not (Sys.file_exists expanded && Sys.is_directory expanded) then
        Some (false, Printf.sprintf "Directory not found: %s" expanded)
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
          let oc = open_out agent_file in
          Common.protect ~module_name:"tool_inline_dispatch" ~finally_label:"finalizer"
            ~finally:(fun () -> close_out_noerr oc)
            (fun () -> output_string oc nickname)
        with e ->
          Log.Misc.error "Failed to write agent file %s: %s" agent_file (Printexc.to_string e))
      end;
      (* Cultural Inheritance: append institution welcome to join response *)
      let institution_welcome = match state.Mcp_server.fs with
        | Some fs ->
            (try Institution_eio.load_and_format_for_welcome ~fs config
             with
             | Eio.Io _ | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> ""
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
            with exn ->
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
            with exn ->
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
       | Some pm ->
           let spawn_fn agent_name prompt =
             Spawn_eio.spawn ~sw ~proc_mgr:pm ~agent_name ~prompt
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
            Llm_client.model_spec_of_string spec_name
        | _, Some _ -> Llm_client.default_execution_model_spec ()
        | _, None -> Llm_client.default_execution_model_spec ()
      in
      let module U = Yojson.Safe.Util in
      let working_dir = match arguments |> U.member "working_dir" with
        | `String s when s <> "" -> Some s
        | _ -> None
      in
       (match runtime_model with
       | Error e -> Some (false, e)
       | Ok runtime_model ->
           (match state.Mcp_server.proc_mgr with
            | Some pm ->
                let result =
                  Spawn_eio.spawn ~sw ~proc_mgr:pm ~agent_name:spawn_agent_name
                    ~prompt ~timeout_seconds ?working_dir
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
        let response = `Assoc ([
          ("status", `String "continue");
          ("context_ratio", `Float context_ratio);
          ("threshold_prepare", `Float mitosis_config.prepare_threshold);
          ("threshold_handoff", `Float mitosis_config.handoff_threshold);
          ("message", `String (Printf.sprintf "Context healthy (%.0f%%). Continue working." (context_ratio *. 100.0)));
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
          | Some pm ->
              let spawn_fn ~prompt =
                let result = Spawn_eio.spawn ~sw ~proc_mgr:pm ~agent_name:target_agent
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
      let limit = arg_get_int "limit" 10 in
      let dry_run = arg_get_bool "dry_run" false in
      let base_path = config.Room_utils.base_path in
      let pending_dir = Filename.concat base_path ".masc/pending_episodes" in

      let pending_files =
        try
          Sys.readdir pending_dir
          |> Array.to_list
          |> List.filter (fun f -> Filename.check_suffix f ".json")
          |> List.sort String.compare
          |> (fun l -> if List.length l > limit then List.filteri (fun i _ -> i < limit) l else l)
        with Sys_error _ -> []
      in

      if dry_run then begin
        let response = `Assoc [
          ("dry_run", `Bool true);
          ("pending", `Int (List.length pending_files));
          ("would_flush", `List (List.map (fun f -> `String f) pending_files));
        ] in
        Some (true, Yojson.Safe.pretty_to_string response)
      end else begin
        let flushed = ref 0 in
        let failed = ref 0 in

        let parse_outcome s = match s with
          | "success" -> `Success
          | "failure" -> `Failure
          | _ -> `Partial
        in

        let parse_string_list = function
          | `List l -> List.filter_map (function `String s -> Some s | _ -> None) l
          | _ -> []
        in

        let parse_context = function
          | `Assoc l -> List.filter_map (fun (k, v) ->
              match v with `String s -> Some (k, s) | _ -> None) l
          | _ -> []
        in

        List.iter (fun file ->
          let file_path = Filename.concat pending_dir file in
          try
            let ic = open_in file_path in
            let content =
              Common.protect ~module_name:"tool_inline_dispatch" ~finally_label:"finalizer"
                ~finally:(fun () -> close_in_noerr ic)
                (fun () ->
                  let buf = Buffer.create 4096 in
                  (try
                    while true do
                      Buffer.add_channel buf ic 1024
                    done
                  with End_of_file -> ());
                  Buffer.contents buf)
            in
            let json = Yojson.Safe.from_string content in
            let module U = Yojson.Safe.Util in
            let ep_id = match Json_util.get_string json "ep_id" with Some v -> v | None -> raise Not_found in

            let episode : Jiphyeon.Archive.episode = {
              ep_id;
              session_id = json |> U.member "session_id" |> U.to_string;
              agent_name = json |> U.member "agent_name" |> U.to_string;
              generation = json |> U.member "generation" |> U.to_int;
              parent_episode = Json_util.get_string json "parent_episode";
              event_type = json |> U.member "event_type" |> U.to_string;
              summary = json |> U.member "summary" |> U.to_string;
              dna = Json_util.get_string json "dna";
              outcome = json |> U.member "outcome" |> U.to_string |> parse_outcome;
              learnings = json |> U.member "learnings" |> parse_string_list;
              context = json |> U.member "context" |> parse_context;
              timestamp = json |> U.member "timestamp" |> U.to_string;
            } in

            (match state.Mcp_server.env with
             | Some env ->
               (match Jiphyeon.Archive.save_episode ~sw ~env episode with
                | Ok () ->
                  Printf.printf "[EPISODE/SAVED] Episode %s saved to PostgreSQL + Neo4j\n%!" ep_id
                | Error e ->
                  Log.Misc.error "DB save failed (file kept): %s" e)
             | None ->
               Log.Misc.warn "No env available, skipping DB save"
            );

            let processed_dir = Filename.concat base_path ".masc/processed_episodes" in
            (try Unix.mkdir processed_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
            let new_path = Filename.concat processed_dir file in
            Sys.rename file_path new_path;
            Printf.printf "[EPISODE/FLUSH] Processed episode %s -> %s\n%!" ep_id new_path;
            incr flushed
          with exn ->
            Log.Misc.error "Failed to flush %s: %s" file (Printexc.to_string exn);
            incr failed
        ) pending_files;

        let remaining =
          try Array.length (Sys.readdir pending_dir) with Sys_error _ -> 0
        in
        let response = `Assoc [
          ("flushed", `Int !flushed);
          ("failed", `Int !failed);
          ("remaining", `Int remaining);
          ("message", `String (Printf.sprintf "Flushed %d episodes (%d failed, %d remaining)" !flushed !failed remaining));
        ] in
        Some (true, Yojson.Safe.pretty_to_string response)
      end

  | "masc_episode_list" ->
      let agent_filter = arg_get_string_opt "agent_name" in
      let gen_filter = match arguments with
        | `Assoc fields -> (match List.assoc_opt "generation" fields with
            | Some (`Int n) -> Some n
            | _ -> None)
        | _ -> None
      in
      let limit = arg_get_int "limit" 20 in
      let base_path = config.Room_utils.base_path in

      let processed_dir = Filename.concat base_path ".masc/processed_episodes" in
      let module U = Yojson.Safe.Util in
      let episodes =
        try
          Sys.readdir processed_dir
          |> Array.to_list
          |> List.filter (fun f -> Filename.check_suffix f ".json")
          |> List.sort (fun a b -> String.compare b a)
          |> (fun l -> if List.length l > limit then List.filteri (fun i _ -> i < limit) l else l)
          |> List.filter_map (fun file ->
              try
                let path = Filename.concat processed_dir file in
                let ic = open_in path in
                let content =
                  Common.protect ~module_name:"tool_inline_dispatch" ~finally_label:"finalizer"
                    ~finally:(fun () -> close_in_noerr ic)
                    (fun () ->
                      let buf = Buffer.create 4096 in
                      (try while true do Buffer.add_channel buf ic 1024 done with End_of_file -> ());
                      Buffer.contents buf)
                in
                let json = Yojson.Safe.from_string content in
                let ep_agent = U.(json |> member "agent_name" |> to_string) in
                let ep_gen = U.(json |> member "generation" |> to_int) in
                let agent_ok = match agent_filter with None -> true | Some a -> ep_agent = a in
                let gen_ok = match gen_filter with None -> true | Some g -> ep_gen = g in
                if agent_ok && gen_ok then Some json else None
              with
              | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None
            )
        with Sys_error _ -> []
      in

      let response = `Assoc [
        ("count", `Int (List.length episodes));
        ("episodes", `List episodes);
      ] in
      Some (true, Yojson.Safe.pretty_to_string response)

  | "masc_self_introspect" ->
      let cell = !(Mcp_server.current_cell) in
      let generation = cell.Mitosis.generation in
      let tool_calls = cell.Mitosis.tool_call_count in
      let task_count = cell.Mitosis.task_count in

      let estimated_ratio = Float.min 1.0 (Float.of_int tool_calls /. Mitosis.Defaults.tool_calls_per_full_context) in
      let status =
        if estimated_ratio >= Mitosis.default_config.handoff_threshold then "critical"
        else if estimated_ratio >= Mitosis.default_config.prepare_threshold then "warning"
        else "healthy" in

      let remaining_ratio = 1.0 -. estimated_ratio in
      let estimated_remaining_tools = int_of_float (remaining_ratio *. Mitosis.Defaults.tool_calls_per_full_context) in

      let now = Time_compat.now () in
      let age_seconds = now -. cell.Mitosis.born_at in
      let age_human =
        if age_seconds < 60.0 then Printf.sprintf "%.0f seconds" age_seconds
        else if age_seconds < 3600.0 then Printf.sprintf "%.1f minutes" (age_seconds /. 60.0)
        else Printf.sprintf "%.1f hours" (age_seconds /. 3600.0)
      in

      let all_statuses = Mitosis.get_all_statuses ~room_config:config in
      let siblings = List.filter (fun (_, _, _) -> true) all_statuses in

      let cell_id = cell.Mitosis.id in
      let episode_count, recent_episode =
        match state.Mcp_server.env with
        | Some env ->
          (try
            (match Jiphyeon.Archive.get_agent_episodes ~sw ~env cell_id 5 with
             | Ok episodes -> (List.length episodes, List.nth_opt episodes 0)
             | Error _ -> (0, None))
          with exn ->
            Log.Inline.warn "%s: %s" __FUNCTION__ (Printexc.to_string exn);
            (0, None))
        | None -> (0, None)
      in

      let mortality_msg =
        if estimated_ratio >= 0.8 then
          "Approaching end of lifecycle. Consider preparing DNA for successor."
        else if estimated_ratio >= 0.5 then
          "Mid-lifecycle. Context accumulating normally."
        else
          "Early lifecycle. Plenty of context remaining."
      in

      let response = `Assoc [
        ("generation", `Int generation);
        ("cell_id", `String cell_id);
        ("context_used", `Float estimated_ratio);
        ("status", `String status);
        ("tool_calls", `Int tool_calls);
        ("task_count", `Int task_count);
        ("phase", `String (Mitosis.phase_to_string cell.Mitosis.phase));
        ("born_at", `Float cell.Mitosis.born_at);
        ("age_seconds", `Float age_seconds);
        ("age_human", `String age_human);
        ("estimated_remaining_tools", `Int estimated_remaining_tools);
        ("siblings_in_room", `Int (List.length siblings));
        ("parent_dna", match cell.Mitosis.context_dna with Some _ -> `Bool true | None -> `Bool false);
        ("episode_count", `Int episode_count);
        ("recent_episode", match recent_episode with
          | Some (ep_id, event_type, _, summary) ->
            `Assoc [("ep_id", `String ep_id); ("event_type", `String event_type); ("summary", `String summary)]
          | None -> `Null);
        ("mortality_awareness", `String mortality_msg);
        ("message", `String (Printf.sprintf "Generation %d | Age %s | Context %.0f%% (%s) | ~%d tool calls remaining | %d memories"
          generation age_human (estimated_ratio *. 100.0) status estimated_remaining_tools episode_count));
      ] in
      Some (true, Yojson.Safe.pretty_to_string response)

  | "masc_recall_search" ->
      let module U = Yojson.Safe.Util in
      let query = match Json_util.get_string arguments "query" with Some v -> v | None -> raise Not_found in
      let limit = arguments |> U.member "limit" |> U.to_int_option |> Option.value ~default:5 in

      (match state.Mcp_server.env with
       | None ->
           Some (true, Yojson.Safe.pretty_to_string (`Assoc [
             ("success", `Bool false);
             ("error", `String "Database environment not available");
             ("suggestion", `String "Ensure runtime environment is initialized");
           ]))
       | Some env ->
           let recall_config = Auto_recall.make_config
             ~enabled:true
             ~sources:[Auto_recall.Recent_broadcasts; Auto_recall.Masc_cache; Auto_recall.File_context]
             ~max_tokens:4000
             ~max_broadcasts:limit
             ()
           in
           let result = Auto_recall.fetch_context_eio ~sw ~env ~clock config ~config:recall_config ~query () in
           let response = `Assoc [
             ("success", `Bool true);
             ("query", `String query);
             ("items", `List (List.map (fun (item : Auto_recall.recall_item) ->
               `Assoc [
                 ("source", `String (match item.source with
                   | Auto_recall.Masc_cache -> "cache"
                   | Auto_recall.Recent_broadcasts -> "broadcast"
                   | Auto_recall.File_context -> "file"));
                 ("content", `String item.content);
                 ("relevance", `Float item.relevance);
                 ("metadata", item.metadata);
               ]
             ) result.items));
             ("total_tokens", `Int result.total_tokens);
             ("truncated", `Bool result.truncated);
             ("message", `String (Printf.sprintf "Found %d relevant items for query: %s"
               (List.length result.items) query));
           ] in
           let agent_name = Safe_ops.json_string ~default:"unknown" "agent_name" arguments in
           Audit_log.log_action config ~agent_id:agent_name ~action:Audit_log.SearchRefinement
             ~room_id:(Filename.basename config.base_path)
             ~details:(`Assoc [("query", `String query); ("results", `Int (List.length result.items))])
             ~outcome:Audit_log.Success ();
           Some (true, Yojson.Safe.pretty_to_string response))

  | "masc_board_post" ->
      let (success, message) as result = Tool_board.handle_tool name arguments in
      if success then begin
        let author = Safe_ops.json_string ~default:"anonymous" "author" arguments in
        let content = Safe_ops.json_string ~default:"" "content" arguments in
        let notification = `Assoc [
          ("type", `String "masc/board_post");
          ("author", `String author);
          ("content", `String (String.sub content 0 (min 200 (String.length content))));
          ("post_id", `String (
            try
              let idx = String.index message '{' in
              let json = Yojson.Safe.from_string
                (String.sub message idx (String.length message - idx)) in
              Yojson.Safe.Util.(json |> member "id" |> to_string)
            with
            | Not_found | Invalid_argument _
            | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> "unknown"
          ));
          ("timestamp", `String (Types.now_iso ()));
        ] in
        Mcp_server.sse_broadcast state notification;
        A2a_tools.notify_event
          ~event_type:A2a_tools.Broadcast
          ~agent:author
          ~data:(`Assoc [
            ("event", `String "board_post");
            ("content_preview", `String (String.sub content 0 (min 100 (String.length content))));
          ])
      end;
      Some result

  | "masc_board_comment" ->
      let (success, _message) as result = Tool_board.handle_tool name arguments in
      if success then begin
        let author = Safe_ops.json_string ~default:"anonymous" "author" arguments in
        let content = Safe_ops.json_string ~default:"" "content" arguments in
        let post_id = Safe_ops.json_string ~default:"unknown" "post_id" arguments in
        let notification = `Assoc [
          ("type", `String "board_comment");
          ("author", `String author);
          ("post_id", `String post_id);
          ("content", `String (String.sub content 0 (min 200 (String.length content))));
          ("timestamp", `String (Types.now_iso ()));
        ] in
        Mcp_server.sse_broadcast state notification;
        A2a_tools.notify_event
          ~event_type:A2a_tools.Broadcast
          ~agent:author
          ~data:(`Assoc [
            ("event", `String "board_comment");
            ("post_id", `String post_id);
            ("content_preview", `String (String.sub content 0 (min 100 (String.length content))));
          ])
      end;
      Some result

  | "masc_board_list" | "masc_board_get"
  | "masc_board_vote" | "masc_board_stats"
  | "masc_board_search" | "masc_board_comment_vote" | "masc_board_profile"
  | "masc_board_hearths" | "masc_board_migrate" ->
      Some (Tool_board.handle_tool name arguments)

  | "lodge_heartbeat" | "lodge_classify" | "lodge_react" | "lodge_cycle"
  | "lodge_discussion" | "lodge_orchestrate" | "lodge_auto_chain"
  | "lodge_evolve" | "lodge_spawn" | "lodge_agents"
  | "lodge_agent_patrol" | "lodge_autonomous_loop"
  | "lodge_propose_project" | "lodge_join_project" | "lodge_share_code"
  | "lodge_research" | "lodge_profile"
  | "lodge_search" | "lodge_comment_like" | "lodge_progress" ->
      (match state.Mcp_server.net with
       | Some net -> Some (Tool_lodge.handle_tool ~net name arguments)
       | None -> Some (false, "lodge tools require net (server_state.net is None)"))

  | "masc_convo_start" ->
      let topic = arg_get_string "topic" "" in
      let initiator = arg_get_string "initiator" agent_name in
      let initial_content = arg_get_string "initial_content" "" in
      let max_turns = arg_get_int "max_turns" 50 in
      let source_post_id = arg_get_string_opt "post_id" in
      let mentions = arg_get_string_list "mentions" in
      let current_room = Room.read_current_room config |> Option.value ~default:"default" in
      if topic = "" then Some (false, "topic required")
      else begin
        let convo_config : Council.Conversation.config = {
          base_path = config.base_path;
          room = current_room;
        } in
        match Council.Conversation.start ~config:convo_config ~topic ~initiator
                ~max_turns ~initial_content ~mentions ?source_post_id () with
        | Ok thread ->
            let link_warning = match source_post_id with
              | Some pid ->
                  (match Board_dispatch.set_thread_id
                    ~post_id:pid ~thread_id:thread.Council.Conversation.id with
                   | Ok () -> ""
                   | Error e -> Printf.sprintf "\nBoard link failed: %s" (Board.show_board_error e))
              | None -> ""
            in
            let json = Council.Conversation.thread_to_yojson thread in
            Some (true, Printf.sprintf "Thread started: %s%s\n%s"
              thread.Council.Conversation.id link_warning (Yojson.Safe.pretty_to_string json))
        | Error e -> Some (false, e)
      end

  | "masc_convo_reply" ->
      let thread_id = arg_get_string "thread_id" "" in
      let speaker = arg_get_string "speaker" agent_name in
      let content = arg_get_string "content" "" in
      let confidence = arg_get_float_opt "confidence" in
      let reply_to = arg_get_string_opt "reply_to" in
      let mentions = arg_get_string_list "mentions" in
      let current_room = Room.read_current_room config |> Option.value ~default:"default" in
      if thread_id = "" || content = "" then
        Some (false, "thread_id and content required")
      else begin
        let convo_config : Council.Conversation.config = {
          base_path = config.base_path;
          room = current_room;
        } in
        match Council.Conversation.get ~config:convo_config ~thread_id with
        | None -> Some (false, Printf.sprintf "Thread not found: %s" thread_id)
        | Some thread ->
            let loop_check = Council.Loop_guard.check
              ~thread ~speaker ~content
              ~config:Council.Loop_guard.default_config
            in
            match Council.Loop_guard.to_error_message loop_check with
            | Some err -> Some (false, Printf.sprintf "Loop detected: %s" err)
            | None ->
                match Council.Conversation.reply ~config:convo_config ~thread_id
                        ~speaker ~content ?confidence ?reply_to ~mentions () with
                | Ok updated ->
                    let json = Council.Conversation.thread_to_yojson updated in
                    Some (true, Printf.sprintf "Reply added (turn %d)\n%s"
                      updated.Council.Conversation.current_turn
                      (Yojson.Safe.pretty_to_string json))
                | Error e -> Some (false, e)
      end

  | "masc_convo_conclude" ->
      let thread_id = arg_get_string "thread_id" "" in
      let concluder = arg_get_string "concluder" agent_name in
      let conclusion = arg_get_string "conclusion" "" in
      let current_room = Room.read_current_room config |> Option.value ~default:"default" in
      if thread_id = "" || conclusion = "" then
        Some (false, "thread_id and conclusion required")
      else begin
        let convo_config : Council.Conversation.config = {
          base_path = config.base_path;
          room = current_room;
        } in
        match Council.Conversation.conclude ~config:convo_config ~thread_id
                ~concluder ~conclusion () with
        | Ok thread ->
            let json = Council.Conversation.thread_to_yojson thread in
            Some (true, Printf.sprintf "Thread concluded: %s\n%s"
              thread.Council.Conversation.id (Yojson.Safe.pretty_to_string json))
        | Error e -> Some (false, e)
      end

  | "masc_convo_get" ->
      let thread_id = arg_get_string "thread_id" "" in
      let current_room = Room.read_current_room config |> Option.value ~default:"default" in
      if thread_id = "" then Some (false, "thread_id required")
      else begin
        let convo_config : Council.Conversation.config = {
          base_path = config.base_path;
          room = current_room;
        } in
        match Council.Conversation.get ~config:convo_config ~thread_id with
        | Some thread ->
            let json = Council.Conversation.thread_to_yojson thread in
            Some (true, Yojson.Safe.pretty_to_string json)
        | None -> Some (false, Printf.sprintf "Thread not found: %s" thread_id)
      end

  | "masc_convo_list" ->
      let current_room = Room.read_current_room config |> Option.value ~default:"default" in
      let convo_config : Council.Conversation.config = {
        base_path = config.base_path;
        room = current_room;
      } in
      let threads = Council.Conversation.list_active ~config:convo_config in
      let json = `List (List.map (fun th ->
        `Assoc [
          ("id", `String th.Council.Conversation.id);
          ("topic", `String th.Council.Conversation.topic);
          ("status", `String (Council.Conversation.thread_status_to_string th.Council.Conversation.status));
          ("turns", `Int th.Council.Conversation.current_turn);
          ("participants", `List (List.map (fun p -> `String p) th.Council.Conversation.participants));
        ]
      ) threads) in
      Some (true, Printf.sprintf "Active threads: %d\n%s"
        (List.length threads) (Yojson.Safe.pretty_to_string json))

  | _ -> None
