(** Runtime adapter for IDE annotation agent tools.

    Allows keepers to leave line-bound annotations on code files,
    stored in [.masc-ide/annotations.jsonl] and surfaced by the
    observational IDE dashboard.

    @since 0.6.0 — observational IDE Phase 1 *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_tool_shared_runtime

let handle_ide_annotate
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
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
      match Agent_observation.annotation_kind_of_string kind_str with
      | Some k -> k
      | None -> Agent_observation.Comment
    in
    (* #23469 (task-1733): the keeper hands us a path relative to its own
       working root — the playground sandbox — so anchor it there before
       partition resolution, exactly like the file tools resolve it. The
       old join left the path for the resolver to anchor at the server
       base path, which filed every keeper annotation under [_orphan/]
       (or worse, under whichever repository the base path happened to
       overlap), where repo-scoped IDE reads can never see it. *)
    let anchored_file_path =
      if Filename.is_relative file_path
      then
        Filename.concat
          (keeper_observation_sandbox_root ~config ~meta)
          file_path
      else file_path
    in
    let partition, stored_file_path =
      Keeper_tool_filesystem_runtime.resolve_partition_for_write
        ~base_dir:base_dir ~kind:"annotation" ~file_path:anchored_file_path
    in
    match
      Agent_observation.emit_annotation_request
        { base_path = base_dir
        ; partition
        ; keeper_id = meta.name
        ; file_path = stored_file_path
        ; line_start
        ; line_end
        ; kind
        ; content
        ; goal_id
        ; task_id
        ; board_post_id
        ; comment_id
        ; pr_id
        ; git_ref
        ; log_id
        ; session_id
        ; operation_id
        ; worker_run_id
        }
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
