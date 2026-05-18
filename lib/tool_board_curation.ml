(** Tool_board_curation — board-curation handlers (read / submit) and
    the curation-specific JSON argument coercers.

    Stage 10 split of lib/tool_board.ml — sub-domain split out of
    [Tool_board_handlers] so both files stay under the godfile new-file
    cap. *)

open Tool_args

(** {1 Curation argument coercion} *)

let curation_tag_suggestions_arg args =
  Tool_board_format.object_list_arg args "tag_suggestions"
  |> List.filter_map (fun fields ->
    let post_id = Tool_board_format.string_field fields "post_id" "" in
    if String.equal post_id ""
    then None
    else
      Some
        { Board_curation.post_id
        ; tags = Tool_board_format.string_list_field fields "tags"
        ; rationale = Tool_board_format.string_field fields "rationale" ""
        })
;;

let curation_answer_matches_arg args =
  Tool_board_format.object_list_arg args "answer_matches"
  |> List.filter_map (fun fields ->
    let question_post_id =
      Tool_board_format.string_field fields "question_post_id" ""
    in
    let answer_post_id = Tool_board_format.string_field fields "answer_post_id" "" in
    if String.equal question_post_id "" || String.equal answer_post_id ""
    then None
    else
      Some
        { Board_curation.question_post_id
        ; answer_post_id
        ; score = Tool_board_format.float_field fields "score" 0.0
        ; rationale = Tool_board_format.string_field fields "rationale" ""
        })
;;

let curation_health_components_arg args =
  Tool_board_format.object_list_arg args "health_components"
  |> List.filter_map (fun fields ->
    let name = Tool_board_format.string_field fields "name" "" in
    if String.equal name ""
    then None
    else
      Some
        { Board_curation.name
        ; score = Tool_board_format.float_field fields "score" 0.0
        ; weight = Tool_board_format.float_field fields "weight" 0.0
        ; rationale = Tool_board_format.string_field fields "rationale" ""
        })
;;

(** {1 Handlers} *)

let handle_board_curation_read ~tool_name ~start_time _args =
  match Board_dispatch.latest_curation_snapshot () with
  | None -> Tool_result.ok ~tool_name ~start_time (Yojson.Safe.to_string `Null)
  | Some snap ->
    let json = Board_curation.snapshot_to_yojson snap in
    Tool_result.ok ~tool_name ~start_time (Yojson.Safe.to_string json)
;;

let handle_board_curation_submit ~tool_name ~start_time args =
  let submitted_by = get_string args "submitted_by" "" |> String.trim in
  let rationale = get_string args "rationale" "" |> String.trim in
  if String.equal submitted_by ""
  then Tool_result.error ~tool_name ~start_time "submitted_by required"
  else if String.equal rationale ""
  then Tool_result.error ~tool_name ~start_time "rationale required"
  else (
    let model = Tool_board_format.string_opt_arg args "model" in
    let summary = Tool_board_format.string_opt_arg args "summary" in
    let ordering = Tool_board_format.string_list_arg args "ordering" in
    let highlights = Tool_board_format.string_list_arg args "highlights" in
    let tag_suggestions = curation_tag_suggestions_arg args in
    let answer_matches = curation_answer_matches_arg args in
    let health_score = get_float_opt args "health_score" in
    let health_components = curation_health_components_arg args in
    match Tool_board_format.provenance_arg args with
    | Error msg -> Tool_result.error ~tool_name ~start_time msg
    | Ok provenance ->
      (try
         let snap =
           Board_dispatch.submit_curation_snapshot
             ~submitted_by
             ?model
             ?summary
             ~ordering
             ~highlights
             ~tag_suggestions
             ~answer_matches
             ?health_score
             ~health_components
             ~rationale
             ~provenance
             ()
         in
         Tool_result.ok
           ~tool_name
           ~start_time
           (Yojson.Safe.to_string (Board_curation.snapshot_to_yojson snap))
       with
       | Invalid_argument msg -> Tool_result.error ~tool_name ~start_time msg))
;;
