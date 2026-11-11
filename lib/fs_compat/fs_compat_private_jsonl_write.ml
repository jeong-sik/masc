open Fs_compat_durable_append
open Fs_compat_private_jsonl_transaction

module Private_jsonl_absence = struct
  type error =
    | Binding_refused of private_jsonl_transaction_error
    | Operation_failed of private_jsonl_operation_failure

  (* An existing-file open can return ENOENT for a dangling leaf symlink.
     Only actual leaf absence can support the caller's Missing observation. *)
  let check path =
    match private_jsonl_capture Inspect_transaction_path (fun () ->
      match Unix.lstat path with
      | stats -> Some stats
      | exception Unix.Unix_error (Unix.ENOENT, _, _) -> None) with
    | Error failure -> Error (Operation_failed failure)
    | Ok None -> Ok ()
    | Ok (Some stats) ->
      let error = if stats.Unix.st_kind <> Unix.S_REG
        then Unexpected_transaction_file_kind stats.Unix.st_kind
        else Transaction_path_binding_changed { path } in
      Error (Binding_refused error)
end

let private_jsonl_open_existing ~close_fd path flags =
  (* The type check below needs an opened descriptor. Without O_NONBLOCK,
     opening a FIFO for reading can wait forever before we can reject it. *)
  match Unix.openfile path (Unix.O_CLOEXEC :: Unix.O_NONBLOCK :: flags) 0 with
  | fd ->
    (match
       private_jsonl_validate_open_binding
         ~operation:Inspect_transaction_path
         ~path
         fd
     with
     | Ok () -> Ok (Some fd)
     | Error error ->
       (match private_jsonl_capture Close_transaction_data (fun () -> close_fd fd) with
        | Ok () -> Error error
        | Error cleanup_failure ->
          Error (private_jsonl_add_cleanup_failure error cleanup_failure)))
  | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
    (match Private_jsonl_absence.check path with
     | Ok () -> Ok None
     | Error (Private_jsonl_absence.Binding_refused error) -> Error error
     | Error (Private_jsonl_absence.Operation_failed failure) ->
       Error (Private_jsonl_operation_failed failure))
  | exception (Eio.Cancel.Cancelled _ as cancellation) -> raise cancellation
  | exception exception_ ->
    Error
      (Private_jsonl_operation_failed
         (private_jsonl_failure Open_transaction_data exception_))
;;

let purge_private_jsonl_durable_locked_with_io ~io path =
  let success cursor = Cursor_succeeded cursor in
  with_private_jsonl_stable_lock ~io ~success path @@ fun ~dir ~path ->
  let open Result.Syntax in
  let sync_removed () =
    let* () =
      private_jsonl_capture Sync_removal_parent (fun () ->
        io.before_sync_parent dir;
        fsync_parent_directory dir)
      |> Result.map_error (fun failure -> Private_jsonl_operation_failed failure)
    in
    Ok Private_jsonl_cursor.Missing
  in
  let* opened =
    private_jsonl_open_existing ~close_fd:io.close_fd path
      [ Unix.O_RDONLY ]
  in
  match opened with
  | None -> sync_removed ()
  | Some fd ->
    private_jsonl_with_fd ~close_operation:Close_transaction_data
      ~close_fd:io.close_fd ~success fd (fun () ->
        let* () =
          private_jsonl_validate_open_binding
            ~operation:Inspect_transaction_path
            ~path
            fd
        in
        let* () =
          private_jsonl_capture Remove_transaction_data (fun () -> Unix.unlink path)
          |> Result.map_error (fun failure -> Private_jsonl_operation_failed failure)
        in
        sync_removed ())
;;

let purge_private_jsonl_durable_locked_result path =
  purge_private_jsonl_durable_locked_with_io ~io:private_jsonl_transaction_unix_io path
;;

let purge_private_jsonl_durable_locked_with_io_for_testing =
  purge_private_jsonl_durable_locked_with_io
;;

let rec private_jsonl_read_byte fd byte offset =
  (* See POSIX lseek: no exception confirms the requested absolute offset. *)
  ignore (Unix.lseek fd offset Unix.SEEK_SET : int);
  match Unix.read fd byte 0 1 with
  | 1 -> Bytes.get byte 0
  | 0 -> raise End_of_file
  | count ->
    invalid_arg (Printf.sprintf "single-byte JSONL read returned %d bytes" count)
  | exception Unix.Unix_error (Unix.EINTR, _, _) ->
    private_jsonl_read_byte fd byte offset
;;

let private_jsonl_validate_complete_tail fd end_offset =
  if end_offset = 0
  then Ok ()
  else
    match private_jsonl_capture Read_transaction_data (fun () ->
      let byte = Bytes.create 1 in
      Char.equal (private_jsonl_read_byte fd byte (end_offset - 1)) '\n')
    with
    | Error failure -> Error (Private_jsonl_operation_failed failure)
    | Ok true -> Ok ()
    | Ok false -> Error (Incomplete_transaction_tail { end_offset })
;;

let private_jsonl_read_exact fd ~from ~end_offset =
  private_jsonl_capture Read_transaction_data (fun () ->
    let length = end_offset - from in
    let bytes = Bytes.create length in
    (* See POSIX lseek: no exception confirms the requested absolute cursor. *)
    ignore (Unix.lseek fd from Unix.SEEK_SET : int);
    let rec read_all offset =
      if offset = length
      then ()
      else
        match Unix.read fd bytes offset (length - offset) with
        | 0 -> raise End_of_file
        | count -> read_all (offset + count)
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> read_all offset
    in
    read_all 0;
    Bytes.unsafe_to_string bytes)
  |> Result.map_error (fun failure -> Private_jsonl_operation_failed failure)
;;

(* Every participant must retain and use the same stable sibling lock. The
   snapshot binds both a physical replacement and a same-inode payload edit;
   POSIX unlink itself is not an atomic compare-and-unlink against rogue actors
   that bypass this process-owned-directory protocol. *)
let purge_private_jsonl_durable_locked_at_snapshot_with_io ~io path
    ~(expected : private_jsonl_snapshot) =
  let success cursor = Cursor_succeeded cursor in
  with_private_jsonl_stable_lock ~io ~success path @@ fun ~dir ~path ->
  let open Result.Syntax in
  let capture operation f = private_jsonl_capture operation f
    |> Result.map_error (fun failure -> Private_jsonl_operation_failed failure) in
  let sync_removed () =
    let* () = capture Sync_removal_parent (fun () ->
      io.before_sync_parent dir; fsync_parent_directory dir) in
    Ok Private_jsonl_cursor.Missing in
  let* opened = private_jsonl_open_existing ~close_fd:io.close_fd path
      [Unix.O_RDONLY] in
  match opened with
  | None -> sync_removed ()
  | Some fd ->
    private_jsonl_with_fd ~close_operation:Close_transaction_data
      ~close_fd:io.close_fd ~success fd (fun () ->
        let* stats = capture Inspect_transaction_data (fun () -> Unix.fstat fd) in
        let* actual = private_jsonl_cursor_of_stats stats in
        let* () = if Private_jsonl_cursor.equal expected.cursor actual then Ok ()
          else Error (Cursor_mismatch {expected=expected.cursor;actual}) in
        let* bytes = private_jsonl_read_exact fd ~from:0 ~end_offset:stats.Unix.st_size in
        let* () = if String.equal expected.bytes bytes then Ok ()
          else Error (Transaction_content_changed {path}) in
        let* () = private_jsonl_validate_open_binding
            ~operation:Inspect_transaction_path ~path fd in
        let* () = capture Remove_transaction_data (fun () -> Unix.unlink path) in
        sync_removed ())
;;

let purge_private_jsonl_durable_locked_at_snapshot_result path ~expected =
  purge_private_jsonl_durable_locked_at_snapshot_with_io
    ~io:private_jsonl_transaction_unix_io path ~expected
;;

let purge_private_jsonl_durable_locked_at_snapshot_with_io_for_testing =
  purge_private_jsonl_durable_locked_at_snapshot_with_io
;;

let read_private_jsonl_snapshot_locked ~io path ~after =
  let success snapshot = Snapshot_succeeded snapshot in
  match private_jsonl_open_existing ~close_fd:io.close_fd path [ Unix.O_RDONLY ] with
  | Error _ as error -> error
  | Ok None ->
    let actual = Private_jsonl_cursor.Missing in
    (match after with
     | None -> Ok { bytes = ""; cursor = actual }
     | Some expected ->
       if Private_jsonl_cursor.equal expected actual
       then Ok { bytes = ""; cursor = actual }
       else Error (Cursor_mismatch { expected; actual }))
  | Ok (Some fd) ->
    private_jsonl_with_fd
      ~close_operation:Close_transaction_data
      ~close_fd:io.close_fd
      ~success
      fd
      (fun () ->
         match private_jsonl_capture Inspect_transaction_data (fun () -> Unix.fstat fd)
         with
         | Error failure -> Error (Private_jsonl_operation_failed failure)
         | Ok stats ->
           (match private_jsonl_cursor_of_stats stats with
            | Error _ as error -> error
            | Ok actual ->
              (match private_jsonl_validate_complete_tail fd stats.Unix.st_size with
               | Error _ as error -> error
               | Ok () ->
                 let from =
                   match after with
                   | None -> Ok 0
                   | Some expected ->
                     (match
                        Private_jsonl_cursor.prefix_end_offset
                          expected
                          ~device:stats.Unix.st_dev
                          ~inode:stats.Unix.st_ino
                          ~file_length:stats.Unix.st_size
                      with
                      | Some end_offset -> Ok end_offset
                      | None -> Error (Cursor_mismatch { expected; actual }))
                 in
                 (match from with
                  | Error _ as error -> error
                  | Ok from ->
                    private_jsonl_read_exact
                      fd
                      ~from
                      ~end_offset:stats.Unix.st_size
                    |> Result.map (fun bytes -> { bytes; cursor = actual })))))
;;

let read_private_jsonl_durable_locked_with_io ~io path ~after =
  let success snapshot = Snapshot_succeeded snapshot in
  with_private_jsonl_stable_lock ~io ~success path @@ fun ~dir:_ ~path ->
  read_private_jsonl_snapshot_locked ~io path ~after
;;

let read_private_jsonl_durable_locked_result path ~after =
  read_private_jsonl_durable_locked_with_io
    ~io:private_jsonl_transaction_unix_io
    path
    ~after
;;

let private_jsonl_last_complete_row_length bytes =
  match String.rindex_opt bytes '\n' with
  | Some index -> index + 1
  | None -> 0
;;

(* Called only under the stable sibling lock, with a writable descriptor.
   Reads the complete store and truncates an incomplete final row. The stable
   append calls it when no cursor is expected; an append at an expected cursor
   and general readers never truncate. *)
let private_jsonl_recover_snapshot fd =
  let open Result.Syntax in
  let capture operation f =
    private_jsonl_capture operation f
    |> Result.map_error (fun failure -> Private_jsonl_operation_failed failure)
  in
  let* stats = capture Inspect_transaction_data (fun () -> Unix.fstat fd) in
  let* actual = private_jsonl_cursor_of_stats stats in
  match private_jsonl_validate_complete_tail fd stats.Unix.st_size with
  | Ok () ->
    private_jsonl_read_exact fd ~from:0 ~end_offset:stats.Unix.st_size
    |> Result.map (fun bytes -> { bytes; cursor = actual })
  | Error (Incomplete_transaction_tail { end_offset }) ->
    let* bytes = private_jsonl_read_exact fd ~from:0 ~end_offset in
    let complete_length = private_jsonl_last_complete_row_length bytes in
    let* () = capture Truncate_transaction_data (fun () ->
      Unix.ftruncate fd complete_length) in
    let* () = capture Sync_transaction_data (fun () -> Unix.fsync fd) in
    let* truncated_stats = capture Inspect_transaction_data (fun () -> Unix.fstat fd) in
    let* cursor = private_jsonl_cursor_of_stats truncated_stats in
    Ok { bytes = String.sub bytes 0 complete_length; cursor }
  (* Recovery is scoped to [Incomplete_transaction_tail]; every other typed
     failure propagates exactly as the general read path surfaces it. *)
  | Error
      ( Stable_lock_contended _
      | Unexpected_stable_lock_permissions _
      | Invalid_stable_lock_state _
      | Cursor_mismatch _
      | Unexpected_transaction_file_kind _
      | Ambiguous_transaction_file_identity _
      | Transaction_path_binding_changed _
      | Transaction_content_changed _
      | Invalid_transaction_suffix
      | Private_jsonl_operation_failed _
      | Rewrite_stage_failed _
      | Rewrite_published_durability_unknown _
      | Transaction_settlement_failed _
      | Transaction_append_failed _ ) as error -> error
;;

let recover_private_jsonl_durable_locked_with_io ~io path =
  let success snapshot = Snapshot_succeeded snapshot in
  with_private_jsonl_stable_lock ~io ~success path @@ fun ~dir:_ ~path ->
  match private_jsonl_open_existing ~close_fd:io.close_fd path [ Unix.O_RDWR ] with
  | Error _ as error -> error
  | Ok None -> Ok { bytes = ""; cursor = Private_jsonl_cursor.Missing }
  | Ok (Some fd) ->
    private_jsonl_with_fd
      ~close_operation:Close_transaction_data
      ~close_fd:io.close_fd
      ~success
      fd
      (fun () -> private_jsonl_recover_snapshot fd)
;;

let recover_private_jsonl_durable_locked_result path =
  recover_private_jsonl_durable_locked_with_io
    ~io:private_jsonl_transaction_unix_io
    path
;;

let read_private_jsonl_durable_locked_with_io_for_testing ~io path ~after =
  read_private_jsonl_durable_locked_with_io ~io path ~after
;;

let private_jsonl_current_cursor ~io path =
  let success cursor = Cursor_precondition_succeeded cursor in
  match private_jsonl_open_existing ~close_fd:io.close_fd path [ Unix.O_RDONLY ] with
  | Error _ as error -> error
  | Ok None -> Ok Private_jsonl_cursor.Missing
  | Ok (Some fd) ->
    private_jsonl_with_fd
      ~close_operation:Close_transaction_data
      ~close_fd:io.close_fd
      ~success
      fd
      (fun () ->
         match private_jsonl_capture Inspect_transaction_data (fun () -> Unix.fstat fd)
         with
         | Error failure -> Error (Private_jsonl_operation_failed failure)
         | Ok stats ->
           (match private_jsonl_cursor_of_stats stats with
            | Error _ as error -> error
            | Ok cursor ->
              private_jsonl_validate_complete_tail fd stats.Unix.st_size
              |> Result.map (fun () -> cursor)))
;;

let private_jsonl_remove_rewrite_stage temp_path =
  match private_jsonl_capture Remove_rewrite_stage (fun () -> Unix.unlink temp_path) with
  | Ok () -> None
  | Error failure ->
    (match failure.exception_ with
     | Unix.Unix_error (error, _, _) when error = Unix.ENOENT -> None
     (* DET-OK: [exn] is open. Every non-ENOENT cleanup exception is preserved
        as typed failure evidence; this arm never chooses a permissive default. *)
     | _ -> Some failure)
;;

let private_jsonl_replace_locked ?before_sync_rewrite_parent ~dir path content =
  match private_jsonl_capture Create_rewrite_stage (fun () ->
    (* Open_binary for the same reason as [Atomic_replace.open_atomic_temp_file]:
       the stage file holds the replacement bytes verbatim. *)
    Filename.open_temp_file
      ~mode:[ Open_binary ]
      ~temp_dir:dir
      ".private_jsonl_"
      ".stage")
  with
  | Error failure -> Error (Private_jsonl_operation_failed failure)
  | Ok (temp_path, output) ->
    let descriptor = Unix.descr_of_out_channel output in
    let first_failure = ref None in
    let run_until_failure operation f =
      match !first_failure with
      | Some _ -> ()
      | None ->
        (match private_jsonl_capture operation f with
         | Ok () -> ()
         | Error failure -> first_failure := Some failure)
    in
    run_until_failure Set_rewrite_stage_permissions (fun () ->
      Unix.fchmod descriptor 0o600);
    run_until_failure Write_rewrite_stage (fun () ->
      output_string output content;
      flush output);
    run_until_failure Sync_rewrite_stage (fun () -> Unix.fsync descriptor);
    let operation_failure = !first_failure in
    let close_failure =
      match private_jsonl_capture Close_rewrite_stage (fun () -> close_out output) with
      | Ok () -> None
      | Error failure -> Some failure
    in
    (match operation_failure, close_failure with
     | Some failure, close_failure ->
       let cleanup_failures =
         [ close_failure; private_jsonl_remove_rewrite_stage temp_path ]
         |> List.filter_map Fun.id
       in
       Error (Rewrite_stage_failed { failure; cleanup_failures })
     | None, Some failure ->
       let cleanup_failures =
         private_jsonl_remove_rewrite_stage temp_path |> Option.to_list
       in
       Error (Rewrite_stage_failed { failure; cleanup_failures })
     | None, None ->
       (match private_jsonl_capture Rename_rewrite_stage (fun () ->
          Unix.rename temp_path path)
        with
        | Error failure ->
          let cleanup_failures =
            private_jsonl_remove_rewrite_stage temp_path |> Option.to_list
          in
          Error (Rewrite_stage_failed { failure; cleanup_failures })
        | Ok () ->
          (match private_jsonl_capture Inspect_rewritten_data (fun () ->
             Unix.lstat path)
           with
           | Error failure ->
             Error
               (Rewrite_published_durability_unknown
                  { cursor = None; failure })
           | Ok stats ->
             (match private_jsonl_cursor_of_stats stats with
              | Error error ->
                let failure =
                  private_jsonl_failure
                    Inspect_rewritten_data
                    (Failure (private_jsonl_transaction_error_to_string error))
                in
                Error
                  (Rewrite_published_durability_unknown
                     { cursor = None; failure })
              | Ok cursor ->
                (match private_jsonl_capture Sync_rewrite_parent (fun () ->
                   Option.iter (fun before_sync -> before_sync dir)
                     before_sync_rewrite_parent;
                   fsync_parent_directory dir)
                 with
                 | Ok () -> Ok cursor
                 | Error failure ->
                   Error
                     (Rewrite_published_durability_unknown
                        { cursor = Some cursor; failure }))))))
;;

type private_jsonl_append_observation =
  { before : Unix.stats; after : Unix.stats; suffix : string }

type private_jsonl_append_precondition =
  | Append_without_precondition
  | Append_at_cursor of Private_jsonl_cursor.t
  | Append_at_snapshot of private_jsonl_snapshot

let append_private_jsonl_locked_with_io
      ?(observe=ignore) ~io ~dir path ~precondition suffix =
  if String.equal suffix ""
     || not (Char.equal suffix.[String.length suffix - 1] '\n')
  then Error Invalid_transaction_suffix
  else
    let open Result.Syntax in
    let success cursor = Cursor_succeeded cursor in
    let check_cursor actual =
      let expected = match precondition with
        | Append_without_precondition -> None
        | Append_at_cursor cursor -> Some cursor
        | Append_at_snapshot snapshot -> Some snapshot.cursor in
      match expected with
      | Some expected when not (Private_jsonl_cursor.equal expected actual) ->
        Error (Cursor_mismatch { expected; actual })
      | None | Some _ -> Ok ()
    in
    let* existing =
      private_jsonl_open_existing
        ~close_fd:io.close_fd path [ Unix.O_RDWR; Unix.O_APPEND ]
    in
    match existing with
    | None ->
      let* () = check_cursor Private_jsonl_cursor.Missing in
      let* () = match precondition with
        | Append_at_snapshot snapshot when not (String.equal snapshot.bytes "") ->
          Error (Transaction_content_changed { path })
        | Append_without_precondition | Append_at_cursor _ | Append_at_snapshot _ -> Ok () in
      private_jsonl_replace_locked ~dir path suffix
    | Some fd ->
      private_jsonl_with_fd
        ~close_operation:Close_transaction_data
        ~close_fd:io.close_fd
        ~success
        fd
        (fun () ->
           let capture operation f =
             private_jsonl_capture operation f
             |> Result.map_error (fun failure -> Private_jsonl_operation_failed failure)
           in
           let* stats = capture Inspect_transaction_data (fun () -> Unix.fstat fd) in
           let* actual = private_jsonl_cursor_of_stats stats in
           let* () = check_cursor actual in
           let* append_from =
             match private_jsonl_validate_complete_tail fd stats.Unix.st_size with
             | Ok () -> Ok stats.Unix.st_size
             | Error (Incomplete_transaction_tail _ as error) ->
               (match precondition with
                | Append_at_cursor _ | Append_at_snapshot _ -> Error error
                | Append_without_precondition ->
                  private_jsonl_recover_snapshot fd
                  |> Result.map (fun snapshot -> String.length snapshot.bytes))
             | Error
                 (( Stable_lock_contended _
                 | Unexpected_stable_lock_permissions _
                 | Invalid_stable_lock_state _
                 | Cursor_mismatch _
                 | Unexpected_transaction_file_kind _
                 | Ambiguous_transaction_file_identity _
                 | Transaction_path_binding_changed _
                 | Transaction_content_changed _
                 | Invalid_transaction_suffix
                 | Private_jsonl_operation_failed _
                 | Rewrite_stage_failed _
                 | Rewrite_published_durability_unknown _
                 | Transaction_settlement_failed _
                 | Transaction_append_failed _ ) as error) -> Error error
           in
           let* () = match precondition with
             | Append_without_precondition | Append_at_cursor _ -> Ok ()
             | Append_at_snapshot expected ->
               let* bytes = private_jsonl_read_exact fd ~from:0 ~end_offset:stats.Unix.st_size in
               if not (String.equal expected.bytes bytes)
               then Error (Transaction_content_changed { path })
               else private_jsonl_validate_open_binding
                   ~operation:Inspect_transaction_path ~path fd in
           let* () = capture Set_transaction_data_permissions (fun () ->
             Unix.fchmod fd 0o600) in
           (* See POSIX lseek: O_APPEND owns writes; this resets reads. *)
           ignore (Unix.lseek fd 0 Unix.SEEK_END : int);
           let* () =
             append_fd_durable ~io:durable_append_unix_io ~fd
               ~original_length:append_from suffix
             |> Result.map_error (fun error -> Transaction_append_failed error)
           in
           let* committed_stats = capture Inspect_transaction_data (fun () -> Unix.fstat fd) in
           let* cursor = private_jsonl_cursor_of_stats committed_stats in
           observe {before=stats;after=committed_stats;suffix};
           Ok cursor)
;;

let append_private_jsonl_durable_stable_with_io
      ?(observe=ignore) ~io path ~precondition suffix =
  if String.equal suffix ""
     || not (Char.equal suffix.[String.length suffix - 1] '\n')
  then Error Invalid_transaction_suffix
  else
    with_private_jsonl_stable_lock ~io ~success:(fun cursor -> Cursor_succeeded cursor)
      path (fun ~dir ~path ->
        append_private_jsonl_locked_with_io ~observe ~io ~dir path ~precondition suffix)
;;

let append_private_jsonl_snapshot_locked ~io ~dir path ~expected suffix =
  append_private_jsonl_locked_with_io ~io ~dir path
    ~precondition:(Append_at_snapshot expected) suffix
;;

let append_private_jsonl_durable_stable_result path suffix =
  append_private_jsonl_durable_stable_with_io
    ~io:private_jsonl_transaction_unix_io path ~precondition:Append_without_precondition suffix
;;

let append_private_jsonl_durable_observed_result path suffix =
  let observation = ref None in
  append_private_jsonl_durable_stable_with_io
    ~observe:(fun value -> observation := Some value)
    ~io:private_jsonl_transaction_unix_io path ~precondition:Append_without_precondition suffix
  |> Result.map (fun cursor -> cursor, !observation)
;;

let append_private_jsonl_durable_locked_at_cursor_result path ~expected suffix =
  append_private_jsonl_durable_stable_with_io
    ~io:private_jsonl_transaction_unix_io path ~precondition:(Append_at_cursor expected) suffix
;;

let append_private_jsonl_durable_locked_at_cursor_with_io_for_testing
      ~io path ~expected suffix
  =
  append_private_jsonl_durable_stable_with_io
    ~io path ~precondition:(Append_at_cursor expected) suffix
;;

let append_private_jsonl_durable_locked_at_snapshot_result path ~expected suffix =
  append_private_jsonl_durable_stable_with_io
    ~io:private_jsonl_transaction_unix_io path ~precondition:(Append_at_snapshot expected) suffix
;;

let append_private_jsonl_durable_locked_at_snapshot_with_io_for_testing
      ~io path ~expected suffix =
  append_private_jsonl_durable_stable_with_io
    ~io path ~precondition:(Append_at_snapshot expected) suffix
;;

let rewrite_private_jsonl_durable_locked_at_cursor_with_io
      ~io
      path
      ~expected
      content
  =
  if not (String.equal content "")
     && not (Char.equal content.[String.length content - 1] '\n')
  then Error Invalid_transaction_suffix
  else
    with_private_jsonl_stable_lock
      ~io
      ~success:(fun cursor -> Cursor_succeeded cursor)
      path
    @@ fun ~dir ~path ->
    match private_jsonl_current_cursor ~io path with
    | Error _ as error -> error
    | Ok actual ->
      if not (Private_jsonl_cursor.equal expected actual)
      then Error (Cursor_mismatch { expected; actual })
      else private_jsonl_replace_locked ~dir path content
;;

let rewrite_private_jsonl_durable_locked_at_cursor_result
      path
      ~expected
      content
  =
  rewrite_private_jsonl_durable_locked_at_cursor_with_io
    ~io:private_jsonl_transaction_unix_io
    path
    ~expected
    content
;;

let rewrite_private_jsonl_durable_locked_at_cursor_with_io_for_testing
      ~io
      path
      ~expected
      content
  =
  rewrite_private_jsonl_durable_locked_at_cursor_with_io
    ~io
    path
    ~expected
    content
;;

(* A cursor can repeat after an inode is recycled. Compare the full observed
   bytes under the stable sibling lock before replacing the current store. *)
let rewrite_private_jsonl_durable_locked_at_snapshot_with_io
      ?before_sync_rewrite_parent ~io path ~(expected : private_jsonl_snapshot) content =
  if not (String.equal content "")
     && not (Char.equal content.[String.length content - 1] '\n')
  then Error Invalid_transaction_suffix
  else
    let success cursor = Cursor_succeeded cursor in
    with_private_jsonl_stable_lock ~io ~success path @@ fun ~dir ~path ->
    let open Result.Syntax in
    let* opened = private_jsonl_open_existing ~close_fd:io.close_fd path [Unix.O_RDONLY] in
    match opened with
    | None ->
      let actual = Private_jsonl_cursor.Missing in
      if not (Private_jsonl_cursor.equal expected.cursor actual)
      then Error (Cursor_mismatch { expected = expected.cursor; actual })
      else if not (String.equal expected.bytes "") then Error (Transaction_content_changed { path })
      else private_jsonl_replace_locked ?before_sync_rewrite_parent ~dir path content
    | Some fd ->
      private_jsonl_with_fd ~close_operation:Close_transaction_data ~close_fd:io.close_fd ~success fd (fun () ->
        let* stats = private_jsonl_capture Inspect_transaction_data (fun () -> Unix.fstat fd)
          |> Result.map_error (fun failure -> Private_jsonl_operation_failed failure) in
        let* actual = private_jsonl_cursor_of_stats stats in
        let* () = if Private_jsonl_cursor.equal expected.cursor actual then Ok ()
          else Error (Cursor_mismatch { expected = expected.cursor; actual }) in
        let* () = private_jsonl_validate_complete_tail fd stats.Unix.st_size in
        let* bytes = private_jsonl_read_exact fd ~from:0 ~end_offset:stats.Unix.st_size in
        let* () = if String.equal expected.bytes bytes then Ok () else Error (Transaction_content_changed { path }) in
        let* () = private_jsonl_validate_open_binding ~operation:Inspect_transaction_path ~path fd in
        private_jsonl_replace_locked ?before_sync_rewrite_parent ~dir path content)
;;

let rewrite_private_jsonl_durable_locked_at_snapshot_result path ~expected content =
  rewrite_private_jsonl_durable_locked_at_snapshot_with_io
    ~io:private_jsonl_transaction_unix_io path ~expected content
;;

let rewrite_private_jsonl_durable_locked_at_snapshot_with_io_for_testing
      ?before_sync_rewrite_parent ~io path ~expected content =
  rewrite_private_jsonl_durable_locked_at_snapshot_with_io
    ?before_sync_rewrite_parent ~io path ~expected content
;;
