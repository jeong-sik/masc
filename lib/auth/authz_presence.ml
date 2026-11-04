(* HIGH-RISK-UNREVIEWED: see the interface. *)

type t =
  | Not_there
  | There
  | Cannot_check of string

let nul_byte path = Printf.sprintf "the path %S holds a NUL byte" path

let rec walk_up path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
    let parent = Filename.dirname path in
    if String.equal parent path then Ok () else walk_up parent
  | exception Unix.Unix_error (error, _, _) ->
    Error (Printf.sprintf "%s: %s" path (Unix.error_message error))
  | { Unix.st_kind = Unix.S_LNK; _ } ->
    (match Unix.stat path with
     | (_ : Unix.stats) -> Ok ()
     | exception Unix.Unix_error (error, _, _) ->
       Error
         (Printf.sprintf "the symbolic link %s is dangling: %s" path (Unix.error_message error)))
  | { Unix.st_kind = Unix.S_REG | Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK; _ }
    -> Ok ()
;;

let confirm_absent path = if String.contains path '\000' then Error (nul_byte path) else walk_up path

let of_path path =
  if String.contains path '\000'
  then Cannot_check (nul_byte path)
  else (
    match Unix.lstat path with
    | (_ : Unix.stats) -> There
    | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
      (match walk_up (Filename.dirname path) with
       | Ok () -> Not_there
       | Error detail -> Cannot_check detail)
    | exception Unix.Unix_error (error, _, _) ->
      Cannot_check (Printf.sprintf "%s: %s" path (Unix.error_message error)))
;;
