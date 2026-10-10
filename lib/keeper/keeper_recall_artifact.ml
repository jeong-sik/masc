type kind = Memory_os | Librarian

type pin_observation = Absent | Retired | Published of string

let decode_pin body =
  try match Yojson.Safe.from_string body with
  | `Null -> Ok Retired
  | `Assoc fields when List.sort String.compare (List.map fst fields) = ["artifact"; "generation"] ->
      (match List.assoc "generation" fields,
             Tool_output.normalized_artifact_ref_of_json (List.assoc "artifact" fields) with
       | `String generation, Tool_output.Decoded_normalized_artifact_ref _ ->
           Result.bind (Random_id.parse_uuid_v7 generation) (fun canonical ->
             if String.equal generation canonical then Ok (Published generation)
             else Error "recall pin generation is not canonical")
       | `String _, (Tool_output.Not_normalized_artifact_ref | Invalid_normalized_artifact_ref _)
       | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _), _ ->
           Error "recall pin requires a generation and normalized artifact")
  | `Assoc _ | `List _ | `String _ | `Bool _ | `Int _ | `Intlit _ | `Float _ ->
      Error "recall pin requires a versioned publication or null"
  with Yojson.Json_error detail -> Error detail

let current_path ~config ~keeper_id ~kind =
  let keeper_dir = Filename.concat (Workspace.keepers_runtime_dir config) keeper_id in
  let file = match kind with
    | Memory_os -> "memory-recall-current.json"
    | Librarian -> "librarian-recall-current.json" in
  Filename.concat keeper_dir file

let read_pin ~config path =
  Result.bind
    (Result.map_error Fs_compat.owned_regular_file_read_error_to_string
       (Fs_compat.load_owned_regular_file
          ~ownership_root:(Workspace.keepers_runtime_dir config) path))
    (function None -> Ok Absent | Some body -> decode_pin body)

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
  | Absent | Retired -> Ok ()
  | Published expected ->
      let path = current_path ~config ~keeper_id ~kind in
      with_pin_lock path (fun () ->
        Result.bind (read_pin ~config path) (function
          | Published current when String.equal expected current ->
              (* A structured empty root releases only this generation. Dated
                 history remains owned by its normal retention policy. *)
              Fs_compat.save_file_atomic_strict path "null"
          | Absent | Retired | Published _ -> Ok ()))

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
    with_pin_lock current (fun () ->
      (* Publication identity is independent of reusable filesystem metadata
         and artifact content, including repeated publication of one hash. *)
      let publication = `Assoc ["generation", `String (Random_id.uuid_v7 ()); "artifact", json] in
      Fs_compat.save_file_atomic_strict current (Yojson.Safe.to_string publication)))
;;
