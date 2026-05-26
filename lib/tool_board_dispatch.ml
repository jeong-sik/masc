(** Tool_board_dispatch — tool-name routing and Tool_dispatch registration.

    Routes [masc_board_*] names to the matching handler in
    {!Tool_board_handlers}, {!Tool_board_post}, {!Tool_board_curation},
    or {!Tool_board_sub_board}; invalidates the {!Tool_board_cache}
    board_list TTL cache on mutations; and installs every schema from
    {!Tool_board_registry.tools} into the global {!Tool_dispatch}
    registry via {!Tool_spec.register_all}.

    Stage 10 split of lib/tool_board.ml. *)

(* RFC-0189 PR-1b.4 — [handle_tool] is now typed end-to-end:
   board handler modules (PR-1b.1/2/3) all return [Tool_result.result],
   the per-arm [|> to_legacy] pipes that PR-1b.1/2/3 left behind are
   gone, and the single legacy projection lives at the
   [Tool_dispatch.handler] registration boundary in [register] below.

   Boundary collapse: 18 per-arm [to_legacy] calls + 1 fallback
   [Tool_result.error] → 1 [to_legacy] at the registration edge. *)

let handle_tool name args : Tool_result.result =
  let start_time = Time_compat.now () in
  match name with
  | "masc_board_post" ->
    let result =
      Tool_board_format.with_yojson_boundary ~tool_name:name ~start_time (fun () ->
        Tool_board_post.handle_post_create ~tool_name:name ~start_time args)
    in
    Tool_board_cache.invalidate_board_list_cache ();
    result
  | "masc_board_list" ->
    Tool_board_post.handle_post_list ~tool_name:name ~start_time args
  | "masc_board_get" ->
    Tool_board_post.handle_post_get ~tool_name:name ~start_time args
  | "masc_board_comment" ->
    let result =
      Tool_board_format.with_yojson_boundary ~tool_name:name ~start_time (fun () ->
        Tool_board_post.handle_comment_add ~tool_name:name ~start_time args)
    in
    Tool_board_cache.invalidate_board_list_cache ();
    result
  | "masc_board_vote" ->
    let result = Tool_board_handlers.handle_vote ~tool_name:name ~start_time args in
    Tool_board_cache.invalidate_board_list_cache ();
    result
  | "masc_board_stats" ->
    Tool_board_handlers.handle_stats ~tool_name:name ~start_time args
  | "masc_board_search" ->
    Tool_board_handlers.handle_search ~tool_name:name ~start_time args
  | "masc_board_comment_vote" ->
    let result =
      Tool_board_handlers.handle_comment_vote ~tool_name:name ~start_time args
    in
    Tool_board_cache.invalidate_board_list_cache ();
    result
  | "masc_board_reaction" ->
    let result = Tool_board_handlers.handle_reaction ~tool_name:name ~start_time args in
    Tool_board_cache.invalidate_board_list_cache ();
    result
  | "masc_board_profile" ->
    Tool_board_handlers.handle_profile ~tool_name:name ~start_time args
  | "masc_board_hearths" ->
    Tool_board_handlers.handle_hearth_list ~tool_name:name ~start_time args
  | "masc_board_curation_read" ->
    Tool_board_curation.handle_board_curation_read ~tool_name:name ~start_time args
  | "masc_board_curation_submit" ->
    Tool_board_curation.handle_board_curation_submit ~tool_name:name ~start_time args
  | "masc_board_delete" ->
    let result = Tool_board_handlers.handle_delete ~tool_name:name ~start_time args in
    Tool_board_cache.invalidate_board_list_cache ();
    result
  | "masc_board_cleanup" ->
    let result =
      Tool_board_handlers.handle_board_cleanup ~tool_name:name ~start_time args
    in
    Tool_board_cache.invalidate_board_list_cache ();
    result
  | "masc_board_sub_board_create" ->
    let result =
      Tool_board_sub_board.handle_sub_board_create ~tool_name:name ~start_time args
    in
    Tool_board_cache.invalidate_board_list_cache ();
    result
  | "masc_board_sub_board_list" ->
    Tool_board_sub_board.handle_sub_board_list ~tool_name:name ~start_time args
  | "masc_board_sub_board_get" ->
    Tool_board_sub_board.handle_sub_board_get ~tool_name:name ~start_time args
  | "masc_board_sub_board_update" ->
    let result =
      Tool_board_sub_board.handle_sub_board_update ~tool_name:name ~start_time args
    in
    Tool_board_cache.invalidate_board_list_cache ();
    result
  | "masc_board_sub_board_delete" ->
    let result =
      Tool_board_sub_board.handle_sub_board_delete ~tool_name:name ~start_time args
    in
    Tool_board_cache.invalidate_board_list_cache ();
    result
  | _ ->
    (* RFC-0189 — unknown-tool fallback now carries an explicit
       Workflow_rejection class (caller asked for a tool name not in
       this dispatch table). *)
    Tool_result.make_err
      ~tool_name:name
      ~class_:Tool_result.Workflow_rejection
      ~start_time
      (Printf.sprintf "Unknown tool: %s" name)
;;

let tool_spec_read_only =
  [ "masc_board_list"
  ; "masc_board_sub_board_list"
  ; "masc_board_sub_board_get"
  ; "masc_board_get"
  ; "masc_board_stats"
  ; "masc_board_search"
  ; "masc_board_profile"
  ; "masc_board_hearths"
  ; "masc_board_curation_read"
  ]
;;

let register () =
  (* RFC-0189 PR-1b.4 — single legacy projection at the registration
     boundary. [handle_tool] returns typed [Tool_result.result];
     [Tool_dispatch.handler] requires [Tool_result.result option], so we
     [to_legacy] exactly here. After PR-1c the [Tool_dispatch.handler]
     surface itself moves to [result] and this bridge disappears. *)
  let handler ~name ~args = Some (handle_tool name args) in
  let tool_required_permission = function
    | "masc_board_list"
    | "masc_board_get"
    | "masc_board_stats"
    | "masc_board_search"
    | "masc_board_profile"
    | "masc_board_hearths"
    | "masc_board_curation_read"
    | "masc_board_sub_board_list"
    | "masc_board_sub_board_get" -> Some Masc_domain.CanReadState
    | "masc_board_post"
    | "masc_board_comment"
    | "masc_board_vote"
    | "masc_board_comment_vote"
    | "masc_board_reaction"
    | "masc_board_curation_submit" -> Some Masc_domain.CanBroadcast
    | "masc_board_delete" | "masc_board_cleanup" -> Some Masc_domain.CanAdmin
    | "masc_board_sub_board_create"
    | "masc_board_sub_board_update"
    | "masc_board_sub_board_delete" -> Some Masc_domain.CanBroadcast
    | _ -> None
  in
  let make_spec (s : Masc_domain.tool_schema) =
    let ro = List.mem s.name tool_spec_read_only in
    Tool_spec.create
      ~name:s.name
      ~description:s.description
      ~module_tag:Tool_dispatch.Mod_inline
      ~input_schema:s.input_schema
      ~handler_binding:(Shared handler)
      ~is_read_only:ro
      ~is_idempotent:ro
      ~is_destructive:(String.equal s.name "masc_board_delete")
      ?required_permission:(tool_required_permission s.name)
      ()
  in
  Tool_spec.register_all (List.map make_spec Tool_board_registry.tools)
;;
