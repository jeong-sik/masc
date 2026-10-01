type kind = Memory_os | Librarian

let retain ~config ~keeper_id ~kind ~now (artifact : Tool_output.artifact_ref) =
  (* Prompt text is not a structured GC root, and latest-prompt captures are
     overwritten. Historical pins use the same dated retention owner as turn
     records and provider inputs. The latest pin also protects paused keepers
     after dated history expires, until a new snapshot is published. *)
  let keeper_dir = Filename.concat (Workspace.keepers_runtime_dir config) keeper_id in
  let json = Tool_output.normalized_artifact_ref_to_json artifact in
  let base_dir = Filename.concat keeper_dir
      (Common.keeper_runtime_store_dirname Common.Keeper_memory_recall_artifacts) in
  let path = (Jsonl_writer.dated_path ~base_dir ~ts:now).path in
  let payload = Yojson.Safe.to_string json in
  let retained =
    match Fs_compat.append_private_jsonl_durable_locked_result path (payload ^ "\n") with
    | Fs_compat.Private_file_succeeded () -> Ok ()
    | Fs_compat.Private_file_succeeded_with_cleanup_failure { value = (); cleanup_failure } ->
      Log.Keeper.warn "recall artifact retention committed keeper=%s; descriptor cleanup failed: %s"
        keeper_id (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure);
      Ok ()
    | Fs_compat.Private_file_failed error ->
      Error (Fs_compat.private_jsonl_append_error_to_string error)
    | Fs_compat.Private_file_failed_with_cleanup_failure { error; cleanup_failure } ->
      Error (Printf.sprintf "%s; descriptor cleanup failed: %s"
        (Fs_compat.private_jsonl_append_error_to_string error)
        (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)) in
  (* The historical row and its parent directory must survive a crash before
     replacement of the previous current pin can release its reference. *)
  Result.bind retained (fun () ->
    let current_file = match kind with
      | Memory_os -> "memory-recall-current.json"
      | Librarian -> "librarian-recall-current.json" in
    Fs_compat.save_file_atomic_strict (Filename.concat keeper_dir current_file) payload)
;;
