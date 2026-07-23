(** Runtime adapter for IDE annotation agent tools.

    Allows keepers to leave line-bound annotations on code files,
    stored in [.masc-ide/annotations.jsonl] and surfaced by the
    observational IDE dashboard.

    @since 0.6.0 — observational IDE Phase 1 *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_tool_shared_runtime

let handle_ide_annotate_with_outcome
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  : Keeper_tool_execution.t
  =
  let reject ?(class_ = Tool_result.Workflow_rejection) message =
    Keeper_tool_execution.failure ~class_ (error_json message)
  in
  let base_dir = Keeper_alerting_path.project_root_of_config config in
  let file_path = Safe_ops.json_string ~default:"" "file_path" args in
  let line_start = Safe_ops.json_int ~default:1 "line_start" args in
  let line_end = Safe_ops.json_int ~default:line_start "line_end" args in
  let kind_str = Safe_ops.json_string ~default:"Comment" "kind" args in
  let content = Safe_ops.json_string ~default:"" "content" args in
  let goal_id = Safe_ops.json_string_opt "goal_id" args in
  let task_id = Safe_ops.json_string_opt "task_id" args in
  let references_result =
    args
    |> Yojson.Safe.Util.member "references"
    |> Agent_observation.annotation_references_of_json
  in
  if String.trim file_path = ""
  then reject "file_path is required for ide_annotate"
  else if line_start < 1
  then reject "line_start must be >= 1"
  else if line_end < line_start
  then reject "line_end must be >= line_start"
  else if String.trim content = ""
  then reject "content is required for ide_annotate"
  else
    match references_result with
    | Error msg -> reject msg
    | Ok references ->
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
      (if Filename.is_relative file_path
       then
         Filename.concat
           (keeper_observation_sandbox_root ~config ~meta)
           file_path
       else file_path)
      |> keeper_observation_host_path_of_visible_path ~config ~meta
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
        ; references
        }
    with
    | Ok annotation ->
      Keeper_tool_execution.success
        (Yojson.Safe.to_string
           (`Assoc
               [ "ok", `Bool true
               ; "id", `String annotation.id
               ; "file_path", `String annotation.file_path
               ; "line_start", `Int annotation.line_start
               ; "line_end", `Int annotation.line_end
               ]))
    | Error msg -> reject ~class_:Tool_result.Runtime_failure msg
;;

let handle_ide_annotate ~config ~meta ~args =
  (handle_ide_annotate_with_outcome ~config ~meta ~args).raw_output
;;
