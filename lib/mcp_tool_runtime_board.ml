module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float


(** Mcp_tool_runtime_board — MCP server-local board tool runtime
    (recall, board, conversation).
    Returns [Some (Tool_result.result)] if handled, [None] otherwise.

    RFC-0062 Phase 4c-2: handlers now return [Tool_result.result] directly
    instead of [(bool * string)]. *)

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
         ?subject ~kind ~payload ~tags ())
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Log.Misc.warn "activity emit failed (%s): %s" kind
        (Stdlib.Printexc.to_string exn)

let extract_board_post_id (message : string) =
  match String.index_opt message '{' with
  | None -> None
  | Some idx ->
      try
        let json =
          Yojson.Safe.from_string
            (String.sub message idx (String.length message - idx))
        in
        match Json_util.assoc_member_opt "id" json with
        | Some (`String id) when not (String.equal (String.trim id) "") -> Some id
        | _ -> None
      with
      | Invalid_argument _
      | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None

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
    caller supplied an identity field whose canonical form disagrees
    with the runtime contract's [agent_name].  Pre-fix the caller's
    value was accepted unconditionally; the counter makes spoof
    attempts (or persona/system-prompt confusion) visible to
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
       (author / voter / owner / user_id) canonicalised to a different keeper than the \
       runtime contract's agent_name. The dispatcher rewrites the field \
       to the trusted ctx value and preserves the caller's claim in \
       [meta.<field>_caller_claim]; this counter surfaces the rewrite \
       so operators can rate-alert on identity drift. \
       Labels: [tool, field]."
    ()

let canonical_board_author raw =
  Server_utils.board_actor_author_for_write (String.trim raw)

let record_identity_raw_surface field raw canonical fields =
  if String.equal raw "" || String.equal raw canonical then fields
  else
    json_upsert_meta_string_field
      (Board_tool_format.raw_agent_name_meta_key ~field)
      raw
      fields

(** #10297: enforce that a board-tool caller cannot author / vote under
    a principal other than the runtime contract's [agent_name].  Pre-fix
    [ensure_board_post_author] only consulted [agent_name] when the
    caller's [author] field was empty, so any LLM that wrote a non-blank
    [author] argument bypassed identity verification.
    Board comment/vote paths also canonicalised caller fields without
    comparing them to [agent_name].

    Both paths now route through this helper, which compares the
    canonical form of the caller's claim against the canonical form
    of [agent_name]:

    1. Empty / "anonymous" -> fill from [agent_name].
    2. Caller's canonical equals ctx canonical -> keep the caller's
       canonicalisation (same keeper, possibly different surface form
       like [keeper-velvet-hammer-agent] vs [velvet-hammer]).
    3. Caller's canonical disagrees -> rewrite the field to ctx
       canonical, preserve the caller's claim in
       [meta.<field>_caller_claim] for forensics, and increment
       [masc_board_actor_identity_spoof_total{tool, field}].

    Lenient mode (rewrite + preserve) is preferred over strict
    fail-closed because the LLM occasionally supplies a wrong
    [author] under persona confusion; rejecting the call would
    break the chain and lose the post entirely, while the rewrite
    preserves the post with correct attribution and surfaces the
    drift to metrics. *)
let enforce_caller_identity ~tool ~field ~agent_name arguments =
  let ctx_raw = String.trim agent_name in
  let ctx_canonical =
    if String.equal ctx_raw "" then "" else canonical_board_author ctx_raw
  in
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
          if String.equal ctx_canonical "" then arguments
          else
            let fields =
              json_upsert_assoc_field field (`String ctx_canonical) fields
            in
            let fields =
              record_identity_raw_surface field ctx_raw ctx_canonical fields
            in
            `Assoc fields
      | claim ->
          let claim_canonical = canonical_board_author claim in
          if String.equal ctx_canonical "" then
            (* No ctx to compare against - preserve the caller's
               canonicalisation as the legacy code did. *)
            if String.equal claim_canonical claim then arguments
            else
              `Assoc
                (json_upsert_assoc_field field (`String claim_canonical)
                   fields)
          else if String.equal claim_canonical ctx_canonical then
            (* Caller's claim resolves to the same keeper as ctx.
               Store the canonical keeper name and preserve the raw
               surface that actually differed from the canonical form. *)
            let fields =
              json_upsert_assoc_field field (`String ctx_canonical) fields
            in
            let fields =
              record_identity_raw_surface field claim ctx_canonical fields
            in
            `Assoc fields
          else (
            (* Mismatch: caller tried to author / vote under a different
               principal. Rewrite to ctx, preserve the claim, and count
               the rewrite. *)
            Otel_metric_store.inc_counter board_actor_identity_spoof_metric
              ~labels:[ ("tool", tool); ("field", field) ]
              ();
            let fields =
              json_upsert_assoc_field field (`String ctx_canonical) fields
            in
            let fields =
              json_upsert_meta_string_field
                (field ^ "_caller_claim") claim fields
            in
            let fields =
              record_identity_raw_surface field ctx_raw ctx_canonical fields
            in
            `Assoc fields))
  | _ -> arguments

let ensure_board_post_author ~agent_name arguments =
  enforce_caller_identity ~tool:"masc_board_post" ~field:"author"
    ~agent_name arguments

let dispatch ~config ~agent_name ~arguments ~(state : Mcp_server.server_state) ~sw ~clock ~name ~start_time =
  (* fire-and-forget: unused params kept for interface contract with callers *)
  ignore (config, state, sw, clock, start_time);
  let arguments =
    match name with
    | "masc_board_post" ->
        enforce_caller_identity ~tool:name ~field:"author" ~agent_name
          arguments
    | "masc_board_comment" ->
        enforce_caller_identity ~tool:name ~field:"author" ~agent_name
          arguments
    | "masc_board_vote" | "masc_board_comment_vote" ->
        enforce_caller_identity ~tool:name ~field:"voter" ~agent_name
          arguments
    | "masc_board_reaction" ->
        enforce_caller_identity ~tool:name ~field:"user_id" ~agent_name
          arguments
    | "masc_board_sub_board_create" ->
        enforce_caller_identity ~tool:name ~field:"owner" ~agent_name
          arguments
    | "masc_board_post_update" ->
        enforce_caller_identity ~tool:name ~field:"author" ~agent_name
          arguments
    | "masc_board_delete" ->
        enforce_caller_identity ~tool:name ~field:"author" ~agent_name
          arguments
    | "masc_board_sub_board_update" | "masc_board_sub_board_delete" ->
        enforce_caller_identity ~tool:name ~field:"owner" ~agent_name
          arguments
    | "masc_board_curation_submit" ->
        enforce_caller_identity ~tool:name ~field:"submitted_by" ~agent_name
          arguments
    | _ -> arguments
  in
  match (name : string) with
  | "masc_board_post" ->
      let result_tr = Board_tool.handle_tool name arguments in
      if Tool_result.is_success result_tr then begin
        let author = Safe_ops.json_string ~default:"anonymous" "author" arguments in
        let content = Safe_ops.json_string ~default:"" "content" arguments in
        let post_id = extract_board_post_id (Tool_result.message result_tr) in
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
             (Stdlib.Printexc.to_string exn));
        let notification = `Assoc [
          ("type", `String "masc/board_post");
          ("author", `String author);
          ("author_identity", Server_utils.board_actor_identity_json author);
          ("content", `String (String.sub content 0 (min 200 (String.length content))));
          ("post_id", `String (Option.value post_id ~default:"unknown"));
          ("timestamp", `String (Masc_domain.now_iso ()));
        ] in
        Mcp_server.sse_broadcast state notification;
        emit_activity config ~kind:(Event_kind.Board.to_string Event_kind.Board.Posted) ~actor:author
          ?subject:
            (Option.map (Activity_graph.entity ~kind:"post") post_id)
          ~tags:[ "board"; Event_kind.Board.to_string Event_kind.Board.Posted ]
          ~payload:
            (`Assoc
              [
                ("content", `String content);
                ( "post_id", Json_util.string_opt_to_json post_id );
              ])
          ();
        (* Mention processing — mirror masc_broadcast pattern *)
        let mention = Mention.extract content in
        (match mention with
         | Some target ->
             Notify.notify_mention ~from_agent:author
               ~target_agent:target ~message:content ()
         | None -> ())
      end;
      Some result_tr

  | "masc_board_comment" ->
      let result_tr = Board_tool.handle_tool name arguments in
      if Tool_result.is_success result_tr then begin
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
             (Stdlib.Printexc.to_string exn));
        let notification = `Assoc [
          ("type", `String "board_comment");
          ("author", `String author);
          ("author_identity", Server_utils.board_actor_identity_json author);
          ("post_id", `String post_id);
          ("content", `String (String.sub content 0 (min 200 (String.length content))));
          ("timestamp", `String (Masc_domain.now_iso ()));
        ] in
        Mcp_server.sse_broadcast state notification;
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
               ~target_agent:target ~message:content ()
         | None -> ())
      end;
      Some result_tr

  | "masc_board_vote" | "masc_board_comment_vote" ->
      let result_tr = Board_tool.handle_tool name arguments in
      (* Record vote activity as a fitness metric (Issue #1861). *)
      if Tool_result.is_success result_tr then begin
        let voter = Safe_ops.json_string ~default:"anonymous" "voter" arguments in
        let target_id =
          if String.equal name "masc_board_vote" then
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
             (Stdlib.Printexc.to_string exn));
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
      Some result_tr

  | "masc_board_delete" ->
      let result_tr = Board_tool.handle_tool name arguments in
      if Tool_result.is_success result_tr then begin
        let post_id = Safe_ops.json_string ~default:"unknown" "post_id" arguments in
        let notification = `Assoc [
          ("type", `String "masc/board_delete");
          ("post_id", `String post_id);
          ("timestamp", `String (Masc_domain.now_iso ()));
        ] in
        Mcp_server.sse_broadcast state notification;
        emit_activity config ~kind:(Event_kind.Board.to_string Event_kind.Board.Deleted) ~actor:agent_name
          ~subject:(Activity_graph.entity ~kind:"post" post_id)
          ~tags:[ "board"; Event_kind.Board.to_string Event_kind.Board.Deleted ]
          ~payload:(`Assoc [ ("post_id", `String post_id) ])
          ()
      end;
      Some result_tr

  | "masc_board_list" | "masc_board_post_get"
  | "masc_board_stats"
  | "masc_board_search" | "masc_board_profile"
  | "masc_board_hearths"
  | "masc_board_curation_read"
  | "masc_board_curation_submit"
  | "masc_board_reaction"
  | "masc_board_sub_board_create"
  | "masc_board_sub_board_list"
  | "masc_board_sub_board_get"
  | "masc_board_sub_board_update"
  | "masc_board_sub_board_delete" ->
      Some (Board_tool.handle_tool name arguments)

  | _ -> None
