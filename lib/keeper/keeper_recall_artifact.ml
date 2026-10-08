type kind = Memory_os | Librarian

type pin_observation = Fs_compat.owned_regular_file_contents option

let current_path ~config ~keeper_id ~kind =
  let keeper_dir = Filename.concat (Workspace.keepers_runtime_dir config) keeper_id in
  let file = match kind with
    | Memory_os -> "memory-recall-current.json"
    | Librarian -> "librarian-recall-current.json" in
  Filename.concat keeper_dir file

let read_pin ~config path =
  Result.map_error Fs_compat.owned_regular_file_read_error_to_string
    (Fs_compat.load_owned_regular_file_with_snapshot
       ~ownership_root:(Workspace.keepers_runtime_dir config) path)

let observe_current ~config ~keeper_id ~kind =
  read_pin ~config (current_path ~config ~keeper_id ~kind)

let with_pin_lock path run =
  (* Both aliases and system-thread/fiber callers own the same stable lock. *)
  let path = Filename.concat (Unix.realpath (Filename.dirname path)) (Filename.basename path) in
  match File_lock_eio.with_durable_lock_observed ~lock_path:(path ^ ".lock") run with
  | Lock_not_acquired error -> Error (File_lock_eio.durable_lock_error_to_string error)
  | Body_completed {value; release_error} ->
      Option.iter (fun error -> Log.Keeper.warn "recall pin lock cleanup failed: %s"
          (File_lock_eio.durable_lock_error_to_string error)) release_error;
      value

let retire_current ~config ~keeper_id ~kind (observed : pin_observation) =
  match observed with
  | None -> Ok ()
  | Some expected ->
      let path = current_path ~config ~keeper_id ~kind in
      with_pin_lock path (fun () ->
        Result.bind (read_pin ~config path) (function
          | Some current when Fs_compat.equal_owned_regular_file_snapshot
              expected.snapshot current.snapshot && String.equal expected.content current.content ->
              (* A structured empty root releases only this current pin. Dated
                 history remains owned by its normal retention policy. *)
              Fs_compat.save_file_atomic_strict path "null"
          | None | Some _ -> Ok ()))

let retain ~config ~keeper_id ~kind ~now (artifact : Tool_output.artifact_ref) =
  (* Prompt text is not a structured GC root, and latest-prompt captures are
     overwritten. Historical pins use the same dated retention owner as turn
     records and provider inputs. The latest pin also protects paused keepers
     after dated history expires, until a new snapshot is published or an
     authoritative recall mode supersedes it. *)
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
    let current = current_path ~config ~keeper_id ~kind in
    with_pin_lock current (fun () -> Fs_compat.save_file_atomic_strict current payload))
;;
