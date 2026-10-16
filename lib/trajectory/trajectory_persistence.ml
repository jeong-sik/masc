type failure =
  | Incomplete_tail
  | Append_failed of Fs_compat.durable_append_error
  | Raised of { exception_ : exn; backtrace : Printexc.raw_backtrace }

type issue =
  { failure : failure
  ; cleanup_failure : Fs_compat.private_jsonl_operation_failure option
  }

type outcome =
  | Durable of { cleanup_failure : Fs_compat.private_jsonl_operation_failure option }
  | Not_committed of issue
  | Indeterminate of issue

let issue_to_string { failure; cleanup_failure } =
  let primary = match failure with
    | Incomplete_tail -> "trajectory has an incomplete final row; bytes preserved"
    | Append_failed error -> Fs_compat.durable_append_error_to_string error
    | Raised { exception_; backtrace = _ } -> Printexc.to_string exception_
  in
  match cleanup_failure with
  | None -> primary
  | Some failure -> primary ^ "; " ^ Fs_compat.private_jsonl_operation_failure_to_string failure
;;

type admission = Before_append | Refused_tail | Append_offered

let append_with transaction ~path jsons =
  let admission = Atomic.make Before_append in
  let cleanup_failure = ref None in
  let refuse error =
    let issue = {failure=Append_failed error; cleanup_failure= !cleanup_failure} in
    match error.Fs_compat.rollback_failures with
    | [] -> Not_committed issue
    | _ :: _ -> Indeterminate issue
  in
  try
    let suffix =
      jsons |> List.map (fun json -> Yojson.Safe.to_string json ^ "\n") |> String.concat ""
    in
    let outcome = transaction path ~max_bytes:1 (fun tail ->
      (* One byte is the JSONL delimiter, not an arbitrary transcript window.
         The tail updater holds both writer locks and never truncates here. *)
      if String.length tail > 0 && not (Char.equal tail.[String.length tail - 1] '\n')
      then (Atomic.set admission Refused_tail; None, ())
      else (Atomic.set admission Append_offered; Some suffix, ())) in
    let result = match outcome with
      | Fs_compat.Private_file_succeeded () -> Ok ()
      | Fs_compat.Private_file_succeeded_with_cleanup_failure { value=(); cleanup_failure=failure } ->
        cleanup_failure := Some failure; Ok ()
      | Fs_compat.Private_file_failed error -> Error error
      | Fs_compat.Private_file_failed_with_cleanup_failure { error; cleanup_failure=failure } ->
        cleanup_failure := Some failure; Error error
    in
    match result, Atomic.get admission with
    | Ok (), Append_offered -> Durable {cleanup_failure= !cleanup_failure}
    | Ok (), (Before_append | Refused_tail) ->
      Not_committed {failure=Incomplete_tail; cleanup_failure= !cleanup_failure}
    | Error error, (Before_append | Refused_tail | Append_offered) -> refuse error
  with
  | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
  | exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    let issue = {failure=Raised {exception_; backtrace}; cleanup_failure= !cleanup_failure} in
    match Atomic.get admission with
    | Before_append | Refused_tail -> Not_committed issue
    | Append_offered -> Indeterminate issue
;;

let append ~path jsons =
  append_with Fs_compat.update_private_file_tail_durable_locked_result ~path jsons
;;

module For_testing = struct
  let append_with_io ~append_io ~path jsons =
    append_with
      (Fs_compat.update_private_file_tail_durable_locked_with_append_io_for_testing ~append_io)
      ~path jsons
end
