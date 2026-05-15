(** Keeper_exec_ide — MCP tool handler for keeper_ide_annotate.

    Allows keepers to leave line-bound annotations on code files,
    stored in [.masc-ide/annotations.jsonl] and surfaced by the
    observational IDE dashboard.

    @since 0.6.0 — observational IDE Phase 1 *)

open Keeper_types
open Keeper_exec_shared
open Ide_annotation_types

let handle_keeper_ide_annotate
      ~(config : Coord.config)
      ~(keeper_name : string)
      ~(args : Yojson.Safe.t)
  : string
  =
  let base_dir = Keeper_alerting_path.project_root_of_config config in
  let file_path = Safe_ops.json_string ~default:"" "file_path" args in
  let line_start = Safe_ops.json_int ~default:1 "line_start" args in
  let line_end = Safe_ops.json_int ~default:line_start "line_end" args in
  let kind_str = Safe_ops.json_string ~default:"Comment" "kind" args in
  let content = Safe_ops.json_string ~default:"" "content" args in
  let goal_id = Safe_ops.json_string_opt "goal_id" args in
  let task_id = Safe_ops.json_string_opt "task_id" args in
  let board_post_id = Safe_ops.json_string_opt "board_post_id" args in
  let comment_id = Safe_ops.json_string_opt "comment_id" args in
  let pr_id = Safe_ops.json_string_opt "pr_id" args in
  let git_ref = Safe_ops.json_string_opt "git_ref" args in
  let log_id = Safe_ops.json_string_opt "log_id" args in
  let session_id = Safe_ops.json_string_opt "session_id" args in
  let operation_id = Safe_ops.json_string_opt "operation_id" args in
  let worker_run_id = Safe_ops.json_string_opt "worker_run_id" args in
  if String.trim file_path = ""
  then error_json "file_path is required for ide_annotate"
  else if line_start < 1
  then error_json "line_start must be >= 1"
  else if line_end < line_start
  then error_json "line_end must be >= line_start"
  else if String.trim content = ""
  then error_json "content is required for ide_annotate"
  else (
    let kind =
      match Ide_annotations.annotation_kind_of_string kind_str with
      | Some k -> k
      | None -> Comment
    in
    match
      Ide_annotations.create
        ~base_dir
        ~keeper_id:keeper_name
        ~file_path
        ~line_start
        ~line_end
        ~kind
        ~content
        ?goal_id
        ?task_id
        ?board_post_id
        ?comment_id
        ?pr_id
        ?git_ref
        ?log_id
        ?session_id
        ?operation_id
        ?worker_run_id
        ()
    with
    | Ok annotation ->
      Yojson.Safe.to_string
        (`Assoc
            [ "ok", `Bool true
            ; "id", `String annotation.id
            ; "file_path", `String annotation.file_path
            ; "line_start", `Int annotation.line_start
            ; "line_end", `Int annotation.line_end
            ])
    | Error msg -> error_json msg)
;;
