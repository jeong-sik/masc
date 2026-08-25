(** See [.mli] for design notes. *)

type t =
  | Path_outside_whitelist of
      { path : string
      ; for_keeper_command : bool
      }
  | Cwd_not_directory of
      { path : string
      ; hint : string option
      }

(* The rejected path is whatever the caller asked for, and a tool argument can
   carry a newline. The logs are line-delimited JSON, so one such rejection
   became three lines: a counter read it as three events and the trailing two
   were dropped as unparseable. Seen on 2026-08-24 with
   "…/repos/masc\r slot\r storage" (#30338).

   Only the rendered message is folded. The path itself is untouched — a
   directory really can contain these bytes, and the check that rejected it
   compared the real string. *)
let one_line path =
  String.map
    (function '\n' | '\r' | '\t' -> ' ' | c -> c)
    path
;;

let append_hint base = function
  | None | Some "" -> base
  | Some hint -> base ^ " " ^ hint
;;

let to_message = function
  | Path_outside_whitelist { path; for_keeper_command = true } ->
    Printf.sprintf
      "Path blocked: %s (outside allowed directories for this keeper command)"
      (one_line path)
  | Path_outside_whitelist { path; for_keeper_command = false } ->
    Printf.sprintf "Path blocked: %s (outside allowed directories)" (one_line path)
  | Cwd_not_directory { path; hint } ->
    let base =
      Printf.sprintf
        "cwd_not_directory: %s (directory does not exist under cwd; create or \
         repair the sandbox repo/worktree first)"
        (one_line path)
    in
    append_hint base hint
;;

let message_prefix = function
  | Path_outside_whitelist _ -> "path blocked:"
  | Cwd_not_directory _ -> "cwd_not_directory:"
;;

let starts_with_ci ~prefix s =
  let pl = String.length prefix in
  String.length s >= pl
  && String.lowercase_ascii (String.sub s 0 pl) = prefix
;;

let parse_prefix msg =
  let trimmed = String.trim msg in
  if starts_with_ci ~prefix:"path blocked:" trimmed
  then Some (Path_outside_whitelist { path = ""; for_keeper_command = false })
  else if starts_with_ci ~prefix:"cwd_not_directory:" trimmed
  then Some (Cwd_not_directory { path = ""; hint = None })
  else None
;;
