(* HIGH-RISK-UNREVIEWED: see the interface. *)

type client =
  | Codex_home
  | Claude_home
  | Muse_home

let clients_dir = "official-clients"

let client_dir = function
  | Codex_home -> "codex"
  | Claude_home -> "claude"
  | Muse_home -> "muse"
;;

let accounts_dir = "accounts"

let person_runtime_root ~base_path ~namespace =
  List.fold_left
    Filename.concat
    (Common.masc_dir_from_base_path ~base_path)
    [ accounts_dir; Authz_types.Account_home_namespace.to_string namespace ]
;;

(* The parts of a path: [.] and the empty parts of a doubled or trailing slash
   are dropped, and [..] stays a part. *)
let parts path =
  List.filter (fun part -> part <> "" && part <> ".") (String.split_on_char '/' path)
;;

let rec leads_into ~ancestor parts =
  match ancestor, parts with
  | [], (_ : string list) -> true
  | _ :: _, [] -> false
  | top :: ancestor, part :: parts -> String.equal top part && leads_into ~ancestor parts
;;

(* The real path of the deepest part of [path] that is there, and the parts
   under it as spelled. [None] when no part is there to read. *)
let rec real_spelling path =
  match Unix.realpath path with
  | real -> Some real
  | exception (Unix.Unix_error _ | Sys_error _) ->
    let parent = Filename.dirname path in
    if String.equal parent path
    then None
    else
      Option.map
        (fun real -> Filename.concat real (Filename.basename path))
        (real_spelling parent)
;;

let under_persons ~base_path home =
  let persons = Filename.concat (Common.masc_dir_from_base_path ~base_path) accounts_dir in
  let spellings path = path :: Option.to_list (real_spelling path) in
  List.exists
    (fun ancestor ->
      List.exists
        (fun home -> leads_into ~ancestor:(parts ancestor) (parts home))
        (spellings home))
    (spellings persons)
;;

type persons_unread =
  | Not_a_directory
  | Unreadable of Unix.error

let persons_unread_to_string = function
  | Not_a_directory -> "it is not a directory"
  | Unreadable error -> Unix.error_message error
;;

let persons_remain ~base_path =
  let persons = Filename.concat (Common.masc_dir_from_base_path ~base_path) accounts_dir in
  match Unix.opendir persons with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false
  | exception Unix.Unix_error (Unix.ENOTDIR, _, _) -> Error Not_a_directory
  | exception Unix.Unix_error (error, _, _) -> Error (Unreadable error)
  | handle ->
    let rec entry () =
      match Unix.readdir handle with
      | "." | ".." -> entry ()
      | (_ : string) -> Ok true
      | exception End_of_file -> Ok false
      | exception Unix.Unix_error (error, _, _) -> Error (Unreadable error)
    in
    let answer = entry () in
    (* The answer was read before the close, so a failed close changes nothing. *)
    (try Unix.closedir handle with
     | Unix.Unix_error _ -> ());
    answer
;;

let home ~runtime_root client ~account_id =
  if not (Fs_compat.is_capability_leaf account_id)
  then Error "Invalid login account identity."
  else if Filename.is_relative runtime_root
  then Error "The runtime directory must be absolute."
  else (
    match Unix.realpath runtime_root with
    | exception (Unix.Unix_error _ | Sys_error _) ->
      Error "The runtime directory is unavailable."
    | root -> Ok (List.fold_left Filename.concat root [ clients_dir; client_dir client; account_id ]))
;;
