module Objects = Agent_core.Checkpoint_objects
open Keeper_checkpoint_store_history_files
open Keeper_checkpoint_store_decode
open Keeper_checkpoint_store_session
open Keeper_checkpoint_store_ref_errors
open Keeper_checkpoint_store_installation
open Keeper_checkpoint_store_exact_snapshot
open Keeper_checkpoint_store_cas_save

(* Accepted continuations are not observational rolling history: nothing
   expires them while a semantic execution names them. Once a journal commit
   stops naming one, the Owner removes it through [release_retained];
   [Keeper_retained_checkpoint_sweep] removes, at server startup, what a crash
   or a failed removal left. *)
let retained_dirname = "accepted-checkpoints"

let retained_checkpoint_path ~session_dir (reference : Keeper_checkpoint_ref.t) =
  Filename.concat (Filename.concat session_dir retained_dirname)
    (reference.sha256 ^ ".json")

let read_retained_locked ~session_dir ~reference =
  match Fs_compat.load_owned_regular_file
          ~ownership_root:(Filename.dirname session_dir)
          (retained_checkpoint_path ~session_dir reference) with
  | Error error ->
      Error (Source_unavailable (Ref_read_failed
        (Store_error (Fs_compat.owned_regular_file_read_error_to_string error))))
  | Ok None -> Ok None
  | Ok (Some bytes) ->
      (match exact_snapshot_of_head_bytes ~session_dir
               ~expected_session_id:reference.Keeper_checkpoint_ref.trace_id bytes with
       | Error error -> Error (Source_unavailable error)
       | Ok snapshot when Keeper_checkpoint_ref.equal reference snapshot.reference ->
           Ok (Some snapshot)
       | Ok snapshot -> Error (Source_changed snapshot.reference))

let load_retained_exact_snapshot ~session_dir ~reference =
  match with_session_lock ~session_dir (fun session_dir ->
    match read_retained_locked ~session_dir ~reference with
    | Error _ as error -> error
    | Ok None -> Error (Source_unavailable Ref_not_found)
    | Ok (Some snapshot) -> Ok snapshot) with
  | Ok result -> result
  | Error detail -> Error (Source_unavailable (Ref_lock_failed detail))

type retained_snapshot =
  | Retained_current of exact_checkpoint_snapshot
  | Retained_superseded of
      { reference : Keeper_checkpoint_ref.t
      ; expected_version : int
      ; got_version : int
      ; pending_input : Agent_core.Agent_input_request.pending option
      }

let decode_superseded_retained_bytes
    ~(reference : Keeper_checkpoint_ref.t)
    ~expected
    ~got
    bytes =
  let parse_error detail =
    Error (Source_unavailable (Ref_read_failed (Parse_error detail)))
  in
  let actual_sha256 =
    offload_checkpoint_cpu (fun () ->
      Keeper_checkpoint_ref.sha256_of_canonical_bytes bytes)
  in
  if not (String.equal actual_sha256 reference.sha256)
  then parse_error "superseded retained checkpoint digest mismatch"
  else (
    match offload_checkpoint_cpu (fun () -> Yojson.Safe.from_string bytes) with
    | exception Yojson.Json_error detail -> parse_error detail
    | `Assoc fields ->
      let unique_field name =
        match
          List.filter_map
            (fun (key, value) -> if String.equal key name then Some value else None)
            fields
        with
        | [ value ] -> Some value
        | [] | _ :: _ :: _ -> None
      in
      let session_id_opt =
        match unique_field "session_id" with
        | Some (`String session_id) -> Some session_id
        | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _)
        | None -> None
      in
      let turn_count_opt =
        match unique_field "turn_count" with
        | Some (`Int turn_count) -> Some turn_count
        | Some (`Null | `Bool _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _)
        | None -> None
      in
      (match session_id_opt, turn_count_opt with
       | Some session_id, Some turn_count ->
         (match Keeper_id.Trace_id.of_string session_id with
          | Error reason ->
            Error
              (Source_unavailable
                 (Ref_identity_invalid (Session_id_invalid reason)))
          | Ok actual_trace_id
            when not (Keeper_id.Trace_id.equal actual_trace_id reference.trace_id) ->
            Error
              (Source_unavailable
                 (Ref_session_mismatch
                    { expected = reference.trace_id; actual = actual_trace_id }))
          | Ok _ ->
            if turn_count <> reference.turn_count
            then
              match
                Keeper_checkpoint_ref.of_persisted
                  ~trace_id:reference.trace_id
                  ~turn_count
                  ~sha256:actual_sha256
              with
              | Ok actual_ref -> Error (Source_changed actual_ref)
              | Error error ->
                Error
                  (Source_unavailable
                     (Ref_identity_invalid (Ref_create_failed error)))
            else (
              let pending_result =
                match
                  List.filter_map
                    (fun (key, value) ->
                       if String.equal key "pending_input" then Some value else None)
                    fields
                with
                | [] | [ `Null ] -> Ok None
                | [ value ] ->
                  Agent_core.Agent_input_request.pending_of_json value
                  |> Result.map Option.some
                | _ :: _ :: _ ->
                  Error "duplicate pending_input field in superseded checkpoint"
              in
              match pending_result with
              | Error detail -> parse_error detail
              | Ok pending_input ->
                Ok
                  (Retained_superseded
                     { reference
                     ; expected_version = expected
                     ; got_version = got
                     ; pending_input
                     })))
       | None, (Some _ | None) | Some _, None ->
         parse_error
           "superseded retained checkpoint is missing canonical session_id or turn_count")
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      parse_error "superseded retained checkpoint must be a JSON object")

let read_retained_snapshot_locked ~session_dir ~reference =
  match
    Fs_compat.load_owned_regular_file
      ~ownership_root:(Filename.dirname session_dir)
      (retained_checkpoint_path ~session_dir reference)
  with
  | Error error ->
    Error
      (Source_unavailable
         (Ref_read_failed
            (Store_error (Fs_compat.owned_regular_file_read_error_to_string error))))
  | Ok None -> Error (Source_unavailable Ref_not_found)
  | Ok (Some bytes) ->
    (match
       exact_snapshot_of_head_bytes
         ~session_dir
         ~expected_session_id:reference.Keeper_checkpoint_ref.trace_id
         bytes
     with
     | Ok snapshot when Keeper_checkpoint_ref.equal reference snapshot.reference ->
       Ok (Retained_current snapshot)
     | Ok snapshot -> Error (Source_changed snapshot.reference)
     | Error (Ref_read_failed (Superseded_version { expected; got })) ->
       decode_superseded_retained_bytes ~reference ~expected ~got bytes
     | Error
         ( Ref_read_failed
             ( Not_found
             | Newer_version _
             | Parse_error _
             | Store_error _
             | Io_error _
             | Read_failed _
             | Agent_core_error _
             | Objects_invalid _ )
         | Ref_not_found
         | Ref_identity_invalid _
         | Ref_session_mismatch _
         | Ref_lock_failed _ as error ) -> Error (Source_unavailable error))

let load_retained_snapshot ~session_dir ~reference =
  match
    with_session_lock ~session_dir (fun session_dir ->
      read_retained_snapshot_locked ~session_dir ~reference)
  with
  | Ok result -> result
  | Error detail -> Error (Source_unavailable (Ref_lock_failed detail))

let find_exact_snapshot_for_retention ~session_dir ~reference =
  let unavailable detail = Source_unavailable (Ref_read_failed (Io_error detail)) in
  match with_session_lock ~session_dir (fun session_dir ->
    match read_retained_locked ~session_dir ~reference with
    | Ok (Some snapshot) -> Ok snapshot
    | Error _ as error -> error
    | Ok None ->
      Cancel_safe.protect ~on_exn:(fun exn -> Error (unavailable (Printexc.to_string exn))) (fun () ->
        let paths = agent_core_checkpoint_path ~session_dir
          ~session_id:(Keeper_id.Trace_id.to_string reference.Keeper_checkpoint_ref.trace_id)
          :: (list_agent_core_history_files ~session_dir |> List.map (Filename.concat session_dir)) in
        let rec find = function
          | [] -> Error (Source_unavailable Ref_not_found)
          | path :: rest ->
            (match Fs_compat.load_owned_regular_file ~ownership_root:(Filename.dirname session_dir) path with
             | Error error -> Error (unavailable (Fs_compat.owned_regular_file_read_error_to_string error))
             | Ok None -> find rest
             | Ok (Some bytes) ->
               (* A head names its content digest without an object read, so
                  only the head that names this reference is loaded. *)
               (match head_of_bytes_off_scheduler bytes with
                | Error (_ : Objects.load_error) -> find rest
                | Ok head
                  when not (String.equal (Objects.head_content_digest head :> string) reference.sha256) ->
                  find rest
                | Ok _ ->
                  (match exact_snapshot_of_head_bytes ~session_dir ~expected_session_id:reference.trace_id bytes with
                   | Error error -> Error (Source_unavailable error)
                   | Ok snapshot when Keeper_checkpoint_ref.equal reference snapshot.reference -> Ok snapshot
                   | Ok snapshot -> Error (Source_changed snapshot.reference)))) in
        find paths)) with
  | Ok result -> result
  | Error detail -> Error (Source_unavailable (Ref_lock_failed detail))

let retain_exact_snapshot_with ~write_checkpoint_bytes ~session_dir snapshot =
  let installed = ref None in
  let publish auxiliary =
    let value = { installed_ref = snapshot.reference; auxiliary } in
    installed := Some value;
    Installed value
  in
  (* This observer runs after all fsyncs but before pending cancellation. It
     preserves the committed fact if cancellation interrupts the lock unwind. *)
  let observe_commit () =
    installed := Some { installed_ref = snapshot.reference; auxiliary = [] }
  in
  let recover_unwind exn backtrace =
    match !installed with
    | None -> Printexc.raise_with_backtrace exn backtrace
    | Some value -> Installed
        { value with auxiliary = value.auxiliary @
            [Post_commit_unwind_interrupted (exn, backtrace)] }
  in
  try
    with_checkpoint_cas_lock ~session_dir (fun session_dir ->
      match read_retained_locked ~session_dir ~reference:snapshot.reference with
      | Error cause -> not_installed cause
      | Ok (None | Some _) ->
          (* The retained head shares the canonical's objects; its open
             messages are written as objects of their own. *)
          match plan_for_session ~session_dir ~boundary:Objects.Turn_continues snapshot.checkpoint with
          | Error error -> not_installed (Candidate_unencodable error)
          | Ok plan when not (String.equal (plan.content :> string) snapshot.reference.sha256) ->
              not_installed
                (Candidate_content_mismatch
                   { reference = snapshot.reference; content = (plan.content :> string) })
          | Ok plan ->
          match Keeper_checkpoint_object_store.write ~session_dir plan.objects with
          | Error error -> not_installed (Objects_not_installed error)
          | Ok (_ : int) ->
          match write_checkpoint_bytes
                  ~on_durable_commit:observe_commit
                  ~ownership_root:(Filename.dirname session_dir)
                  ~path:(retained_checkpoint_path ~session_dir snapshot.reference)
                  ~bytes:plan.head_bytes with
          | Error error when error.Keeper_fs.renamed ->
              publish [Commit_durability_unknown error]
          | Error error -> not_installed (Commit_not_installed error)
          | Ok Keeper_fs.Committed -> publish []
          | Ok (Keeper_fs.Committed_but_observer_failed failure) ->
              publish [Commit_observer_failed failure])
  with
  | Eio.Cancel.Cancelled _ as exn ->
      recover_unwind exn (Printexc.get_raw_backtrace ())
  | exn -> recover_unwind exn (Printexc.get_raw_backtrace ())

let retain_exact_snapshot ~session_dir snapshot =
  retain_exact_snapshot_with ~write_checkpoint_bytes ~session_dir snapshot

type release_failure =
  | Lock_held_elsewhere
  | Release_failed of string

let release_retained ~session_root released =
  let reference = Keeper_chat_operation_store.released_reference released in
  let unlink session_dir =
    let retained_dir = Filename.concat session_dir retained_dirname in
    let path = retained_checkpoint_path ~session_dir reference in
    let unlink () =
      match Fs_compat.inspect_owned_directory_chain
              ~ownership_root:(Filename.dirname session_dir) retained_dir with
      | Error rejection -> Error (Fs_compat.owned_directory_chain_rejection_to_string rejection)
      | Ok Fs_compat.Owned_directory_missing -> Ok ()
      | Ok (Fs_compat.Owned_directory _) ->
        (match Unix.lstat path with
         | { Unix.st_kind = Unix.S_REG; _ } -> Unix.unlink path; Ok ()
         | { Unix.st_kind = (Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK
                            | Unix.S_FIFO | Unix.S_SOCK) as kind; _ } ->
           Error (Printf.sprintf "%s is a %s, not a retained checkpoint"
                    path (Fs_compat.file_kind_to_string kind))
         | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ())
    in
    match Eio_guard.run_in_systhread ~label:"keeper.checkpoint.retained.release" unlink with
    | result -> result
    | exception (Unix.Unix_error _ as exn) -> Error (Printexc.to_string exn)
  in
  let session_dir = Keeper_chat_operation_store.released_session_dir ~session_root released in
  match canonical_session_location session_dir with
  | Error error -> Error (Release_failed (save_agent_core_error_to_string error))
  | Ok session_dir ->
    (* The same lock file retention and exact reads take, tried once. *)
    match File_lock_eio.try_with_durable_lock_observed
            ~lock_path:(session_dir ^ ".checkpoint.lock") (fun () -> unlink session_dir) with
    | File_lock_eio.Lock_held_elsewhere -> Error Lock_held_elsewhere
    | File_lock_eio.Lock_attempted (File_lock_eio.Lock_not_acquired error) ->
      Error (Release_failed (File_lock_eio.durable_lock_error_to_string error))
    | File_lock_eio.Lock_attempted (File_lock_eio.Body_completed { value = Error detail; _ }) ->
      Error (Release_failed detail)
    | File_lock_eio.Lock_attempted
        (File_lock_eio.Body_completed { value = Ok (); release_error = Some error }) ->
      Error (Release_failed ("removed, but the checkpoint lock was not released: "
                             ^ File_lock_eio.durable_lock_error_to_string error))
    | File_lock_eio.Lock_attempted
        (File_lock_eio.Body_completed { value = Ok (); release_error = None }) -> Ok ()
