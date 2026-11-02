open Board_types

type posts_inspection_framing =
  | Complete_rows
  | Torn_tail of { rows_end : int; end_offset : int }

type posts_inspection_observation =
  | Observed_missing
  | Observed_present of {
      accepted_rows : int;
      errors : posts_row_error list;
      framing : posts_inspection_framing;
    }

type posts_inspection =
  | Inspected of {
      observation : posts_inspection_observation;
      settlement_diagnostic : Fs_compat.private_jsonl_operation_failure option;
    }
  | Inspection_failed of {
      error : Fs_compat.Private_jsonl_unique_fold.error;
      settlement_diagnostic : Fs_compat.private_jsonl_operation_failure option;
    }


type rows = {
  next_line : int;
  accepted_rows : int;
  errors_rev : posts_row_error list;
  diagnostics_rev : Board_content_json.diagnostic list;
}

let empty_rows = {
  next_line = 1; accepted_rows = 0; errors_rev = []; diagnostics_rev = [];
}

(* Pure callback: no logging, Board lock or Eio effect in the Fs worker. *)
let decode_row rows text =
  let next_line = rows.next_line + 1 in
  match Board_posts_rows.decode ~line:rows.next_line text with
  | Blank -> { rows with next_line }
  | Accepted { diagnostics; post = _ } -> {
      rows with next_line; accepted_rows = rows.accepted_rows + 1;
      diagnostics_rev = List.rev_append diagnostics rows.diagnostics_rev;
    }
  | Rejected { error; diagnostics } -> {
      rows with next_line; errors_rev = error :: rows.errors_rev;
      diagnostics_rev = List.rev_append diagnostics rows.diagnostics_rev;
    }

let inspected ~settlement_diagnostic = function
  | Fs_compat.Private_jsonl_fold.Missing ->
    Inspected { observation = Observed_missing; settlement_diagnostic }
  | Present { value; rows_end; end_offset } ->
    let framing = if rows_end = end_offset then Complete_rows
      else Torn_tail { rows_end; end_offset } in
    (* The stable reader refuses torn framing before decoding. Retain the
       pure prefix observation without advancing its diagnostic effects. *)
    (match framing with
     | Complete_rows -> Board_content_diagnostics.emit (List.rev value.diagnostics_rev)
     | Torn_tail _ -> ());
    Inspected {
      observation = Observed_present {
        accepted_rows = value.accepted_rows;
        errors = List.rev value.errors_rev;
        framing;
      };
      settlement_diagnostic;
    }

let read_with_fold ~workspace_masc_dir fold =
  let workspace_masc_dir = Board_paths.capture_workspace_masc_dir workspace_masc_dir in
  let path = Board_paths.posts_file ~workspace_masc_dir in
  match fold path ~init:empty_rows ~f:decode_row with
  | Fs_compat.Private_file_succeeded value ->
    inspected ~settlement_diagnostic:None value
  | Private_file_succeeded_with_cleanup_failure { value; cleanup_failure } ->
    inspected ~settlement_diagnostic:(Some cleanup_failure) value
  | Private_file_failed error -> Inspection_failed { error; settlement_diagnostic = None }
  | Private_file_failed_with_cleanup_failure { error; cleanup_failure } ->
    Inspection_failed { error; settlement_diagnostic = Some cleanup_failure }

let read ~workspace_masc_dir =
  read_with_fold ~workspace_masc_dir Fs_compat.fold_private_jsonl_unique_regular_locked_result

let read_with_io_for_testing ~workspace_masc_dir ~io =
  read_with_fold ~workspace_masc_dir
    (Fs_compat.fold_private_jsonl_unique_regular_locked_with_io_for_testing ~io)

let reserved_operation (failure : Fs_compat.private_jsonl_operation_failure) =
  Board_posts_source.reserved_exception (failure.exception_, failure.backtrace)

let reserved_error = function
  | Fs_compat.Private_jsonl_unique_fold.Non_regular_file _ | Snapshot_changed -> None
  | Binding_refused error -> Board_posts_source.reserved_transaction error
  | Operation_failed failure -> reserved_operation failure

let finish inspection =
  let primary, settlement_diagnostic = match inspection with
    | Inspected { settlement_diagnostic; _ } -> None, settlement_diagnostic
    | Inspection_failed { error; settlement_diagnostic } -> reserved_error error, settlement_diagnostic in
  let reserved = match primary with
    | Some _ -> primary
    | None -> Option.bind settlement_diagnostic reserved_operation in
  match reserved with
  | None -> ()
  | Some (exception_, backtrace) -> Printexc.raise_with_backtrace exception_ backtrace
