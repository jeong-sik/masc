(** See [.mli] for design notes. *)

type t =
  | Path_syntax_blocked of
      { token : string
      ; hint : string option
      }
  | Path_outside_whitelist of
      { path : string
      ; for_keeper_command : bool
      }
  | Cwd_not_directory of
      { path : string
      ; hint : string option
      }

let append_hint base = function
  | None | Some "" -> base
  | Some hint -> base ^ " " ^ hint
;;

let to_message = function
  | Path_syntax_blocked { token = _; hint } ->
    let base =
      "Path syntax blocked: shell quoting, globbing, brace expansion, and \
       backslash escapes are not allowed for path-bearing keeper commands. \
       Use plain unquoted paths and explicit cwd."
    in
    append_hint base hint
  | Path_outside_whitelist { path; for_keeper_command = true } ->
    Printf.sprintf
      "Path blocked: %s (outside allowed directories for this keeper command)"
      path
  | Path_outside_whitelist { path; for_keeper_command = false } ->
    Printf.sprintf "Path blocked: %s (outside allowed directories)" path
  | Cwd_not_directory { path; hint } ->
    let base =
      Printf.sprintf
        "cwd_not_directory: %s (directory does not exist under cwd; create or \
         repair the sandbox repo/worktree first)"
        path
    in
    append_hint base hint
;;

let message_prefix = function
  | Path_syntax_blocked _ -> "path syntax blocked:"
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
  if starts_with_ci ~prefix:"path syntax blocked:" trimmed
  then Some (Path_syntax_blocked { token = ""; hint = None })
  else if starts_with_ci ~prefix:"path blocked:" trimmed
  then Some (Path_outside_whitelist { path = ""; for_keeper_command = false })
  else if starts_with_ci ~prefix:"cwd_not_directory:" trimmed
  then Some (Cwd_not_directory { path = ""; hint = None })
  else None
;;
