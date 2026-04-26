(** Exception-safe subprocess stdout capture.

    SSOT for the [Unix.open_process_*] + drain + close pattern.  Extracted
    in the post-#8543 hardening (#8538) so every call site uses the same
    error-path close semantics.

    Why not [Fun.protect]?  Its finally-callback gets its exception wrapped
    in [Fun.Finally_raised], which masks the original exception that matters
    to callers.  Manual [try/with] lets [Eio.Cancel.Cancelled] and other
    in-flight exceptions propagate unchanged.

    Why swallow close errors?  Per ocaml/ocaml#2447, [close_process_*] may
    raise [Failure "equal: abstract value"] when called on already-closed
    channels.  The close is best-effort; the primary contract is fd reclaim. *)

let close_best_effort ic =
  try
    let _ = (Unix.close_process_in ic : Unix.process_status) in
    ()
  with
  | Unix.Unix_error _ | Sys_error _ | Failure _ -> ()
;;

let with_process_in cmd f =
  let ic = Unix.open_process_in cmd in
  match f ic with
  | result ->
    let status = Unix.close_process_in ic in
    result, status
  | exception exn ->
    close_best_effort ic;
    raise exn
;;

let with_process_args_in prog argv f =
  let ic = Unix.open_process_args_in prog argv in
  match f ic with
  | result ->
    let status = Unix.close_process_in ic in
    result, status
  | exception exn ->
    close_best_effort ic;
    raise exn
;;

let drain_to_buffer ?(chunk = 4096) ic =
  let buf = Buffer.create chunk in
  (try
     while true do
       Buffer.add_channel buf ic chunk
     done
   with
   | End_of_file -> ());
  buf
;;

let drain_lines ic =
  let rec loop acc =
    match input_line ic with
    | line -> loop (line :: acc)
    | exception End_of_file -> List.rev acc
  in
  loop []
;;
