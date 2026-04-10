
(** Tool_inline_dispatch_extra — additional inline tool dispatch arms
    (recall, board, conversation).
    Returns [Some (success, message)] if handled, [None] otherwise. *)

let emit_activity config ~kind ~actor ?subject ?(tags = []) ~payload () =
  try
    ignore
      (Activity_graph.emit config
         ~actor:(Activity_graph.entity ~kind:"agent" actor)
         ?subject ~kind ~payload ~tags ())
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Log.Misc.warn "activity emit failed (%s): %s" kind
        (Printexc.to_string exn)

let extract_board_post_id (message : string) =
  try
    let idx = String.index message '{' in
    let json =
      Yojson.Safe.from_string
        (String.sub message idx (String.length message - idx))
    in
    match Yojson.Safe.Util.member "id" json with
    | `String id when String.trim id <> "" -> Some id
    | _ -> None
  with
  | Not_found | Invalid_argument _
  | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None

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
  | "masc_recall_search" ->
      let module U = Yojson.Safe.Util in
      let query = match Json_util.get_string arguments "query" with Some v -> v | None -> raise Not_found in
      let limit = arguments |> U.member "limit" |> U.to_int_option |> Option.value ~default:5 in
      (* PR#814 Gap 3: format=grep returns compact grep-like output for LLM parsing *)
      let format = arguments |> U.member "format" |> U.to_string_option
        |> Option.value ~default:"json" in

      (match state.Mcp_server.env with
       | None ->
           Some (true, Yojson.Safe.to_string (`Assoc [
             ("success", `Bool false);
             ("error", `String "Database environment not available");
             ("suggestion", `String "Ensure runtime environment is initialized");
           ]))
       | Some env ->
           let recall_config = Auto_recall.make_config
             ~enabled:true
             ~sources:[Auto_recall.Recent_broadcasts; Auto_recall.Masc_cache; Auto_recall.File_context]
             ~max_tokens:4000 (* recall context token cap *)
             ~max_broadcasts:limit
             ()
           in
           let result = Auto_recall.fetch_context_eio ~sw ~env ~clock config ~config:recall_config ~query () in
           let grep_projection =
             Auto_recall.format_for_injection result
           in
           let agent_name = Safe_ops.json_string ~default:"unknown" "agent_name" arguments in
           Audit_log.log_action config ~agent_id:agent_name ~action:Audit_log.SearchRefinement
             ~room_id:(Filename.basename config.base_path)
             ~details:(`Assoc [("query", `String query); ("results", `Int (List.length result.items))])
             ~outcome:Audit_log.Success ();
           if format = "grep" then
             (* Compact grep-like format — LLM in-distribution output *)
             Some (true, if grep_projection = "" then "No results" else grep_projection)
           else
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
               ("grep_projection", `String grep_projection);
               ("message", `String (Printf.sprintf "Found %d relevant items for query: %s"
                 (List.length result.items) query));
             ] in
             Some (true, Yojson.Safe.to_string response))

  | "masc_board_post" ->
      let (success, message) as result = Tool_board.handle_tool name arguments in
      if success then begin
        let author = Safe_ops.json_string ~default:"anonymous" "author" arguments in
        let content = Safe_ops.json_string ~default:"" "content" arguments in
        let post_id = extract_board_post_id message in
        (* Record board activity as a fitness metric so board-active agents
           appear in agent_fitness queries (Issue #1861). *)
        (try
           let now = Time_compat.now () in
           let metric : Metrics_store_eio.task_metric = {
             id = Metrics_store_eio.generate_id ();
             agent_id = author;
             task_id = "board_post";
             started_at = now;
             completed_at = Some now;
             success = true;
             error_message = None;
             collaborators = [];
             handoff_from = None;
             handoff_to = None;
           } in
           Metrics_store_eio.record config metric
         with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
           Log.Misc.error "board_post fitness record failed: %s"
             (Printexc.to_string exn));
        let notification = `Assoc [
          ("type", `String "masc/board_post");
          ("author", `String author);
          ("content", `String (String.sub content 0 (min 200 (String.length content))));
          ("post_id", `String (Option.value post_id ~default:"unknown"));
          ("timestamp", `String (Types.now_iso ()));
        ] in
        Mcp_server.sse_broadcast state notification;
        A2a_tools.notify_event
          ~event_type:A2a_tools.Broadcast
          ~agent:author
          ~data:(`Assoc [
            ("event", `String "board_post");
            ("content_preview", `String (String.sub content 0 (min 100 (String.length content))));
          ]);
        emit_activity config ~kind:"board.posted" ~actor:author
          ?subject:
            (Option.map (Activity_graph.entity ~kind:"post") post_id)
          ~tags:[ "board"; "board.posted" ]
          ~payload:
            (`Assoc
              [
                ("content", `String content);
                ( "post_id",
                  match post_id with
                  | Some id -> `String id
                  | None -> `Null );
              ])
          ();
        (* Mention processing — mirror masc_broadcast pattern *)
        let mention = Mention.extract content in
        (match mention with
         | Some target ->
             Notify.notify_mention ~from_agent:author
               ~target_agent:target ~message:content ();
             ignore (Auto_responder.maybe_respond ~sw
               ~base_path:config.base_path ~from_agent:author
               ~content ~mention)
         | None -> ())
      end;
      Some result

  | "masc_board_comment" ->
      let (success, _message) as result = Tool_board.handle_tool name arguments in
      if success then begin
        let author = Safe_ops.json_string ~default:"anonymous" "author" arguments in
        let content = Safe_ops.json_string ~default:"" "content" arguments in
        let post_id = Safe_ops.json_string ~default:"unknown" "post_id" arguments in
        (* Record board comment as a fitness metric (Issue #1861). *)
        (try
           let now = Time_compat.now () in
           let metric : Metrics_store_eio.task_metric = {
             id = Metrics_store_eio.generate_id ();
             agent_id = author;
             task_id = "board_comment:" ^ post_id;
             started_at = now;
             completed_at = Some now;
             success = true;
             error_message = None;
             collaborators = [];
             handoff_from = None;
             handoff_to = None;
           } in
           Metrics_store_eio.record config metric
         with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
           Log.Misc.error "board_comment fitness record failed: %s"
             (Printexc.to_string exn));
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
          ]);
        emit_activity config ~kind:"board.commented" ~actor:author
          ~subject:(Activity_graph.entity ~kind:"post" post_id)
          ~tags:[ "board"; "board.commented" ]
          ~payload:
            (`Assoc
              [
                ("post_id", `String post_id);
                ("content", `String content);
              ])
          ();
        (* Mention processing — mirror masc_broadcast pattern *)
        let mention = Mention.extract content in
        (match mention with
         | Some target ->
             Notify.notify_mention ~from_agent:author
               ~target_agent:target ~message:content ();
             ignore (Auto_responder.maybe_respond ~sw
               ~base_path:config.base_path ~from_agent:author
               ~content ~mention)
         | None -> ())
      end;
      Some result

  | "masc_board_vote" | "masc_board_comment_vote" ->
      let (success, _message) as result = Tool_board.handle_tool name arguments in
      (* Record vote activity as a fitness metric (Issue #1861). *)
      if success then begin
        let voter = Safe_ops.json_string ~default:"anonymous" "voter" arguments in
        let target_id =
          if name = "masc_board_vote" then
            Safe_ops.json_string ~default:"unknown" "post_id" arguments
          else
            Safe_ops.json_string ~default:"unknown" "comment_id" arguments
        in
        (try
           let now = Time_compat.now () in
           let metric : Metrics_store_eio.task_metric = {
             id = Metrics_store_eio.generate_id ();
             agent_id = voter;
             task_id = "board_vote:" ^ target_id;
             started_at = now;
             completed_at = Some now;
             success = true;
             error_message = None;
             collaborators = [];
             handoff_from = None;
             handoff_to = None;
           } in
           Metrics_store_eio.record config metric
         with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
           Log.Misc.error "board_vote fitness record failed: %s"
             (Printexc.to_string exn));
        let subject_kind =
          if String.equal name "masc_board_vote" then "post" else "comment"
        in
        emit_activity config ~kind:"board.voted" ~actor:voter
          ~subject:(Activity_graph.entity ~kind:subject_kind target_id)
          ~tags:[ "board"; "board.voted" ]
          ~payload:
            (`Assoc
              [
                ("target_id", `String target_id);
                ("target_kind", `String subject_kind);
              ])
          ()
      end;
      Some result

  | "masc_board_delete" ->
      let (success, _message) as result = Tool_board.handle_tool name arguments in
      if success then begin
        let post_id = Safe_ops.json_string ~default:"unknown" "post_id" arguments in
        let notification = `Assoc [
          ("type", `String "masc/board_delete");
          ("post_id", `String post_id);
          ("timestamp", `String (Types.now_iso ()));
        ] in
        Mcp_server.sse_broadcast state notification;
        emit_activity config ~kind:"board.deleted" ~actor:agent_name
          ~subject:(Activity_graph.entity ~kind:"post" post_id)
          ~tags:[ "board"; "board.deleted" ]
          ~payload:(`Assoc [ ("post_id", `String post_id) ])
          ()
      end;
      Some result

  | "masc_board_list" | "masc_board_get"
  | "masc_board_stats"
  | "masc_board_search" | "masc_board_profile"
  | "masc_board_hearths" ->
      Some (Tool_board.handle_tool name arguments)

  | _ -> None
