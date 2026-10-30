module Artifact_id = Shared_types.Artifact_id

type source = Vision | Fusion_judge

type attempt =
  { source : source
  ; invocation_id : Artifact_id.t
  ; runtime_id : string
  ; attempt_index : int
  ; tool_use_id : string option
  ; trace_id : string option
  }

let invocation_id = Artifact_id.generate

let record_path ~base_path id =
  let traces = Filename.concat (Config_dir_resolver.masc_root ~base_path) "traces" in
  Filename.concat (Filename.concat traces "structured-output")
    (Artifact_id.to_string id ^ ".jsonl")
;;

let optional_string = function Some value -> `String value | None -> `Null

let warn code id =
  Cancel_safe.observe ~on_exn:(fun _ -> ()) (fun () ->
    Log.Keeper.warn "%s id=%s" code (Artifact_id.to_string id))
;;

let record_failure ~base_path ~(attempt : attempt) error =
  let detail = Agent_core.Error.to_string error in
  match error with
  | Agent_core.Error.Serialization
      (StructuredOutputParseError { reason; detail = parser_detail; raw_preview; raw_len }) ->
    (match base_path with
     | None -> detail ^ " [structured_evidence_unavailable: workspace_not_supplied]"
     | Some base_path ->
       let id = Artifact_id.generate () in
       let path = record_path ~base_path id in
       let row =
         `Assoc
           [ "schema", `String "masc.structured-response-evidence/v1"
           ; "evidence_id", Artifact_id.to_json id
           ; "source", `String (match attempt.source with Vision -> "vision" | Fusion_judge -> "fusion_judge")
           ; "invocation_id", Artifact_id.to_json attempt.invocation_id
           ; "runtime_id", `String attempt.runtime_id
           ; "attempt_index", `Int attempt.attempt_index
           ; "tool_use_id", optional_string attempt.tool_use_id
           ; "trace_id", optional_string attempt.trace_id
           ; "reason", `String (Agent_core.Error.structured_failure_label reason)
           ; "parser_detail", `String parser_detail
           ; "raw_preview", `String raw_preview
           ; "raw_len", `Int raw_len
           ]
       in
       let saved =
         try
           match Fs_compat.append_private_jsonl_durable_locked_result path
                   (Yojson.Safe.to_string row ^ "\n") with
           | Fs_compat.Private_file_succeeded () -> true
           | Fs_compat.Private_file_succeeded_with_cleanup_failure _ ->
             warn "structured_evidence_cleanup_failed" id;
             true
           | Fs_compat.Private_file_failed _ ->
             warn "structured_evidence_write_failed" id;
             false
           | Fs_compat.Private_file_failed_with_cleanup_failure _ ->
             warn "structured_evidence_write_and_cleanup_failed" id;
             false
         with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | Sys_error _ | Unix.Unix_error _ | Eio.Io _ ->
           warn "structured_evidence_write_failed" id;
           false
       in
       if saved then detail ^ " [structured_evidence_id: " ^ Artifact_id.to_string id ^ "]"
       else detail ^ " [structured_evidence_unavailable: write_failed]")
  | Serialization (JsonParseError _ | StructuredOutputStateError _
      | VersionMismatch _ | UnknownVariant _)
  | Api _ | Provider _ | Agent _ | Mcp _ | Config _ | Io _ | Orchestration _ | Media _
  | Internal _ | Internal_carried _ -> detail
;;
