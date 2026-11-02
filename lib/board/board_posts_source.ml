open Board_types

type reserved_settlement = {
  result : (unit, board_error) result;
  exception_ : exn;
  backtrace : Printexc.raw_backtrace;
}
exception Reserved_settlement of reserved_settlement

(* The persistence mutex owns source state. Rendering/table access additionally
   requires the state mutex; Fs callbacks acquire no Board locks. *)
let last_observed = function
  | Posts_unobserved -> None
  | Posts_readable { observation; _ } -> Some observation
  | Posts_refused { last_observed; _ } | Posts_unsettled { last_observed; _ } -> last_observed

let failure_to_board_error = function
  | Posts_not_observed -> Io_error "posts source has not been explicitly loaded"
  | Posts_rows_rejected errors ->
    let detail = List.map (function
      | Invalid_posts_json { line; detail } -> Printf.sprintf "line %d: invalid JSON: %s" line detail
      | Invalid_posts_row { line } -> Printf.sprintf "line %d: invalid persisted row schema" line) errors in
    Io_error (String.concat "; " detail)
  | Posts_transaction_failed error -> Io_error (Fs_compat.private_jsonl_transaction_error_to_string error)
  | Posts_missing_after_observation _ -> Io_error "posts source disappeared after observation or refusal"
  | Posts_source_binding_mismatch -> Io_error "posts source belongs to another captured workspace"
  | Posts_snapshot_stale -> Io_error "captured posts snapshot is stale"
  | Posts_raised { exception_; _ } -> Io_error (Printexc.to_string exception_)

let require_readable store = match store.posts_source with
  | Posts_readable { observation; _ }
    when String.equal observation.source_path (Board_paths.persist_path store) -> Ok ()
  | Posts_readable _ -> Error (failure_to_board_error Posts_source_binding_mismatch)
  | Posts_unobserved -> Error (failure_to_board_error Posts_not_observed)
  | Posts_refused { failure; _ } | Posts_unsettled { failure; _ } -> Error (failure_to_board_error failure)

let rec reserved_exception (exception_, backtrace) = match exception_ with
  | Eio.Cancel.Cancelled _ | Eio.Time.Timeout | Out_of_memory | Stack_overflow | Sys.Break ->
    Some (exception_, backtrace)
  | Eio.Exn.Multiple failures ->
    (match List.find_map reserved_exception failures with
     | None -> None | Some _ -> Some (exception_, backtrace))
  (* exn is open; ordinary exceptions are retained as typed source failures. *)
  | _ -> None

let reserved_failure (failure : Fs_compat.private_jsonl_operation_failure) =
  reserved_exception (failure.exception_, failure.backtrace)

let rec reserved_transaction = function
  | Fs_compat.Private_jsonl_operation_failed failure -> reserved_failure failure
  | Rewrite_stage_failed { failure; cleanup_failures } ->
    (match reserved_failure failure with Some _ as found -> found
     | None -> List.find_map reserved_failure cleanup_failures)
  | Rewrite_published_durability_unknown { failure; _ } -> reserved_failure failure
  | Transaction_settlement_failed { primary; cleanup_failures } ->
    let first = match primary with
      | Transaction_succeeded _ -> None
      | Transaction_failed error -> reserved_transaction error in
    (match first with Some _ -> first | None -> List.find_map reserved_failure cleanup_failures)
  | Stable_lock_contended _ | Unexpected_stable_lock_permissions _
  | Invalid_stable_lock_state _ | Cursor_mismatch _ | Unexpected_transaction_file_kind _
  | Ambiguous_transaction_file_identity _ | Transaction_path_binding_changed _
  | Transaction_content_changed _ | Incomplete_transaction_tail _ | Invalid_transaction_suffix
  | Transaction_append_failed _ -> None

let raise_reserved = function
  | None -> ()
  | Some (exception_, backtrace) -> Printexc.raise_with_backtrace exception_ backtrace

let propagate_reserved exception_ backtrace =
  raise_reserved (reserved_exception (exception_, backtrace))

let reserved_source_failure = function
  | Posts_transaction_failed error -> reserved_transaction error
  | Posts_raised { exception_; backtrace } -> reserved_exception (exception_, backtrace)
  | Posts_missing_after_observation diagnostic -> Option.bind diagnostic reserved_transaction
  | Posts_not_observed | Posts_rows_rejected _
  | Posts_source_binding_mismatch | Posts_snapshot_stale -> None

let finish_failure failure = raise_reserved (reserved_source_failure failure)

let carry_reserved result = function
  | None -> ()
  | Some (exception_, backtrace) -> raise (Reserved_settlement { result; exception_; backtrace })

let finish_diagnostic diagnostic =
  Option.iter (fun error -> match reserved_transaction error with
    | None -> ()
    | Some reserved -> carry_reserved (Ok ()) (Some reserved)) diagnostic

let finish_write = function
  | Posts_written { settlement_diagnostic } -> finish_diagnostic settlement_diagnostic; Ok ()
  | Posts_not_written failure ->
    let result = Error (failure_to_board_error failure) in
    carry_reserved result (reserved_source_failure failure);
    result
  | Posts_write_unknown failure ->
    finish_failure failure; Error (failure_to_board_error failure)

let finish_read = function
  | Posts_complete { settlement_diagnostic; _ } | Posts_partial { settlement_diagnostic; _ } ->
    finish_diagnostic settlement_diagnostic
  | Posts_unavailable failure ->
    carry_reserved (Error (failure_to_board_error failure)) (reserved_source_failure failure)

let refused store failure =
  match store.posts_source with
  | Posts_unsettled _ -> ()
  | Posts_unobserved | Posts_readable _ | Posts_refused _ ->
    store.posts_source <- Posts_refused { last_observed = last_observed store.posts_source; failure }

let unsettled store failure =
  store.posts_source <- Posts_unsettled { last_observed = last_observed store.posts_source; failure }

let read store =
  match store.posts_source with
  | Posts_unsettled { failure; _ } -> Posts_unavailable failure
  | Posts_unobserved | Posts_readable _ | Posts_refused _ ->
    let path = Board_paths.persist_path store in
    try
      let result = match store.posts_io_for_testing with
        | None -> Fs_compat.read_private_jsonl_durable_locked_result path ~after:None
        | Some io -> Fs_compat.read_private_jsonl_durable_locked_with_io_for_testing ~io path ~after:None in
      match Fs_compat.private_jsonl_snapshot_success_receipt result with
      | Error error -> Posts_unavailable (Posts_transaction_failed error)
      | Ok receipt ->
        let observation = { source_path = path; snapshot = receipt.value } in
        let missing = Fs_compat.Private_jsonl_cursor.is_missing receipt.value.cursor in
        let missing_allowed = match store.posts_source with
          | Posts_unobserved -> true
          | Posts_readable { observation; _ } ->
            Fs_compat.Private_jsonl_cursor.is_missing observation.snapshot.cursor
          | Posts_refused _ | Posts_unsettled _ -> false in
        if missing && not missing_allowed then
          Posts_unavailable (Posts_missing_after_observation receipt.settlement_error)
        else
          let posts = ref [] and errors = ref [] in
          String.split_on_char '\n' receipt.value.bytes |> List.iteri (fun index text ->
            if not (String.equal (String.trim text) "") then
              match Yojson.Safe.from_string text with
              | json -> (match Board_core_json.post_of_yojson json with
                | Some post -> posts := post :: !posts
                | None -> errors := Invalid_posts_row { line = index + 1 } :: !errors)
              | exception Yojson.Json_error detail ->
                errors := Invalid_posts_json { line = index + 1; detail } :: !errors);
          let posts = List.rev !posts in
          match List.rev !errors with
          | [] -> Posts_complete { observation; posts; settlement_diagnostic = receipt.settlement_error }
          | errors -> Posts_partial { observation; posts; errors; settlement_diagnostic = receipt.settlement_error }
    with exception_ ->
      let backtrace = Printexc.get_raw_backtrace () in
      let failure = Posts_raised { exception_; backtrace } in
      refused store failure;
      carry_reserved (Error (failure_to_board_error failure)) (reserved_source_failure failure);
      Printexc.raise_with_backtrace exception_ backtrace

let publish_read store = function
  | Posts_complete { observation; settlement_diagnostic; _ } ->
    (match store.posts_source with
     | Posts_unsettled _ -> ()
     | Posts_unobserved | Posts_readable _ | Posts_refused _ ->
       store.posts_source <- Posts_readable { observation; settlement_diagnostic })
  | Posts_partial { observation; errors; _ } ->
    (match store.posts_source with
     | Posts_unsettled _ -> ()
     | Posts_unobserved | Posts_readable _ | Posts_refused _ ->
       store.posts_source <- Posts_refused { last_observed = Some observation; failure = Posts_rows_rejected errors })
  | Posts_unavailable failure -> refused store failure

(* Only error branches with actual prepublication evidence are nonwrites. The
   final append fstat uses the same operation tag as its precondition fstat. *)
let rec definitely_not_written = function
  | Fs_compat.Stable_lock_contended _ | Unexpected_stable_lock_permissions _
  | Invalid_stable_lock_state _ | Cursor_mismatch _ | Unexpected_transaction_file_kind _
  | Ambiguous_transaction_file_identity _ | Transaction_path_binding_changed _
  | Transaction_content_changed _ | Incomplete_transaction_tail _ | Invalid_transaction_suffix
  | Rewrite_stage_failed _ -> true
  | Transaction_append_failed { rollback_failures; _ } -> rollback_failures = []
  | Transaction_settlement_failed { primary = Transaction_failed error; _ } -> definitely_not_written error
  | Transaction_settlement_failed { primary = Transaction_succeeded (Cursor_precondition_succeeded _); _ } -> true
  | Transaction_settlement_failed { primary = Transaction_succeeded (Snapshot_succeeded _ | Cursor_succeeded _); _ }
  | Rewrite_published_durability_unknown _ -> false
  | Private_jsonl_operation_failed { operation; _ } ->
    (match operation with
     | Create_parent_directory | Canonicalize_parent_directory | Inspect_stable_lock
     | Open_stable_lock | Set_stable_lock_permissions | Sync_stable_lock_parent
     | Acquire_stable_lock | Read_stable_lock_state | Write_stable_lock_state
     | Sync_stable_lock | Open_transaction_data | Set_transaction_data_permissions
     | Inspect_transaction_path | Read_transaction_data | Create_rewrite_stage
     | Set_rewrite_stage_permissions | Write_rewrite_stage | Sync_rewrite_stage
     | Close_rewrite_stage | Rename_rewrite_stage | Remove_rewrite_stage -> true
     | Inspect_transaction_data | Close_transaction_data | Close_stable_lock
     | Sync_rewrite_parent | Inspect_rewritten_data | Truncate_transaction_data
     | Sync_transaction_data | Remove_transaction_data | Sync_removal_parent -> false)

(* A prewrite nonregular obstruction cannot authorize a write. Retain the old
   expectation so an applied deletion can retry after the original file is
   restored: Fs must still compare its exact identity and bytes. A real read
   failure remains a refusal through [publish_read]. *)
let rec contradicts_observation = function
  | Fs_compat.Cursor_mismatch _ | Transaction_content_changed _
  | Transaction_path_binding_changed _ | Incomplete_transaction_tail _
  | Ambiguous_transaction_file_identity _ -> true
  | Transaction_settlement_failed { primary = Transaction_failed error; _ } -> contradicts_observation error
  | Stable_lock_contended _ | Unexpected_stable_lock_permissions _ | Invalid_stable_lock_state _
  | Unexpected_transaction_file_kind _ | Invalid_transaction_suffix | Private_jsonl_operation_failed _
  | Rewrite_stage_failed _ | Rewrite_published_durability_unknown _
  | Transaction_settlement_failed { primary = Transaction_succeeded _; _ }
  | Transaction_append_failed _ -> false

let classify_write store ~bytes result =
  match Fs_compat.private_jsonl_cursor_success_receipt result with
  | Ok receipt ->
    let observation = { source_path = Board_paths.persist_path store;
                        snapshot = { Fs_compat.bytes = bytes; cursor = receipt.value } } in
    store.posts_source <- Posts_readable { observation; settlement_diagnostic = receipt.settlement_error };
    Posts_written { settlement_diagnostic = receipt.settlement_error }
  | Error error ->
    let failure = Posts_transaction_failed error in
    if definitely_not_written error then (
      if contradicts_observation error then refused store failure;
      Posts_not_written failure)
    else (unsettled store failure; Posts_write_unknown failure)

let write store ~bytes perform =
  try classify_write store ~bytes (perform ()) with exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    unsettled store (Posts_raised { exception_; backtrace });
    Printexc.raise_with_backtrace exception_ backtrace

let expected store = match store.posts_source with
  | Posts_readable { observation; _ } ->
    if String.equal observation.source_path (Board_paths.persist_path store)
    then Ok observation else Error Posts_source_binding_mismatch
  | Posts_unobserved -> Error Posts_not_observed
  | Posts_refused { failure; _ } | Posts_unsettled { failure; _ } -> Error failure

let append store post = match expected store with
  | Error failure -> Posts_not_written failure
  | Ok observation ->
    let suffix = Yojson.Safe.to_string (Board_content_json.post_to_yojson post) ^ "\n" in
    let bytes = observation.snapshot.bytes ^ suffix in
    write store ~bytes (fun () -> match store.posts_io_for_testing with
      | None -> Fs_compat.append_private_jsonl_durable_locked_at_snapshot_result
          observation.source_path ~expected:observation.snapshot suffix
      | Some io -> Fs_compat.append_private_jsonl_durable_locked_at_snapshot_with_io_for_testing
          ~io observation.source_path ~expected:observation.snapshot suffix)

type snapshot = { expected : (posts_source_observation, posts_source_failure) result; bytes : string }

let capture ?replacement store =
  let bytes = match replacement with
    | None -> Board_snapshot_rows.render ~rows:store.post_rows
        ~to_json:Board_content_json.post_to_yojson store.posts
    | Some (replacement : post) ->
      let buffer = Buffer.create 4096 in
      Hashtbl.iter (fun key (post : post) ->
        let post = if String.equal key (Post_id.to_string replacement.id) then replacement else post in
        Buffer.add_string buffer (Yojson.Safe.to_string (Board_content_json.post_to_yojson post));
        Buffer.add_char buffer '\n') store.posts;
      Buffer.contents buffer in
  { expected = expected store; bytes }

let rewrite store snapshot = match snapshot.expected, expected store with
  | Error failure, _ | _, Error failure -> Posts_not_written failure
  | Ok captured, Ok current ->
    if not (String.equal captured.source_path current.source_path)
    then Posts_not_written Posts_source_binding_mismatch
    else if not (Fs_compat.Private_jsonl_cursor.equal captured.snapshot.cursor current.snapshot.cursor
                 && String.equal captured.snapshot.bytes current.snapshot.bytes)
    then Posts_not_written Posts_snapshot_stale
    else write store ~bytes:snapshot.bytes (fun () -> match store.posts_io_for_testing with
      | None -> Fs_compat.rewrite_private_jsonl_durable_locked_at_snapshot_result
          captured.source_path ~expected:captured.snapshot snapshot.bytes
      | Some io -> Fs_compat.rewrite_private_jsonl_durable_locked_at_snapshot_with_io_for_testing
          ~io ~before_sync_rewrite_parent:io.before_sync_parent
          captured.source_path ~expected:captured.snapshot snapshot.bytes)
