(** Board_tool_curation — board-curation handlers (read / submit) and
    the curation-specific JSON argument coercers.

    Stage 10 split of lib/board_tool.ml — sub-domain split out of
    [Board_tool_handlers] so both files stay under the godfile new-file
    cap. *)

open Masc_board_handlers
open Tool_args

(** {1 Curation argument coercion} *)

let curation_tag_suggestions_arg args =
  Board_tool_format.object_list_arg args "tag_suggestions"
  |> List.filter_map (fun fields ->
    let post_id = Board_tool_format.string_field fields "post_id" "" in
    if String.equal post_id ""
    then None
    else
      Some
        { Board_curation.post_id
        ; tags = Board_tool_format.string_list_field fields "tags"
        ; rationale = Board_tool_format.string_field fields "rationale" ""
        })
;;

let curation_answer_matches_arg args =
  Board_tool_format.object_list_arg args "answer_matches"
  |> List.filter_map (fun fields ->
    let question_post_id =
      Board_tool_format.string_field fields "question_post_id" ""
    in
    let answer_post_id = Board_tool_format.string_field fields "answer_post_id" "" in
    if String.equal question_post_id "" || String.equal answer_post_id ""
    then None
    else
      Some
        { Board_curation.question_post_id
        ; answer_post_id
        ; score = Board_tool_format.float_field fields "score" 0.0
        ; rationale = Board_tool_format.string_field fields "rationale" ""
        })
;;

(** {1 Handlers} *)

(* RFC-0189 PR-1b.3 — handlers in this module return typed
   [Tool_result.result]. Curation snapshots are passed as typed JSON
   [~data] directly. *)

let handle_board_curation_read ~tool_name ~start_time _args : Tool_result.result =
  match Board_dispatch.latest_curation_snapshot () with
  | None -> Tool_result.make_ok ~tool_name ~start_time ~data:`Null ()
  | Some snap ->
    let json = Board_curation.snapshot_to_yojson snap in
    Tool_result.make_ok ~tool_name ~start_time ~data:json ()
;;

let handle_board_curation_submit ~tool_name ~start_time args : Tool_result.result =
  let submitted_by = get_string args "submitted_by" "" |> String.trim in
  let rationale = get_string args "rationale" "" |> String.trim in
  if String.equal submitted_by ""
  then
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Workflow_rejection
      ~start_time
      "submitted_by required"
  else if String.equal rationale ""
  then
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Workflow_rejection
      ~start_time
      "rationale required"
  else (
    let summary = Board_tool_format.string_opt_arg args "summary" in
    let ordering = Board_tool_format.string_list_arg args "ordering" in
    let highlights = Board_tool_format.string_list_arg args "highlights" in
    let tag_suggestions = curation_tag_suggestions_arg args in
    let answer_matches = curation_answer_matches_arg args in
    match Board_tool_format.provenance_arg args with
    | Error msg ->
      Tool_result.make_err
        ~tool_name
        ~class_:Tool_result.Workflow_rejection
        ~start_time
        msg
    | Ok provenance ->
      (try
         let snap =
           Board_dispatch.submit_curation_snapshot
             ~submitted_by
             ?summary
             ~ordering
             ~highlights
             ~tag_suggestions
             ~answer_matches
             ~rationale
             ~provenance
             ()
         in
         Tool_result.make_ok
           ~tool_name
           ~start_time
           ~data:(Board_curation.snapshot_to_yojson snap)
           ()
       with
       | Invalid_argument msg ->
         Tool_result.make_err
           ~tool_name
           ~class_:Tool_result.Workflow_rejection
           ~start_time
           msg))
;;
