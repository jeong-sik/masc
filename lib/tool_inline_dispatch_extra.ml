[@@@warning "-32-33-69"]

(** Tool_inline_dispatch_extra — additional inline tool dispatch arms
    (self-introspect, recall, board, conversation).
    Returns [Some (success, message)] if handled, [None] otherwise. *)

open Types [@@warning "-33"]

let dispatch ~config ~agent_name ~arguments ~(state : Mcp_server.server_state) ~sw ~clock ~name =
  ignore (config, agent_name, state, sw, clock);
  let arg_get_string key default =
    Safe_ops.json_string ~default key arguments in
  let arg_get_int key default =
    Safe_ops.json_int ~default key arguments in
  let arg_get_float key default =
    Safe_ops.json_float ~default key arguments in
  let arg_get_bool key default =
    Safe_ops.json_bool ~default key arguments in
  let arg_get_string_list key =
    Safe_ops.json_string_list key arguments in
  let arg_get_string_opt key =
    match Safe_ops.json_string_opt key arguments with
    | Some "" -> None
    | other -> other in
  let arg_get_float_opt key =
    Safe_ops.json_float_opt key arguments in
  ignore (arg_get_string, arg_get_int, arg_get_float, arg_get_bool, arg_get_string_list, arg_get_string_opt, arg_get_float_opt);
  match (name : string) with
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
      else if not (try Room.is_agent_joined config ~agent_name:speaker with Sys_error _ | Not_found -> false) then
        Some (false, Printf.sprintf "Speaker '%s' is not a member of this room" speaker)
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
