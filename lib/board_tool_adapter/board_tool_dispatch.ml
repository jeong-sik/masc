open Masc_board_handlers

(** Board_tool_dispatch — tool-name routing and Tool_dispatch registration.

    Routes [masc_board_*] names to the matching handler in
    {!Board_tool_handlers}, {!Board_tool_post}, {!Board_tool_curation},
    or {!Board_tool_sub_board}; and installs every schema from
    {!Board_tool_registry.tools} into the global {!Tool_dispatch}
    registry via {!Tool_spec.register_all}. All handler arms return
    {!Tool_result.result}. *)

let handle_tool ~reader ~result_boundary name args : Tool_result.result =
  let start_time = Tool_timing.start () in
  let module B = Tool_name.Board_name in
  let require_target target_type target_id =
    let valid = match target_type with
      | Board.Reaction_post -> Result.is_ok (Board.Post_id.of_string target_id)
      | Board.Reaction_comment -> Result.is_ok (Board.Comment_id.of_string target_id) in
    if valid then Board_dispatch.require_readable_target ~reader ~target_type ~target_id
    else Ok ()
  in
  let access = match B.of_string name with
    | Some (B.Board_post_update | B.Board_comment | B.Board_vote
        | B.Board_delete | B.Board_close | B.Board_reopen) ->
      require_target Board.Reaction_post (Tool_args.get_string args "post_id" "")
    | Some B.Board_comment_vote ->
      require_target Board.Reaction_comment (Tool_args.get_string args "comment_id" "")
    | Some B.Board_reaction ->
      (match Board.reaction_target_type_of_string_opt (Tool_args.get_string args "target_type" "") with
       | None -> Ok ()
       | Some target_type -> require_target target_type (Tool_args.get_string args "target_id" ""))
    | None | Some (B.Board_post | B.Board_post_get | B.Board_list | B.Board_stats | B.Board_search
        | B.Board_profile | B.Board_hearths | B.Board_curation_read | B.Board_curation_submit
        | B.Board_cleanup | B.Board_sub_board_create | B.Board_sub_board_list
        | B.Board_sub_board_get | B.Board_sub_board_update | B.Board_sub_board_delete) -> Ok ()
  in
  let dispatch () =
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
    Board_tool_post.handle_post_create ~tool_name:name ~start_time args
  | Some B.Board_post_update ->
    Board_tool_format.with_yojson_boundary ~tool_name:name ~start_time (fun () ->
      Board_tool_post.handle_post_edit ~tool_name:name ~start_time args)
  | Some B.Board_list ->
    Board_tool_post.handle_post_list ~reader ~tool_name:name ~start_time args
  | Some B.Board_post_get ->
    Board_tool_post.handle_post_get ~reader ~result_boundary ~tool_name:name ~start_time args
  | Some B.Board_comment ->
    Board_tool_format.with_yojson_boundary ~tool_name:name ~start_time (fun () ->
      Board_tool_post.handle_comment_add ~reader ~tool_name:name ~start_time args)
  | Some B.Board_vote ->
    Board_tool_handlers.handle_vote ~reader ~tool_name:name ~start_time args
  | Some B.Board_stats ->
    Board_tool_handlers.handle_stats ~reader ~tool_name:name ~start_time args
  | Some B.Board_search ->
    Board_tool_handlers.handle_search ~reader ~tool_name:name ~start_time args
  | Some B.Board_comment_vote ->
    Board_tool_handlers.handle_comment_vote ~tool_name:name ~start_time args
  | Some B.Board_reaction ->
    Board_tool_handlers.handle_reaction ~reader ~tool_name:name ~start_time args
  | Some B.Board_profile ->
    Board_tool_handlers.handle_profile ~reader ~tool_name:name ~start_time args
  | Some B.Board_hearths ->
    Board_tool_handlers.handle_hearth_list ~reader ~tool_name:name ~start_time args
  | Some B.Board_curation_read ->
    Board_tool_curation.handle_board_curation_read ~reader ~tool_name:name ~start_time args
  | Some B.Board_curation_submit ->
    Board_tool_curation.handle_board_curation_submit ~tool_name:name ~start_time args
  | Some B.Board_delete ->
    Board_tool_handlers.handle_delete ~reader ~tool_name:name ~start_time args
  | Some B.Board_cleanup ->
    Board_tool_handlers.handle_board_cleanup ~reader ~tool_name:name ~start_time args
  | Some B.Board_close ->
    Board_tool_handlers.handle_close ~reader ~tool_name:name ~start_time args
  | Some B.Board_reopen ->
    Board_tool_handlers.handle_reopen ~reader ~tool_name:name ~start_time args
  | Some B.Board_sub_board_create ->
    Board_tool_sub_board.handle_sub_board_create ~reader ~tool_name:name ~start_time args
  | Some B.Board_sub_board_list ->
    Board_tool_sub_board.handle_sub_board_list ~reader ~tool_name:name ~start_time args
  | Some B.Board_sub_board_get ->
    Board_tool_sub_board.handle_sub_board_get ~reader ~tool_name:name ~start_time args
  | Some B.Board_sub_board_update ->
    Board_tool_sub_board.handle_sub_board_update ~reader ~tool_name:name ~start_time args
  | Some B.Board_sub_board_delete ->
    Board_tool_sub_board.handle_sub_board_delete ~reader ~tool_name:name ~start_time args
  in
  match access with
  | Ok () -> dispatch ()
  | Error error -> Board_tool_format.error_of_board_error ~tool_name:name ~start_time error

;;

let register () =
  (* The registry serves callers outside a Keeper turn, which take a result
     whole. *)
  let handler ~name ~args = handle_tool ~reader:Masc_board_handlers.Board_access.Anonymous ~result_boundary:Tool_output.Sent_to_client name args in
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
