(** Mcp_tool_runtime_board — MCP server-local board tool runtime
    (recall, board, conversation).
    Returns [Some (Tool_result.result)] if handled, [None] otherwise.

    RFC-0062 Phase 4c-2: handlers now return [Tool_result.result] directly
    instead of [(bool * string)]. *)

(* Board content reaches SSE subscribers as JSON. A byte-based cut lands
   mid-character on Korean (3 bytes per syllable) and emits an invalid
   sequence; Issue #7690 fixed the same shape in [Audit_log.preview]. *)
let board_notification_content_max_bytes = 200

let board_notification_content content =
  String_util.utf8_prefix ~max_bytes:board_notification_content_max_bytes content

let emit_activity config ~kind ~actor ?subject ?(tags = []) ~payload () =
  try
    let payload =
      match payload with
      | `Assoc fields ->
          `Assoc
            (("actor_identity", Server_utils.board_actor_identity_json actor)
            :: List.filter (fun (k, _) -> not (String.equal k "actor_identity")) fields)
      | other -> other
    in
    ignore
      (Activity_graph.emit config
         ~actor:(Server_utils.board_actor_entity actor)
         ?subject ~kind ~payload ~tags ());
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      let detail = Stdlib.Printexc.to_string exn in
      Log.Misc.warn "activity emit failed (%s): %s" kind detail;
      Error detail

let result_after_activity_projection
      ~tool_name
      ~start_time
      ~(primary_result : Tool_result.result)
      ~operation
      emit
  =
  if not (Tool_result.is_success primary_result)
  then primary_result
  else
    match emit () with
    | Ok () -> primary_result
    | Error detail ->
      Tool_result.make_err
        ~tool_name
        ~class_:Tool_result.Runtime_failure
        ~start_time
        ~data:
          (`Assoc
            [ ("primary_result", Tool_result.data primary_result)
            ; ( "effect_disposition"
              , `String
                  (Tool_result.failure_effect_disposition_to_string
                     Tool_result.Proven_post_effect) )
            ; ("projection", `String operation)
            ; ("error", `String detail)
            ])
        (Printf.sprintf
           "%s committed, but activity projection failed: %s"
           operation
           detail)

(* The post handler returns the created post as its typed data
   ([Board.post_to_yojson]); its id is read from there, not parsed back out of
   the message text written for the client. *)
let created_post_id result =
  Option.map
    (fun (post : Board.post) -> Board.Post_id.to_string post.id)
    (Board.post_of_yojson (Tool_result.data result))

module For_testing = struct
  let result_after_activity_projection = result_after_activity_projection
  let created_post_id = created_post_id
end

let json_upsert_assoc_field name value fields =
  (name, value) :: List.filter (fun (k, _) -> not (String.equal k name)) fields

let json_upsert_meta_string_field name value fields =
  let value = String.trim value in
  if String.equal value "" then fields
  else
    let meta_json =
      match List.assoc_opt "meta" fields with
      | Some (`Assoc meta_fields) ->
          `Assoc (json_upsert_assoc_field name (`String value) meta_fields)
      | _ -> `Assoc [ (name, `String value) ]
    in
    json_upsert_assoc_field "meta" meta_json fields

(** #10297: Otel_metric_store counter recording the cycle when a board-tool
    caller supplied an identity field that disagrees
    with the runtime contract's [agent_name].  Pre-fix the caller's
    value was accepted unconditionally; the counter makes spoof
    attempts (or Keeper instruction confusion) visible to
    operators instead of leaving them as silent audit drift.

    Cardinality is bounded by the small board write surface and identity fields
    ([author], [voter], [owner], [user_id]). *)
let board_actor_identity_spoof_metric =
  "masc_board_actor_identity_spoof_total"

let () =
  Otel_metric_store.register_counter
    ~name:board_actor_identity_spoof_metric
    ~help:
      "Total board-tool calls where the caller-supplied identity field \
       (author / voter / owner / user_id) named a different principal than the \
       runtime contract's agent_name. The dispatcher rewrites the field \
       to the trusted ctx value and preserves the caller's claim in \
       [meta.<field>_caller_claim]; this counter surfaces the rewrite \
       so operators can rate-alert on identity drift. \
       Labels: [tool, field]."
    ()

(** #10297: enforce that a board-tool caller cannot author / vote under
    a principal other than the runtime contract's [agent_name].  Pre-fix
    [ensure_board_post_author] only consulted [agent_name] when the
    caller's [author] field was empty, so any LLM that wrote a non-blank
    [author] argument bypassed identity verification.
    Board comment/vote paths also took caller fields without
    comparing them to [agent_name].

    Both paths now route through this helper, which compares the
    caller's claim against [agent_name]:

    1. Empty / "anonymous" -> fill from [agent_name].
    2. Caller's claim equals [agent_name] -> store [agent_name].
    3. Caller's claim disagrees -> rewrite the field to [agent_name],
       preserve the caller's claim in [meta.<field>_caller_claim] for
       forensics, and increment
       [masc_board_actor_identity_spoof_total{tool, field}].

    Lenient mode (rewrite + preserve) is preferred over strict
    fail-closed because the LLM occasionally supplies a wrong
    [author] under Keeper instruction confusion; rejecting the call would
    break the chain and lose the post entirely, while the rewrite
    preserves the post with correct attribution and surfaces the
    drift to metrics. *)
let enforce_caller_identity ~tool ~field ~agent_name arguments =
  let ctx = String.trim agent_name in
  match arguments with
  | `Assoc fields -> (
      let raw_existing =
        match List.assoc_opt field fields with
        | Some (`String s) -> String.trim s
        | _ -> ""
      in
      match raw_existing with
      | "" | "anonymous" ->
          (* Fill from ctx when caller left the field blank or
             explicitly marked it anonymous; if ctx is also empty,
             leave the original arguments untouched. *)
          if String.equal ctx "" then arguments
          else `Assoc (json_upsert_assoc_field field (`String ctx) fields)
      | claim ->
          if String.equal ctx "" then
            (* No ctx to compare against: keep the caller's claim. *)
            arguments
          else if String.equal claim ctx then
            `Assoc (json_upsert_assoc_field field (`String ctx) fields)
          else (
            (* Mismatch: caller tried to author / vote under a different
               principal. Rewrite to ctx, preserve the claim, and count
               the rewrite. *)
            Otel_metric_store.inc_counter board_actor_identity_spoof_metric
              ~labels:[ ("tool", tool); ("field", field) ]
              ();
            let fields =
              json_upsert_assoc_field field (`String ctx) fields
            in
            let fields =
              json_upsert_meta_string_field
                (field ^ "_caller_claim") claim fields
            in
            `Assoc fields))
  | _ -> arguments

let ensure_board_post_author ~agent_name arguments =
  enforce_caller_identity
    ~tool:(Tool_name.Board_name.to_string Tool_name.Board_name.Board_post)
    ~field:"author"
    ~agent_name arguments

(* [sw] and [clock] used to sit here beside the others, under an [ignore] and a
   comment calling all five "unused params kept for interface contract with
   callers". Three of the five -- [config], [state] and [start_time] -- are used
   in this function, and there is no interface contract: [dispatch] has one
   caller, a direct call from [Mcp_tool_runtime], and the sibling handlers take
   a different shape (~tool_name ~start_time ctx). What the [ignore] did was
   suppress the warning that would have named [sw] and [clock] as dead. *)
(* Which caller-identity fields a board tool binds comes from the same
   generated registry the Keeper runtime reads --
   [Board_tool_registry.identity_fields_for_board_name], built from
   config/tools/masc_board_*.toml -- so the TOML declaration moves both
   consumers at once. Until 2026-09-08 this path carried its own copy of the
   list as a match on tool-name strings ending in [_ -> arguments], and a
   declaration edited in TOML changed the Keeper path only (#34157). A name
   that is not a board tool has no identity fields to bind. *)
let bind_caller_identity ~name ~agent_name arguments =
  match Tool_name.Board_name.of_string name with
  | None -> arguments
  | Some board_name ->
      List.fold_left
        (fun arguments field ->
          enforce_caller_identity ~tool:name ~field ~agent_name arguments)
        arguments
        (Board_tool_registry.identity_fields_for_board_name board_name)

let dispatch ~config ~agent_name ~arguments ~(state : Mcp_server.server_state) ~name ~start_time =
  let arguments = bind_caller_identity ~name ~agent_name arguments in
  match Tool_name.Board_name.of_string name with
  | None -> None
  | Some Tool_name.Board_name.Board_post ->
      let result_tr = Board_tool.handle_tool ~result_boundary:Tool_output.Sent_to_client name arguments in
      let result_tr =
        if Tool_result.is_success result_tr then begin
        let author = Safe_ops.json_string ~default:"anonymous" "author" arguments in
        let content = Safe_ops.json_string ~default:"" "content" arguments in
        let post_id = created_post_id result_tr in
        if Option.is_none post_id then
          Log.Misc.error "board_post succeeded but its result data is not a post";
        let notification = `Assoc [
          ("type", `String "masc/board_post");
          ("author", `String author);
          ("author_identity", Server_utils.board_actor_identity_json author);
          ("content", `String (board_notification_content content));
          ("post_id", Json_util.string_opt_to_json post_id);
          ("timestamp", `String (Masc_domain.now_iso ()));
        ] in
        Mcp_server.sse_broadcast state notification;
        let projected_result =
          result_after_activity_projection
            ~tool_name:name
            ~start_time
            ~primary_result:result_tr
            ~operation:(Event_kind.Board.to_string Event_kind.Board.Posted)
            (fun () ->
               emit_activity
                 config
                 ~kind:(Event_kind.Board.to_string Event_kind.Board.Posted)
                 ~actor:author
                 ?subject:(Option.map (Activity_graph.entity ~kind:"post") post_id)
                 ~tags:[ "board"; Event_kind.Board.to_string Event_kind.Board.Posted ]
                 ~payload:
                   (`Assoc
                     [ ("content", `String content)
                     ; ("post_id", Json_util.string_opt_to_json post_id)
                     ])
                 ())
        in
        (* Mention processing — mirror masc_broadcast pattern *)
        let mention = Mention.extract content in
        (match mention with
         | Some target ->
             Notify.notify_mention ~from_agent:author
               ~target_agent:target ~message:content ()
         | None -> ())
        ; projected_result
        end
        else result_tr
      in
      Some result_tr

  | Some Tool_name.Board_name.Board_comment ->
      let result_tr = Board_tool.handle_tool ~result_boundary:Tool_output.Sent_to_client name arguments in
      let result_tr =
        if Tool_result.is_success result_tr then begin
        let author = Safe_ops.json_string ~default:"anonymous" "author" arguments in
        let content = Safe_ops.json_string ~default:"" "content" arguments in
        let post_id = Safe_ops.json_string ~default:"unknown" "post_id" arguments in
        let notification = `Assoc [
          ("type", `String "board_comment");
          ("author", `String author);
          ("author_identity", Server_utils.board_actor_identity_json author);
          ("post_id", `String post_id);
          ("content", `String (board_notification_content content));
          ("timestamp", `String (Masc_domain.now_iso ()));
        ] in
        Mcp_server.sse_broadcast state notification;
        let projected_result =
          result_after_activity_projection
            ~tool_name:name
            ~start_time
            ~primary_result:result_tr
            ~operation:(Event_kind.Board.to_string Event_kind.Board.Commented)
            (fun () ->
               emit_activity
                 config
                 ~kind:(Event_kind.Board.to_string Event_kind.Board.Commented)
                 ~actor:author
                 ~subject:(Activity_graph.entity ~kind:"post" post_id)
                 ~tags:[ "board"; Event_kind.Board.to_string Event_kind.Board.Commented ]
                 ~payload:(
                   `Assoc
                     [ ("post_id", `String post_id)
                     ; ("content", `String content)
                     ])
                 ())
        in
        (* Mention processing — mirror masc_broadcast pattern *)
        let mention = Mention.extract content in
        (match mention with
         | Some target ->
             Notify.notify_mention ~from_agent:author
               ~target_agent:target ~message:content ()
         | None -> ())
        ; projected_result
        end
        else result_tr
      in
      Some result_tr

  | Some ((Tool_name.Board_name.Board_vote | Tool_name.Board_name.Board_comment_vote) as vote_name) ->
      let result_tr = Board_tool.handle_tool ~result_boundary:Tool_output.Sent_to_client name arguments in
      let result_tr =
        if Tool_result.is_success result_tr then begin
        let voter = Safe_ops.json_string ~default:"anonymous" "voter" arguments in
        let target_field, subject_kind =
          match vote_name with
          | Tool_name.Board_name.Board_vote -> "post_id", "post"
          | Tool_name.Board_name.Board_post | Tool_name.Board_name.Board_post_update
          | Tool_name.Board_name.Board_list | Tool_name.Board_name.Board_post_get
          | Tool_name.Board_name.Board_comment | Tool_name.Board_name.Board_stats
          | Tool_name.Board_name.Board_search | Tool_name.Board_name.Board_comment_vote
          | Tool_name.Board_name.Board_reaction | Tool_name.Board_name.Board_profile
          | Tool_name.Board_name.Board_hearths | Tool_name.Board_name.Board_curation_read
          | Tool_name.Board_name.Board_curation_submit | Tool_name.Board_name.Board_delete
          | Tool_name.Board_name.Board_cleanup | Tool_name.Board_name.Board_close
          | Tool_name.Board_name.Board_reopen | Tool_name.Board_name.Board_sub_board_create
          | Tool_name.Board_name.Board_sub_board_list | Tool_name.Board_name.Board_sub_board_get
          | Tool_name.Board_name.Board_sub_board_update
          | Tool_name.Board_name.Board_sub_board_delete -> "comment_id", "comment"
        in
        let target_id = Safe_ops.json_string ~default:"unknown" target_field arguments in
        result_after_activity_projection
          ~tool_name:name
          ~start_time
          ~primary_result:result_tr
          ~operation:(Event_kind.Board.to_string Event_kind.Board.Voted)
          (fun () ->
             emit_activity
               config
               ~kind:(Event_kind.Board.to_string Event_kind.Board.Voted)
               ~actor:voter
               ~subject:(Activity_graph.entity ~kind:subject_kind target_id)
               ~tags:[ "board"; Event_kind.Board.to_string Event_kind.Board.Voted ]
               ~payload:(
                 `Assoc
                   [ ("target_id", `String target_id)
                   ; ("target_kind", `String subject_kind)
                   ])
               ())
        end
        else result_tr
      in
      Some result_tr

  | Some Tool_name.Board_name.Board_delete ->
      let result_tr = Board_tool.handle_tool ~result_boundary:Tool_output.Sent_to_client name arguments in
      let result_tr =
        if Tool_result.is_success result_tr then begin
        let post_id = Safe_ops.json_string ~default:"unknown" "post_id" arguments in
        let notification = `Assoc [
          ("type", `String "masc/board_delete");
          ("post_id", `String post_id);
          ("timestamp", `String (Masc_domain.now_iso ()));
        ] in
        Mcp_server.sse_broadcast state notification;
        result_after_activity_projection
          ~tool_name:name
          ~start_time
          ~primary_result:result_tr
          ~operation:(Event_kind.Board.to_string Event_kind.Board.Deleted)
          (fun () ->
             emit_activity
               config
               ~kind:(Event_kind.Board.to_string Event_kind.Board.Deleted)
               ~actor:agent_name
               ~subject:(Activity_graph.entity ~kind:"post" post_id)
               ~tags:[ "board"; Event_kind.Board.to_string Event_kind.Board.Deleted ]
               ~payload:(`Assoc [ ("post_id", `String post_id) ])
               ())
        end
        else result_tr
      in
      Some result_tr

  | Some Tool_name.Board_name.Board_post_get ->
      (* The read carries the caller's own vote back as a "내 투표" marker.
         The identity is the server's, through the same rewrite as vote's
         [voter]: a model-supplied viewer is corrected, never trusted —
         otherwise a read could impersonate another reader's vote state. *)
      let arguments =
        enforce_caller_identity ~tool:name ~field:"viewer" ~agent_name arguments
      in
      Some (Board_tool.handle_tool ~result_boundary:Tool_output.Sent_to_client name arguments)

  | Some
      ( Tool_name.Board_name.Board_list
      | Tool_name.Board_name.Board_stats
      | Tool_name.Board_name.Board_search
      | Tool_name.Board_name.Board_profile
      | Tool_name.Board_name.Board_hearths
      | Tool_name.Board_name.Board_curation_read
      | Tool_name.Board_name.Board_curation_submit
      | Tool_name.Board_name.Board_reaction
      | Tool_name.Board_name.Board_sub_board_create
      | Tool_name.Board_name.Board_sub_board_list
      | Tool_name.Board_name.Board_sub_board_get
      | Tool_name.Board_name.Board_sub_board_update
      | Tool_name.Board_name.Board_sub_board_delete
  (* masc_board_post_update runs through the same author-identity rewrite as
     masc_board_post above; masc_board_cleanup is the admin retention pass.
     Both were routable by [Board_tool.handle_tool] all along but had no arm
     here, so the MCP endpoint misreported them as
     "Unknown tool (registry inconsistency)". *)
      | Tool_name.Board_name.Board_post_update
      | Tool_name.Board_name.Board_cleanup
      (* task-1758/#39356: author-tier close/reopen. No SSE/activity-graph
         projection yet (unlike Board_delete above) -- same "was routable,
         had no arm" gap this comment already describes for post_update/
         cleanup, not a deliberate omission of notification wiring. *)
      | Tool_name.Board_name.Board_close
      | Tool_name.Board_name.Board_reopen ) ->
      Some (Board_tool.handle_tool ~result_boundary:Tool_output.Sent_to_client name arguments)
