(** Tool_inline_dispatch — thin dispatch router for inline tool handlers.

    Delegates to sub-modules:
    - Tool_inline_dispatch_room: masc_start, masc_lock, masc_unlock,
      masc_set_room, masc_join, masc_leave
    - Tool_inline_dispatch_comm: masc_bounded_run, masc_broadcast,
      masc_messages, masc_listen, masc_who
    - Tool_inline_dispatch_episode: masc_episode_flush, masc_episode_list
    - Tool_inline_dispatch_extra: remaining tools (introspect, recall,
      board, conversation, keeper, etc.)

    Keeps inline: verify, mcp_session, cancellation, subscription,
    progress, interrupt, approve, reject, pending_interrupts, branch,
    governance_set, spawn, memento_mori, discover_tools.
*)

(** Re-export shared types so callers can use
    [Tool_inline_dispatch.context] and [Tool_inline_dispatch.result]
    without knowing about the types sub-module. *)
type result = Tool_inline_dispatch_types.result
type context = Tool_inline_dispatch_types.context = {
  config : Room.config;
  agent_name : string;
  registry : Session.registry;
  state : Mcp_server.server_state;
  sw : Eio.Switch.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t;
  arguments : Yojson.Safe.t;
  mcp_session_id : string option;
  write_mcp_session_agent : string -> unit;
  wait_for_message :
    Session.registry ->
    agent_name:string ->
    timeout:float ->
    Yojson.Safe.t option;
  governance_defaults : string -> Mcp_server_eio_governance.governance_config;
  save_governance :
    Room.config -> Mcp_server_eio_governance.governance_config -> unit;
  load_mcp_sessions : Room.config -> Mcp_server_eio_governance.mcp_session_record list;
  save_mcp_sessions :
    Room.config -> Mcp_server_eio_governance.mcp_session_record list -> unit;
}

let safe_exec = Tool_inline_dispatch_types.safe_exec

(** Dispatch a tool call.
    Returns [Some (success, message)] if the tool name is handled,
    [None] if the tool name is not recognized by this module. *)
let dispatch (ctx : context) ~(name : string) : result option =
  let config = ctx.config in
  let agent_name = ctx.agent_name in
  let state = ctx.state in
  let sw = ctx.sw in
  let clock = ctx.clock in
  let arguments = ctx.arguments in

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
  let _arg_get_string_list key =
    Safe_ops.json_string_list key arguments
  in
  let arg_get_string_opt key =
    match Safe_ops.json_string_opt key arguments with
    | Some "" -> None
    | other -> other
  in
  let _arg_get_string_required key =
    Tool_args.get_string_required arguments key
  in
  let _arg_get_int_opt _key = () in  (* unused but kept for symmetry *)
  let _arg_get_float_opt key =
    Safe_ops.json_float_opt key arguments
  in

  match name with
  (* ── Room lifecycle (delegated) ─────────────────────────────── *)
  | "masc_start" -> Tool_inline_dispatch_room.handle_start ctx
  | "masc_lock" -> Tool_inline_dispatch_room.handle_lock ctx
  | "masc_unlock" -> Tool_inline_dispatch_room.handle_unlock ctx
  | "masc_set_room" -> Tool_inline_dispatch_room.handle_set_room ctx
  | "masc_join" -> Tool_inline_dispatch_room.handle_join ctx
  | "masc_leave" -> Tool_inline_dispatch_room.handle_leave ctx

  (* ── Communication (delegated) ──────────────────────────────── *)
  | "masc_bounded_run" -> Tool_inline_dispatch_comm.handle_bounded_run ctx
  | "masc_broadcast" -> Tool_inline_dispatch_comm.handle_broadcast ctx
  | "masc_messages" -> Tool_inline_dispatch_comm.handle_messages ctx
  | "masc_listen" -> Tool_inline_dispatch_comm.handle_listen ctx
  | "masc_who" -> Tool_inline_dispatch_comm.handle_who ctx
  | ("masc_cache_set" | "masc_cache_get" | "masc_cache_delete"
    | "masc_cache_list" | "masc_cache_clear" | "masc_cache_stats") as tool_name ->
      Tool_cache.dispatch { Tool_cache.config = config } ~name:tool_name ~args:arguments
  | ("masc_hat_wear" | "masc_hat_status") as tool_name ->
      Tool_hat.dispatch
        { Tool_hat.config = config; agent_name }
        ~name:tool_name ~args:arguments

  (* ── Verification ───────────────────────────────────────────── *)
  | "masc_verify_request" | "masc_verify_submit" | "masc_verify_status"
  | "masc_verify_pending" | "masc_verify_auto" ->
      Some (Tool_verification.dispatch config agent_name name arguments)

  (* ── MCP Session ────────────────────────────────────────────── *)
  | "masc_mcp_session" ->
      let action = arg_get_string "action" "" in
      if action = "" then Some (false, "action is required (create|get|list|delete)")
      else
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

  (* ── Infrastructure tools ───────────────────────────────────── *)
  | "masc_cancellation" ->
      Some (Cancellation.handle_cancellation_tool arguments)

  | "masc_subscription" ->
      Some (Subscriptions.handle_subscription_tool arguments)

  | "masc_progress" ->
      Progress.set_sse_callback (Mcp_server.sse_broadcast state);
      Some (Progress.handle_progress_tool arguments)

  | "masc_interrupt" ->
      let task_id = arg_get_string "task_id" "" in
      let action = arg_get_string "action" "" in
      if task_id = "" || action = "" then
        Some (false, "task_id and action are required")
      else
      let step = arg_get_int "step" 1 in
      let message = arg_get_string "message" "" in
      Notify.notify_interrupt ~agent:agent_name ~action;
      Some (safe_exec ["masc-checkpoint"; "--masc-dir"; Room.masc_dir config;
                 "--task-id"; task_id; "--step"; string_of_int step;
                 "--action"; action; "--agent"; agent_name; "--interrupt"; message])

  | "masc_approve" ->
      let task_id = arg_get_string "task_id" "" in
      if task_id = "" then Some (false, "task_id is required")
      else
      Some (safe_exec ["masc-checkpoint"; "--masc-dir"; Room.masc_dir config;
                 "--task-id"; task_id; "--approve"])

  | "masc_reject" ->
      let task_id = arg_get_string "task_id" "" in
      if task_id = "" then Some (false, "task_id is required")
      else
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
      if prompt = "" then Some (false, "prompt is required")
      else
      let timeout_seconds = arg_get_int "timeout_seconds" 300 in
      let model_name =
        match arguments |> Yojson.Safe.Util.member "model" with
        | `String s ->
            let trimmed = String.trim s in
            if trimmed = "" then None else Some trimmed
        | _ -> None
      in
      let runtime_model_valid =
        match (spawn_agent_name, model_name) with
        | "llama", None -> Error "model is required when agent_name=llama"
        | "llama", Some raw ->
            let spec_name =
              if String.contains raw ':' then raw else "llama:" ^ raw
            in
            (* Validate the label parses without retaining model_spec *)
            (match Llm_provider.Cascade_config.parse_model_string spec_name with Some _ -> Ok () | None -> Error "invalid model spec")
        | _ ->
            (match Provider_adapter.preferred_execution_model_labels () with _ :: _ -> Ok () | [] -> Error "no execution model")
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
       (match runtime_model_valid with
       | Error e -> Some (false, e)
       | Ok () ->
           ignore (sw, state, execution_scope);
           let result =
             Spawn.spawn ~agent_name:spawn_agent_name
               ~prompt ~timeout_seconds ?working_dir ()
           in
           Some (result.Spawn.success, Spawn.result_to_string result))

  | "masc_memento_mori" ->
      let context_ratio = arg_get_float "context_ratio" 0.0 in
      let full_context = arg_get_string "full_context" "" in
      let summary = arg_get_string "summary" "" in
      let current_task = arg_get_string "current_task" "" in
      let target_agent = arg_get_string "target_agent" "claude" in
      let cell = Mcp_server.get_cell () in
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
          Mcp_server.set_cell prepared_cell;
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

          ignore (state, sw);
          let spawn_fn ~prompt =
            Spawn.spawn ~agent_name:target_agent
              ~prompt ~timeout_seconds:Env_config.Spawn.timeout_seconds ()
          in

          let pool = Mcp_server.get_pool () in
          let (spawn_result, new_cell, new_pool, _handoff_dna) =
            Mitosis.execute_mitosis
              ~config:mitosis_config
              ~pool
              ~parent:cell
              ~full_context:(Printf.sprintf "Summary: %s\n\nCurrent Task: %s\n\nContext:\n%s"
                  (if summary = "" then "Memento mori - context limit reached" else summary)
                  current_task full_context)
              ~spawn_fn
          in
              Mcp_server.set_cell new_cell;
              Mcp_server.set_pool new_pool;

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

  (* ── Episodes (delegated) ───────────────────────────────────── *)
  | "masc_episode_flush" ->
      Tool_inline_dispatch_episode.handle_episode_flush ~config ~arguments ~state ~sw

  | "masc_episode_list" ->
      Tool_inline_dispatch_episode.handle_episode_list ~config ~arguments

  (* ── Tool discovery ─────────────────────────────────────────── *)
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
                   Re.execp (Re.str w |> Re.compile) haystack))
          |> List.filteri (fun i _ -> i < limit)
        in
        let results = List.map (fun (schema : Types.tool_schema) ->
          `Assoc [
            ("name", `String schema.name);
            ("description", `String schema.description);
            ("tier", `String (Tool_catalog.tier_to_string (Tool_catalog.tool_tier schema.name)));
          ]
        ) matches in
        Some (true, Yojson.Safe.to_string (`Assoc [
          ("query", `String query);
          ("count", `Int (List.length results));
          ("tools", `List results);
          ("hint", `String "These tools are callable via tools/call even if not in the default tools/list.");
        ]))

  (* ── Fallthrough to extra dispatch ──────────────────────────── *)
  | _ -> Tool_inline_dispatch_extra.dispatch ~config ~agent_name ~arguments ~state ~sw ~clock ~name
