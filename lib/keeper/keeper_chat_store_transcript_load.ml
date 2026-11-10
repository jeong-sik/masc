open Keeper_chat_types
open Keeper_chat_store_paths
open Keeper_chat_store_redaction
open Keeper_chat_store_line_decode
open Keeper_chat_store_history_window
open Keeper_chat_store_transcript_rows

let purge_transcript path ~remove =
  Keeper_chat_store_transcript_index.purge_indexed_transcript path ~remove:(fun path ->
    Fun.protect ~finally:(fun () -> forget_transcript path) (fun () -> remove path))
;;

let load_transcript_fully ~path ~redaction =
  let before = transcript_identity path in
  match Fs_compat.read_private_jsonl_rows_locked_result path with
  | Private_file_succeeded Fs_compat.Private_jsonl_rows.Rows_missing
  | Private_file_succeeded_with_cleanup_failure
      { value = Fs_compat.Private_jsonl_rows.Rows_missing; _ } ->
    forget_transcript path;
    []
  | Private_file_succeeded
      (Fs_compat.Private_jsonl_rows.Rows_present { rows; rows_end; end_offset = _ })
  | Private_file_succeeded_with_cleanup_failure
      { value =
          Fs_compat.Private_jsonl_rows.Rows_present { rows; rows_end; end_offset = _ }
      ; _
      } ->
    let messages =
      Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
        parse_transcript_rows ~path ~redaction rows)
    in
    (* Register only when the file the rows came from is the one statted
       before the read: a replacement between the two would pair a new
       identity with old rows, and the next load would append to it. *)
    (match before, transcript_identity path with
     | Some (device, inode, _), Some (device', inode', _)
       when device = device' && inode = inode' ->
       remember_transcript
         path
         { device; inode; parsed_end = rows_end; messages_rev = List.rev messages; redaction }
     | Some _, Some _ | Some _, None | None, Some _ | None, None -> forget_transcript path);
    messages
  | Private_file_failed error
  | Private_file_failed_with_cleanup_failure { error; cleanup_failure = _ } ->
    report_persistence_read_drop
      ~reason:Read_drop_reason.Entry_load_error
      ~path
      ~detail:(Fs_compat.Private_jsonl_rows.error_to_string error);
    forget_transcript path;
    []
;;

let load_all ~base_dir ~keeper_name : chat_message list =
  let path = chat_path ~base_dir ~keeper_name in
  if not (Sys.file_exists path) then (
    forget_transcript path;
    [])
  else
    let redaction = redaction_for ~base_dir ~keeper_name in
    let cached =
      Stdlib.Mutex.protect transcript_caches_mu (fun () ->
        Hashtbl.find_opt transcript_caches path)
    in
    let continuation =
      match cached, transcript_identity path with
      | Some cache, Some (device, inode, size)
        when cache.device = device
             && cache.inode = inode
             && size >= cache.parsed_end
             && cache.redaction == redaction -> Some cache
      | Some _, Some _ | Some _, None | None, Some _ | None, None -> None
    in
    match continuation with
    | None -> load_transcript_fully ~path ~redaction
    | Some cache ->
      (match Fs_compat.read_private_jsonl_slice_locked_result path ~from:cache.parsed_end with
       | Private_file_succeeded { Fs_compat.Private_jsonl_slice.bytes; end_offset }
       | Private_file_succeeded_with_cleanup_failure
           { value = { Fs_compat.Private_jsonl_slice.bytes; end_offset }; _ } ->
         let fresh =
           if String.equal bytes ""
           then []
           else
             Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
               parse_transcript_rows ~path ~redaction bytes)
         in
         let messages_rev = List.rev_append fresh cache.messages_rev in
         (* The read and the parse above can suspend this fiber, and a purge of
            the transcript can run meanwhile. These rows are then those of a
            file that is gone, so they are registered only while the table
            still holds the cache this load went on from. *)
         advance_transcript path ~from:cache { cache with parsed_end = end_offset; messages_rev };
         List.rev messages_rev
       | Private_file_failed _ | Private_file_failed_with_cleanup_failure _ ->
         load_transcript_fully ~path ~redaction)

let load_all_using ~base_dir ~keeper_name ~parse_rows =
  let path = chat_path ~base_dir ~keeper_name in
  let redaction = redaction_for ~base_dir ~keeper_name in
  (* The [load_all] cache is permissive: malformed rows are omitted. A strict
     caller must parse the durable file so it cannot advance past such a row. *)
  match Fs_compat.read_private_jsonl_rows_locked_result path with
  | Private_file_succeeded Fs_compat.Private_jsonl_rows.Rows_missing
  | Private_file_succeeded_with_cleanup_failure
      { value = Fs_compat.Private_jsonl_rows.Rows_missing; _ } -> Ok []
  | Private_file_succeeded
      (Fs_compat.Private_jsonl_rows.Rows_present { rows; rows_end; end_offset })
  | Private_file_succeeded_with_cleanup_failure
      { value =
          Fs_compat.Private_jsonl_rows.Rows_present { rows; rows_end; end_offset }
      ; _
      } ->
    if rows_end < end_offset
    then
      Error
        { location = path
        ; cause =
            Unreadable_file
              (Printf.sprintf
                 "%s incomplete chat tail: complete rows end at byte %d, file ends at byte %d"
                 path
                 rows_end
                 end_offset)
        }
    else parse_rows ~path ~redaction rows
  | Private_file_failed error
  | Private_file_failed_with_cleanup_failure { error; cleanup_failure = _ } ->
    Error
      { location = path
      ; cause =
          Unreadable_file (Fs_compat.Private_jsonl_rows.error_to_string error)
      }

let load_captured_result ~select ~base_dir ~keeper_name =
  load_all_using ~base_dir ~keeper_name ~parse_rows:(parse_transcript_captures_result ~select)

let load_all_result ~base_dir ~keeper_name =
  load_all_using ~base_dir ~keeper_name ~parse_rows:parse_transcript_rows_result

type history_page =
  { history_messages : chat_message list
  ; next_cursor : Keeper_chat_history_page.cursor option
  }

let load_result ~base_dir ~keeper_name =
  let open Result.Syntax in
  let path = chat_path ~base_dir ~keeper_name in
  (* All complete rows inside the existing byte window participate in the
     role-based selection. Taking only 400 physical rows would let a tool-heavy
     tail erase the conversation again. The reader still reads at most 4 MiB. *)
  let* page = Keeper_chat_history_page.read ~path ~owner:keeper_name
      ~max_rows:max_int () in
  let redaction = redaction_for ~base_dir ~keeper_name in
  let push, finish = history_window ~window_history:max_history
      ~window_secondary:(max_total_lines - max_history) in
  let* () =
    List.fold_left (fun state (row : Keeper_chat_history_page.row) ->
      let* () = state in
      match parse_transcript_row_strict ~path ~redaction ~position:(Byte_offset row.offset) row.line with
      | `Blank -> Ok ()
      | `Message message -> push message; Ok ()
      | `Unreadable err ->
        Error (Keeper_chat_history_page.Invalid_row { offset = row.offset; detail = strict_decode_error_to_string err }))
      (Ok ()) page.rows
  in
  Ok (fst (finish ()))

let load_history_page_result ~base_dir ~keeper_name ?cursor
      ?(max_total = max_total_lines) () =
  let open Result.Syntax in
  let path = chat_path ~base_dir ~keeper_name in
  let* page = Keeper_chat_history_page.read ~path ~owner:keeper_name ?cursor
    ~max_rows:(max 1 (min max_total max_total_lines)) () in
  let redaction = redaction_for ~base_dir ~keeper_name in
  let* messages_rev =
    List.fold_left (fun state (row : Keeper_chat_history_page.row) ->
      let* messages = state in
      match parse_transcript_row_strict ~path ~redaction ~position:(Byte_offset row.offset) row.line with
      | `Blank -> Ok messages
      | `Message message -> Ok (message :: messages)
      | `Unreadable err -> Error (Keeper_chat_history_page.Invalid_row { offset = row.offset; detail = strict_decode_error_to_string err }))
      (Ok []) page.rows
  in
  Ok { history_messages = List.rev messages_rev; next_cursor = page.next_cursor }
