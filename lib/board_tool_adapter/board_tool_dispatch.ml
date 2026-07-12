(** Board_tool_dispatch — tool-name routing and Tool_dispatch registration.

    Routes [masc_board_*] names to the matching handler in
    {!Board_tool_handlers}, {!Board_tool_post}, {!Board_tool_curation},
    or {!Board_tool_sub_board}; invalidates the {!Board_tool_cache}
    board_list TTL cache on mutations; and installs every schema from
    {!Board_tool_registry.tools} into the global {!Tool_dispatch}
    registry via {!Tool_spec.register_all}.

    Stage 10 split of lib/board_tool.ml. *)

(* RFC-0189 PR-1b.4 — [handle_tool] is now typed end-to-end:
   board handler modules (PR-1b.1/2/3) all return [Tool_result.result]
   and the old per-arm projection pipes are gone. *)

let handle_tool name args : Tool_result.result =
  let start_time = Time_compat.now () in
  match name with
  | "masc_board_post" ->
    let result =
      Board_tool_format.with_yojson_boundary ~tool_name:name ~start_time (fun () ->
        Board_tool_post.handle_post_create ~tool_name:name ~start_time args)
    in
    Board_tool_cache.invalidate_board_list_cache ();
    result
  | "masc_board_post_update" ->
    let result =
      Board_tool_format.with_yojson_boundary ~tool_name:name ~start_time (fun () ->
        Board_tool_post.handle_post_edit ~tool_name:name ~start_time args)
    in
    Board_tool_cache.invalidate_board_list_cache ();
    result
  | "masc_board_list" ->
    Board_tool_post.handle_post_list ~tool_name:name ~start_time args
  | "masc_board_post_get" ->
    Board_tool_post.handle_post_get ~tool_name:name ~start_time args
  | "masc_board_comment" ->
    let result =
      Board_tool_format.with_yojson_boundary ~tool_name:name ~start_time (fun () ->
        Board_tool_post.handle_comment_add ~tool_name:name ~start_time args)
    in
    Board_tool_cache.invalidate_board_list_cache ();
    result
  | "masc_board_vote" ->
    let result = Board_tool_handlers.handle_vote ~tool_name:name ~start_time args in
    Board_tool_cache.invalidate_board_list_cache ();
    result
  | "masc_board_stats" ->
    Board_tool_handlers.handle_stats ~tool_name:name ~start_time args
  | "masc_board_search" ->
    Board_tool_handlers.handle_search ~tool_name:name ~start_time args
  | "masc_board_comment_vote" ->
    let result =
      Board_tool_handlers.handle_comment_vote ~tool_name:name ~start_time args
    in
    Board_tool_cache.invalidate_board_list_cache ();
    result
  | "masc_board_reaction" ->
    let result = Board_tool_handlers.handle_reaction ~tool_name:name ~start_time args in
    Board_tool_cache.invalidate_board_list_cache ();
    result
  | "masc_board_profile" ->
    Board_tool_handlers.handle_profile ~tool_name:name ~start_time args
  | "masc_board_hearths" ->
    Board_tool_handlers.handle_hearth_list ~tool_name:name ~start_time args
  | "masc_board_curation_read" ->
    Board_tool_curation.handle_board_curation_read ~tool_name:name ~start_time args
  | "masc_board_curation_submit" ->
    Board_tool_curation.handle_board_curation_submit ~tool_name:name ~start_time args
  | "masc_board_delete" ->
    let result = Board_tool_handlers.handle_delete ~tool_name:name ~start_time args in
    Board_tool_cache.invalidate_board_list_cache ();
    result
  | "masc_board_cleanup" ->
    let result =
      Board_tool_handlers.handle_board_cleanup ~tool_name:name ~start_time args
    in
    Board_tool_cache.invalidate_board_list_cache ();
    result
  | "masc_board_sub_board_create" ->
    let result =
      Board_tool_sub_board.handle_sub_board_create ~tool_name:name ~start_time args
    in
    Board_tool_cache.invalidate_board_list_cache ();
    result
  | "masc_board_sub_board_list" ->
    Board_tool_sub_board.handle_sub_board_list ~tool_name:name ~start_time args
  | "masc_board_sub_board_get" ->
    Board_tool_sub_board.handle_sub_board_get ~tool_name:name ~start_time args
  | "masc_board_sub_board_update" ->
    let result =
      Board_tool_sub_board.handle_sub_board_update ~tool_name:name ~start_time args
    in
    Board_tool_cache.invalidate_board_list_cache ();
    result
  | "masc_board_sub_board_delete" ->
    let result =
      Board_tool_sub_board.handle_sub_board_delete ~tool_name:name ~start_time args
    in
    Board_tool_cache.invalidate_board_list_cache ();
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
  Tool_name.Board_name.all
  |> List.filter (fun board_name ->
    (Board_tool_registry.operation_policy board_name).readonly)
  |> List.map Tool_name.Board_name.to_string
;;

let register () =
  let handler ~name ~args = Some (handle_tool name args) in
  let make_spec board_name =
    let s = Board_tool_registry.schema_for_board_name board_name in
    let policy = Board_tool_registry.operation_policy board_name in
    Tool_spec.create
      ~name:s.name
      ~description:s.description
      ~module_tag:Tool_dispatch.Mod_inline
      ~input_schema:s.input_schema
      ~handler_binding:(Shared handler)
      ~is_read_only:policy.readonly
      ~is_idempotent:policy.idempotent
      ~is_destructive:policy.destructive
      ~visibility:policy.visibility
      ()
  in
  Tool_spec.register_all (List.map make_spec Tool_name.Board_name.all)
;;
