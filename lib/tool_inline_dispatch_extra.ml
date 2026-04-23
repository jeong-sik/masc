
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
  match String.index_opt message '{' with
  | None -> None
  | Some idx ->
      try
        let json =
          Yojson.Safe.from_string
            (String.sub message idx (String.length message - idx))
        in
        match Yojson.Safe.Util.member "id" json with
        | `String id when String.trim id <> "" -> Some id
        | _ -> None
      with
      | Invalid_argument _
      | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None

(** Fill [author] from the caller's agent identity when the arg is absent or
    blank. Keepers, the HTTP surface, and autonomous callers routinely omit
    [author] — we used to reject those calls at pre-hook validation, which
    forced every caller to know about the legacy schema field. Canonical
    identity lives in [agent_name]; mirror it into the arg object so the
    downstream [Tool_board.handle_post_create] author check passes. *)
let ensure_board_post_author ~agent_name arguments =
  match arguments with
  | `Assoc fields ->
    let existing =
      match List.assoc_opt "author" fields with
      | Some (`String s) -> String.trim s
      | _ -> ""
    in
    if existing <> "" && existing <> "anonymous" then arguments
    else
      let injected = String.trim agent_name in
      if injected = "" then arguments
      else
        let stripped =
          List.filter (fun (k, _) -> k <> "author") fields
        in
        `Assoc (("author", `String injected) :: stripped)
  | _ -> arguments

let dispatch ~config ~agent_name ~arguments ~(state : Mcp_server.server_state) ~sw ~clock ~name =
  ignore (config, state, sw, clock);
  let arguments =
    match name with
    | "masc_board_post" -> ensure_board_post_author ~agent_name arguments
    | _ -> arguments
  in
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
        emit_activity config ~kind:(Event_kind.Board.to_string Event_kind.Board.Posted) ~actor:author
          ?subject:
            (Option.map (Activity_graph.entity ~kind:"post") post_id)
          ~tags:[ "board"; Event_kind.Board.to_string Event_kind.Board.Posted ]
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
        emit_activity config ~kind:(Event_kind.Board.to_string Event_kind.Board.Commented) ~actor:author
          ~subject:(Activity_graph.entity ~kind:"post" post_id)
          ~tags:[ "board"; Event_kind.Board.to_string Event_kind.Board.Commented ]
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
        emit_activity config ~kind:(Event_kind.Board.to_string Event_kind.Board.Voted) ~actor:voter
          ~subject:(Activity_graph.entity ~kind:subject_kind target_id)
          ~tags:[ "board"; Event_kind.Board.to_string Event_kind.Board.Voted ]
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
        emit_activity config ~kind:(Event_kind.Board.to_string Event_kind.Board.Deleted) ~actor:agent_name
          ~subject:(Activity_graph.entity ~kind:"post" post_id)
          ~tags:[ "board"; Event_kind.Board.to_string Event_kind.Board.Deleted ]
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
