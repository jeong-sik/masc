open Keeper_meta_contract

let kind_words = String.concat ", " Ide_memo.kind_words

let handle_ide_annotate_with_outcome
      ~turn_sandbox_factory
      ~config
      ~(meta : keeper_meta)
      ~publication_recovery
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~(args : Yojson.Safe.t)
      ()
  : Keeper_tool_execution.t
  =
  let reject message =
    Keeper_tool_execution.failure
      ~class_:Tool_result.Workflow_rejection
      (Keeper_tool_shared_runtime.error_json message)
  in
  let file_path = Safe_ops.json_string ~default:"" "file_path" args in
  let line = Safe_ops.json_int ~default:0 "line" args in
  let text = Safe_ops.json_string ~default:"" "text" args in
  if String.equal (String.trim file_path) ""
  then reject "file_path is required for keeper_ide_annotate"
  else if line < 1
  then reject "line must be >= 1: the memo goes above that line"
  else (
    (* The schema declares kind as an enum and documents the default, so
       absence is the plain comment and any other word is the caller's
       error, named back with the words that would have worked. *)
    let kind =
      match Safe_ops.safe_member "kind" args with
      | `Null -> Ok Agent_observation.Comment
      | `String word ->
        (match Ide_memo.kind_of_word word with
         | Some kind -> Ok kind
         | None -> Error word)
      | other -> Error (Yojson.Safe.to_string other)
    in
    match kind with
    | Error word -> reject (Printf.sprintf "kind must be one of [%s], got %S." kind_words word)
    | Ok kind ->
      (match Ide_memo.make ~author:meta.name ~kind ~text with
       | Error why -> reject ("the memo cannot be written: " ^ why)
       | Ok memo ->
         (match Lsp_process_manager.memo_line ~path:file_path memo with
          | Error refusal -> reject (Lsp_process_manager.memo_line_refusal_to_string refusal)
          | Ok comment_line ->
            Keeper_tool_filesystem_runtime.handle_file_write_with_outcome
              ~turn_sandbox_factory
              ~config
              ~meta
              ~publication_recovery
              ?continuation_channel
              ?gate_context
              ?gate_grant
              ~args:
                (`Assoc
                    [ "path", `String file_path
                    ; "mode", `String "patch"
                    ; "insert_before_line", `Int line
                    ; "insert_text", `String comment_line
                    ])
              ())))
;;
