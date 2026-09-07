(** Board_tool_dispatch — tool-name routing and Tool_dispatch registration.

    Routes [masc_board_*] names to the matching handler in
    {!Board_tool_handlers}, {!Board_tool_post}, {!Board_tool_curation},
    or {!Board_tool_sub_board}; and installs every schema from
    {!Board_tool_registry.tools} into the global {!Tool_dispatch}
    registry via {!Tool_spec.register_all}. All handler arms return
    {!Tool_result.result}. *)

let handle_tool name args : Tool_result.result =
  let start_time = Time_compat.now () in
  let module B = Tool_name.Board_name in
  (* [register] advertises one tool per [B.all] constructor, so routing has to
     be decided on the same closed type. Matching the wire string here instead
     let a new constructor be advertised while its call fell through to the
     unknown-tool arm, with nothing in the build to say so. *)
  match B.of_string name with
  | None ->
    (* Direct callers receive a typed rejection for unrecognized names. *)
    Tool_result.make_err
      ~tool_name:name
      ~class_:Tool_result.Workflow_rejection
      ~start_time
      (Printf.sprintf "Unknown tool: %s" name)
  | Some B.Board_post ->
    Board_tool_format.with_yojson_boundary ~tool_name:name ~start_time (fun () ->
      Board_tool_post.handle_post_create ~tool_name:name ~start_time args)
  | Some B.Board_post_update ->
    Board_tool_format.with_yojson_boundary ~tool_name:name ~start_time (fun () ->
      Board_tool_post.handle_post_edit ~tool_name:name ~start_time args)
  | Some B.Board_list ->
    Board_tool_post.handle_post_list ~tool_name:name ~start_time args
  | Some B.Board_post_get ->
    Board_tool_post.handle_post_get ~tool_name:name ~start_time args
  | Some B.Board_comment ->
    Board_tool_format.with_yojson_boundary ~tool_name:name ~start_time (fun () ->
      Board_tool_post.handle_comment_add ~tool_name:name ~start_time args)
  | Some B.Board_vote ->
    Board_tool_handlers.handle_vote ~tool_name:name ~start_time args
  | Some B.Board_stats ->
    Board_tool_handlers.handle_stats ~tool_name:name ~start_time args
  | Some B.Board_search ->
    Board_tool_handlers.handle_search ~tool_name:name ~start_time args
  | Some B.Board_comment_vote ->
    Board_tool_handlers.handle_comment_vote ~tool_name:name ~start_time args
  | Some B.Board_reaction ->
    Board_tool_handlers.handle_reaction ~tool_name:name ~start_time args
  | Some B.Board_profile ->
    Board_tool_handlers.handle_profile ~tool_name:name ~start_time args
  | Some B.Board_hearths ->
    Board_tool_handlers.handle_hearth_list ~tool_name:name ~start_time args
  | Some B.Board_curation_read ->
    Board_tool_curation.handle_board_curation_read ~tool_name:name ~start_time args
  | Some B.Board_curation_submit ->
    Board_tool_curation.handle_board_curation_submit ~tool_name:name ~start_time args
  | Some B.Board_delete ->
    Board_tool_handlers.handle_delete ~tool_name:name ~start_time args
  | Some B.Board_cleanup ->
    Board_tool_handlers.handle_board_cleanup ~tool_name:name ~start_time args
  | Some B.Board_sub_board_create ->
    Board_tool_sub_board.handle_sub_board_create ~tool_name:name ~start_time args
  | Some B.Board_sub_board_list ->
    Board_tool_sub_board.handle_sub_board_list ~tool_name:name ~start_time args
  | Some B.Board_sub_board_get ->
    Board_tool_sub_board.handle_sub_board_get ~tool_name:name ~start_time args
  | Some B.Board_sub_board_update ->
    Board_tool_sub_board.handle_sub_board_update ~tool_name:name ~start_time args
  | Some B.Board_sub_board_delete ->
    Board_tool_sub_board.handle_sub_board_delete ~tool_name:name ~start_time args
;;

let register () =
  let handler ~name ~args = handle_tool name args in
  let make_spec board_name =
    let s = Board_tool_registry.schema_for_board_name board_name in
    let policy = Board_tool_registry.operation_policy board_name in
    Tool_spec.create
      ~name:s.name
      ~description:s.description
      ~module_tag:Tool_dispatch.Mod_inline
      ~input_schema:s.input_schema
      ~handler_binding:(Registered handler)
      ~is_read_only:policy.readonly
      ~is_idempotent:policy.idempotent
      ~visibility:policy.visibility
      ()
  in
  Tool_spec.register_all (List.map make_spec Tool_name.Board_name.all)
;;
