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

let json_upsert_assoc_field name value fields =
  (name, value) :: List.filter (fun (k, _) -> not (String.equal k name)) fields

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
      ~(primary_result : Tool_result.result)
      ~operation
      emit
  =
  match primary_result with
  | Tool_result.Deferred _ | Tool_result.Failed _ -> primary_result
  | Tool_result.Completed output ->
    (match emit () with
     | Ok () -> primary_result
     | Error detail ->
       let observation = `Assoc
         [ "status", `String "failed"
         ; "operation", `String (Event_kind.Board.to_string operation)
         ; "error", `String detail ] in
       let fields = match output.metadata with
         | None -> []
         | Some metadata ->
           (match metadata with
            | `Assoc fields -> fields
            | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
              [ "primary_metadata", metadata ]) in
       let metadata = `Assoc
         (json_upsert_assoc_field "activity_projection" observation fields) in
       Tool_result.Completed { output with metadata=Some metadata })

(* The handler reads the request's text once ([body], else [content]) and
   stores it. What follows a write here -- the SSE notification, the activity
   record and the mention -- takes the text from the stored row, so it cannot
   read the request by a different rule than the store did.

   The post handler returns the stored post as its typed data
   ([Board.post_to_yojson] plus the names no Keeper declares). *)
let written_post result = Board_tool.post_of_write_data (Tool_result.data result)

type written_comment_unavailable =
  | No_board_evidence
  | Board_evidence_unreadable of string
  | Board_evidence_is_a_reaction
  | Stored_comment_unreadable of Board.board_error

let written_comment_unavailable_to_string = function
  | No_board_evidence -> "the result carries no Board evidence"
  | Board_evidence_unreadable detail -> "the Board evidence does not decode: " ^ detail
  | Board_evidence_is_a_reaction -> "the Board evidence names a reaction, not a comment"
  | Stored_comment_unreadable error -> Board_tool.board_error_to_string error

(* The comment handler leaves the text out of its answer
   ([Board_tool_post.comment_acknowledgement]), so the stored comment is read
   back by the id in the handler's own write evidence. *)
let written_comment result =
  match Board_tool_evidence.of_metadata (Tool_result.metadata result) with
  | None -> Error No_board_evidence
  | Some (Error detail) -> Error (Board_evidence_unreadable detail)
  | Some (Ok (Board_tool_evidence.Reaction_changed _)) -> Error Board_evidence_is_a_reaction
  | Some (Ok (Board_tool_evidence.Comment_added { comment_id; _ })) ->
    Board.get_comment (Board_dispatch.backend ()) ~comment_id
    |> Result.map_error (fun error -> Stored_comment_unreadable error)

module For_testing = struct
  let result_after_activity_projection = result_after_activity_projection
end

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
    the board post path only consulted [agent_name] when the
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

let public_post ~post_id =
  match Board_dispatch.read_post_unchecked ~post_id with
  | Ok post -> (match post.visibility with Board.Public -> true | Board.Unlisted | Board.Internal | Board.Direct -> false)
  | Error _ -> false

let public_comment ~comment_id =
  let store = Board_dispatch.backend () in
  match Board.get_comment store ~comment_id with
  | Ok comment -> public_post ~post_id:(Board.Post_id.to_string comment.post_id)
  | Error _ -> false

(* The stored post of a successful write, when it is public. *)
let public_created_post result =
  if not (Tool_result.is_success result) then None
  else
    match written_post result with
    | None ->
      Log.Misc.error "board_post succeeded but its result data is not a post: %s"
        (Tool_result.message result);
      None
    | Some post ->
      (match post.visibility with
       | Board.Public -> Some post
       | Board.Unlisted | Board.Internal | Board.Direct -> None)

(* The stored comment of a successful write, when its post is public. *)
let public_written_comment result =
  if not (Tool_result.is_success result) then None
  else
    match written_comment result with
    | Error unavailable ->
      Log.Misc.error "board_comment succeeded but its stored comment is not available: %s"
        (written_comment_unavailable_to_string unavailable);
      None
    | Ok comment ->
      if public_post ~post_id:(Board.Post_id.to_string comment.post_id)
      then Some comment
      else None

let dispatch ~reader ~config ~agent_name ~arguments ~(state : Mcp_server.server_state) ~name =
  let arguments = bind_caller_identity ~name ~agent_name arguments in
  match Tool_name.Board_name.of_string name with
  | None -> None
  | Some Tool_name.Board_name.Board_post ->
      let result_tr = Board_tool.handle_tool ~reader ~result_boundary:Tool_output.Sent_to_client name arguments in
      let result_tr =
        match public_created_post result_tr with
        | None -> result_tr
        | Some post ->
        let author = Safe_ops.json_string ~default:"anonymous" "author" arguments in
        let content = post.body in
        let post_id = Board.Post_id.to_string post.id in
        let notification = `Assoc [
          ("type", `String "masc/board_post");
          ("author", `String author);
          ("author_identity", Server_utils.board_actor_identity_json author);
          ("content", `String (board_notification_content content));
          ("post_id", `String post_id);
          ("timestamp", `String (Masc_domain.now_iso ()));
        ] in
        Mcp_server.sse_broadcast state notification;
        let projected_result =
          result_after_activity_projection
            ~primary_result:result_tr
            ~operation:Event_kind.Board.Posted
            (fun () ->
               emit_activity
                 config
                 ~kind:(Event_kind.Board.to_string Event_kind.Board.Posted)
                 ~actor:author
                 ~subject:(Activity_graph.entity ~kind:"post" post_id)
                 ~tags:[ "board"; Event_kind.Board.to_string Event_kind.Board.Posted ]
                 ~payload:
                   (`Assoc
                     [ ("content", `String content)
                     ; ("post_id", `String post_id)
                     ])
                 ())
        in
        (* Mention processing — mirror masc_broadcast pattern *)
        let mention = Board_addressing.routing_target content in
        (match mention with
         | Some target ->
             Notify.notify_mention ~from_agent:author
               ~target_agent:target ~message:content ()
         | None -> ())
        ; projected_result
      in
      Some result_tr

  | Some Tool_name.Board_name.Board_comment ->
      let result_tr = Board_tool.handle_tool ~reader ~result_boundary:Tool_output.Sent_to_client name arguments in
      let result_tr =
        match public_written_comment result_tr with
        | None -> result_tr
        | Some comment ->
        let author = Safe_ops.json_string ~default:"anonymous" "author" arguments in
        let content = comment.content in
        let post_id = Board.Post_id.to_string comment.post_id in
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
            ~primary_result:result_tr
            ~operation:Event_kind.Board.Commented
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
        let mention = Board_addressing.routing_target content in
        (match mention with
         | Some target ->
             Notify.notify_mention ~from_agent:author
               ~target_agent:target ~message:content ()
         | None -> ())
        ; projected_result
      in
      Some result_tr

  | Some ((Tool_name.Board_name.Board_vote | Tool_name.Board_name.Board_comment_vote) as vote_name) ->
      let result_tr = Board_tool.handle_tool ~reader ~result_boundary:Tool_output.Sent_to_client name arguments in
      let result_tr =
        if Tool_result.is_success result_tr && (if vote_name = Tool_name.Board_name.Board_comment_vote then public_comment ~comment_id:(Safe_ops.json_string ~default:"" "comment_id" arguments) else public_post ~post_id:(Safe_ops.json_string ~default:"" "post_id" arguments)) then begin
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
          ~primary_result:result_tr
          ~operation:Event_kind.Board.Voted
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
      let publish_public = public_post ~post_id:(Safe_ops.json_string ~default:"" "post_id" arguments) in
      let result_tr = Board_tool.handle_tool ~reader ~result_boundary:Tool_output.Sent_to_client name arguments in
      let result_tr =
        if Tool_result.is_success result_tr && publish_public then begin
        let post_id = Safe_ops.json_string ~default:"unknown" "post_id" arguments in
        let notification = `Assoc [
          ("type", `String "masc/board_delete");
          ("post_id", `String post_id);
          ("timestamp", `String (Masc_domain.now_iso ()));
        ] in
        Mcp_server.sse_broadcast state notification;
        result_after_activity_projection
          ~primary_result:result_tr
          ~operation:Event_kind.Board.Deleted
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
      Some (Board_tool.handle_tool ~reader ~result_boundary:Tool_output.Sent_to_client name arguments)

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
     Both were routable by [Board_tool.handle_tool ~reader] all along but had no arm
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
      Some (Board_tool.handle_tool ~reader ~result_boundary:Tool_output.Sent_to_client name arguments)
