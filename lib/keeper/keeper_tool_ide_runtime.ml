(** Runtime adapter for IDE annotation agent tools.

    RFC-0378 §5.3 — the anchor contract is the co-view contract: the
    keeper hands back the [(codebase slug, repo-root-relative path)]
    the IDE gave it, verbatim. The handler mints the address directly;
    there is no sandbox anchoring and no resolver hop, so an
    unmintable anchor is a typed reject instead of a silent burial in
    a partition no repo-scoped read can see. *)

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
  let codebase = Safe_ops.json_string ~default:"" "codebase" args in
  let file_path = Safe_ops.json_string ~default:"" "file_path" args in
  let line_start = Safe_ops.json_int ~default:1 "line_start" args in
  let line_end = Safe_ops.json_int ~default:line_start "line_end" args in
  let kind_member = Safe_ops.safe_member "kind" args in
  let content = Safe_ops.json_string ~default:"" "content" args in
  let goal_id = Safe_ops.json_string_opt "goal_id" args in
  let task_id = Safe_ops.json_string_opt "task_id" args in
  let references_result =
    args
    |> Yojson.Safe.Util.member "references"
    |> Agent_observation.annotation_references_of_json
  in
  if String.trim codebase = ""
  then reject "codebase is required for ide_annotate — hand back the slug the co-view context names"
  else if String.trim file_path = ""
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
    (* The schema declares kind as an enum of the four constructors and
       documents the default, so absence is Comment and anything else is a
       client error. The previous shape defaulted twice — once for a missing or
       non-string member, once for an unrecognised string — and both landed on
       Comment, so {"kind":"decision"} (the casing an LLM reaches for) was
       silently filed as a comment with no rejection and no log. *)
    let kind_result =
      match kind_member with
      | `Null -> Ok Agent_observation.Comment
      | `String raw ->
        (match Agent_observation.annotation_kind_of_string raw with
         | Some k -> Ok k
         | None -> Error raw)
      | other -> Error (Yojson.Safe.to_string other)
    in
    match kind_result with
    | Error raw ->
      reject
        (Printf.sprintf
           "kind must be one of [%s], got %S."
           (String.concat ", " Agent_observation.valid_annotation_kind_strings)
           raw)
    | Ok kind ->
    (* RFC-0378 §5.3: mint the address from the co-view vocabulary
       directly. The keeper needs no knowledge of its own mount layout —
       it hands back what it was given, and the constructor's typed
       rejection is the contract error. *)
    match Agent_observation.Code_address.v ~codebase ~path:file_path with
    | Error invalid ->
      reject
        (Printf.sprintf
           "ide_annotate anchor rejected (%s) — pass the codebase slug and \
            repo-root-relative path exactly as the co-view context names them"
           (Agent_observation.Code_address.invalid_to_string invalid))
    | Ok address ->
    match
      Agent_observation.emit_annotation_request
        { base_path = base_dir
        ; attribution = Agent_observation.Addressed { address; checkout = None }
        ; keeper_id = meta.name
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
    (* A missing sink is a dependency this process never attached, not a
       fault in the call. Reporting it as a runtime failure told the model
       its own call broke and left the outcome unknown, so it could retry a
       call that had no effect. *)
    | Error Agent_observation.Sink_not_installed ->
      reject
        ~class_:Tool_result.Dependency_unavailable
        (Agent_observation.annotation_error_to_string
           Agent_observation.Sink_not_installed)
    | Error (Agent_observation.Sink_rejected msg) ->
      reject ~class_:Tool_result.Runtime_failure msg
;;

let handle_ide_annotate ~config ~meta ~args =
  (handle_ide_annotate_with_outcome ~config ~meta ~args).raw_output
;;
