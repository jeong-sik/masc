type error =
  | Durable_source_read_failed of
      { path : string
      ; reason : string
      }
  | Symlink_encountered of { path : string }

let error_to_string = function
  | Durable_source_read_failed { path; reason } ->
    Printf.sprintf "durable source read failed path=%s: %s" path reason
  | Symlink_encountered { path } ->
    Printf.sprintf
      "refusing to report unreferenced past an unresolved symlink at %s"
      path
;;

exception Found
exception Error_exn of error

let unix_reason fn arg code = Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code)

(* An empty handle names nothing, so no file mentions it. *)
let mentions ~handle content =
  (not (String.equal handle "")) && String_util.contains_substring content handle
;;

let read_whole_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let len = in_channel_length ic in
      really_input_string ic len)
;;

(* A regular file is read and checked; a directory is recursed into. A
   symlink is never followed (it could point outside the scanned tree), and
   it is never silently skipped either (see .mli): this predicate protects a
   handle by answering [true], and a symlink is a place this scan cannot
   verify, so it must not fall through as "no reference here". A device,
   socket or fifo is not a place a handle mention could live and is skipped
   without raising: unlike a symlink it names no other content to miss. *)
let rec walk_tree ~handle path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | exception Unix.Unix_error (err, fn, arg) ->
    raise (Error_exn (Durable_source_read_failed { path; reason = unix_reason fn arg err }))
  | stat ->
    (match stat.Unix.st_kind with
     | Unix.S_REG ->
       (match read_whole_file path with
        | content -> if mentions ~handle content then raise Found
        | exception Sys_error reason -> raise (Error_exn (Durable_source_read_failed { path; reason })))
     | Unix.S_DIR ->
       (match Sys.readdir path with
        | exception Sys_error reason -> raise (Error_exn (Durable_source_read_failed { path; reason }))
        | entries -> Array.iter (fun name -> walk_tree ~handle (Filename.concat path name)) entries)
     | Unix.S_LNK -> raise (Error_exn (Symlink_encountered { path }))
     | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> ())
;;

let is_referenced ~consumer_paths ~handle =
  try
    List.iter (walk_tree ~handle) consumer_paths;
    Ok false
  with
  | Found -> Ok true
  | Error_exn e -> Error e
;;
