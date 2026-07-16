type put_status =
  | Stored
  | Already_present
  | Reconciled

type load_error =
  | Not_found
  | Read_failed of Fs_compat.owned_regular_file_read_error
  | Snapshot_invalid of Keeper_checkpoint_store.checkpoint_ref_load_error
  | Content_mismatch of { path : string }
  | Reference_mismatch of
      { expected : Keeper_checkpoint_ref.t
      ; actual : Keeper_checkpoint_ref.t
      }
  | Load_lock_failed of File_lock_eio.durable_lock_error

type put_error =
  | Existing_object_invalid of
      { path : string
      ; error : load_error
      }
  | Write_not_committed of Keeper_fs.durable_write_error
  | Transaction_outcome_unknown of
      { write_error : Keeper_fs.durable_write_error
      ; observed : load_error
      }
  | Object_lock_failed of
      { error : File_lock_eio.durable_lock_error
      ; observed : load_error
      }
  | Access_failed of exn

let object_path ~base_path ~keeper_name
    ~(reference : Keeper_checkpoint_ref.t) =
  Filename.concat
    (Filename.concat
       (Filename.concat
          (Common.keepers_runtime_dir_of_base ~base_path)
          (Keeper_id.Keeper_name.to_string keeper_name))
       "compaction-objects")
    (reference.sha256 ^ ".checkpoint")
;;

let load_path_unlocked ~base_path path
    ~(reference : Keeper_checkpoint_ref.t) =
  match Fs_compat.load_owned_regular_file ~ownership_root:base_path path with
  | Error error -> Error (Read_failed error)
  | Ok None -> Error Not_found
  | Ok (Some bytes) ->
    (match
       Keeper_checkpoint_store.exact_snapshot_of_canonical_bytes
         ~expected_session_id:reference.trace_id
         bytes
     with
     | Error error -> Error (Snapshot_invalid error)
     | Ok snapshot ->
       let actual =
         Keeper_checkpoint_store.exact_snapshot_reference snapshot
       in
       if Keeper_checkpoint_ref.equal reference actual
       then Ok snapshot
       else Error (Reference_mismatch { expected = reference; actual }))
;;

let load ~base_path ~keeper_name ~(reference : Keeper_checkpoint_ref.t) =
  let path = object_path ~base_path ~keeper_name ~reference in
  if not (Fs_compat.file_exists (Filename.dirname path))
  then Error Not_found
  else
    match
      File_lock_eio.with_durable_lock
        ~lock_path:(path ^ ".lock")
        (fun () -> load_path_unlocked ~base_path path ~reference)
    with
    | Ok result -> result
    | Error error -> Error (Load_lock_failed error)
;;

let put_with ~write ~base_path ~keeper_name snapshot =
  let reference =
    Keeper_checkpoint_store.exact_snapshot_reference snapshot
  in
  let path = object_path ~base_path ~keeper_name ~reference in
  let canonical_bytes =
    Keeper_checkpoint_store.exact_snapshot_canonical_bytes snapshot
  in
  let observe_exact () =
    match load_path_unlocked ~base_path path ~reference with
    | Error error -> Error error
    | Ok observed ->
      if
        String.equal
          (Keeper_checkpoint_store.exact_snapshot_canonical_bytes observed)
          canonical_bytes
      then Ok ()
      else Error (Content_mismatch { path })
  in
  try
    Fs_compat.mkdir_p (Filename.dirname path);
    match
      File_lock_eio.with_durable_lock
        ~lock_path:(path ^ ".lock")
        (fun () ->
           if Fs_compat.file_exists path
           then
             (match observe_exact () with
              | Ok () -> Ok Already_present
              | Error error -> Error (Existing_object_invalid { path; error }))
           else
             match write path canonical_bytes with
             | Ok () -> Ok Stored
             | Error ({ Keeper_fs.renamed = false; _ } as error) ->
               Error (Write_not_committed error)
             | Error write_error ->
               (match observe_exact () with
                | Ok () -> Ok Reconciled
                | Error observed ->
                  Error
                    (Transaction_outcome_unknown
                       { write_error; observed })))
    with
    | Ok result -> result
    | Error error ->
      (match observe_exact () with
       | Ok _ -> Ok Reconciled
       | Error observed ->
         Error (Object_lock_failed { error; observed }))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Access_failed exn)
;;

let put ~base_path =
  put_with
    ~write:(Keeper_fs.save_bytes_durable_atomic ~ownership_root:base_path)
    ~base_path
;;

module For_testing = struct
  let put ~before_stage ~base_path =
    put_with
      ~write:
        (Keeper_fs.For_testing.save_bytes_durable_atomic
           ~before_stage
           ~ownership_root:base_path)
      ~base_path
  ;;
end
