type read =
  | Read of Fs_compat.private_jsonl_snapshot Fs_compat.private_jsonl_success_receipt
  | Failed of Fs_compat.private_jsonl_transaction_error
  | Raised of exn * Printexc.raw_backtrace

let read ?io ~path () =
  try
    let result = match io with
      | None -> Fs_compat.read_private_jsonl_durable_locked_result path ~after:None
      | Some io -> Fs_compat.read_private_jsonl_durable_locked_with_io_for_testing
          ~io path ~after:None in
    match Fs_compat.private_jsonl_snapshot_success_receipt result with
    | Ok receipt -> Read receipt
    | Error error -> Failed error
  with exception_ -> Raised (exception_, Printexc.get_raw_backtrace ())

let validate (snapshot : Fs_compat.private_jsonl_snapshot) =
  let rows = ref Board_posts_guard_rows.empty and start = ref 0 in
  String.iteri (fun index character ->
    if character = '\n' then (
      rows := Board_posts_guard_rows.add_row !rows
        (String.sub snapshot.bytes !start (index - !start));
      start := index + 1)) snapshot.bytes;
  let framing = Board_posts_guard_rows.framing
      ~rows_end:!start ~end_offset:(String.length snapshot.bytes) in
  Board_posts_guard_rows.validate ~framing !rows
