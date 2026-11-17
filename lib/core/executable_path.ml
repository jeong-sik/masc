(** Executable_path — shell-free executable lookup helpers.

    These helpers intentionally do not mirror shell quirks such as treating an
    empty PATH entry as the current directory. The availability checks answer
    before a spawn, and the actual spawn path remains the authority there.
    [absolute_on_path] gives the file itself, for a caller that hands its path
    to another process. *)

let regular_file_is_executable path =
  try
    let stat = Unix.stat path in
    match stat.Unix.st_kind with
    | Unix.S_REG ->
      Unix.access path [ Unix.X_OK ];
      true
    | Unix.S_DIR
    | Unix.S_CHR
    | Unix.S_BLK
    | Unix.S_LNK
    | Unix.S_FIFO
    | Unix.S_SOCK -> false
  with
  | Unix.Unix_error _ | Sys_error _ -> false
;;

let search_path_separator = if Sys.win32 then ';' else ':'

let split_search_path ?(separator = search_path_separator) raw_path =
  String.split_on_char separator raw_path
;;

(* The first executable regular file named [name] in a directory of [PATH]
   that [admits] lets through. *)
let first_on_path ~getenv ~admits name =
  match getenv "PATH" with
  | None -> None
  | Some raw_path ->
    raw_path
    |> split_search_path
    |> List.find_map (fun dir ->
      if admits dir
      then (
        let path = Filename.concat dir name in
        if regular_file_is_executable path then Some path else None)
      else None)
;;

let path_has_executable ?(getenv = Sys.getenv_opt) name =
  first_on_path ~getenv ~admits:(fun dir -> not (String.equal dir "")) name
  |> Option.is_some
;;

let absolute_on_path ?(getenv = Sys.getenv_opt) name =
  first_on_path ~getenv ~admits:(fun dir -> not (Filename.is_relative dir)) name
;;

let command_available ?(getenv = Sys.getenv_opt) name =
  let name = String.trim name in
  if String.equal name ""
  then false
  else if String.contains name '/'
  then regular_file_is_executable name
  else path_has_executable ~getenv name
;;
