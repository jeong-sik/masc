(* HIGH-RISK-UNREVIEWED: see the interface. *)

type client =
  | Codex_home
  | Claude_home

let clients_dir = "official-clients"

let client_dir = function
  | Codex_home -> "codex"
  | Claude_home -> "claude"
;;

let accounts_dir = "accounts"

let person_runtime_root ~base_path ~namespace =
  List.fold_left
    Filename.concat
    (Common.masc_dir_from_base_path ~base_path)
    [ accounts_dir; Authz_types.Account_home_namespace.to_string namespace ]
;;

(* The canonical lexical parts of a path: [.], empty segments, and [..] parent
   segments are resolved so [other/../accounts/...] cannot disguise a path under
   [accounts/] as a sibling directory. *)
let parts path =
  let absolute = String.length path > 0 && Char.equal path.[0] '/' in
  let rec fold acc = function
    | [] -> List.rev acc
    | ("" | ".") :: rest -> fold acc rest
    | ".." :: rest ->
      (match acc, absolute with
       | ".." :: _, false -> fold (".." :: acc) rest
       | _ :: tail, _ -> fold tail rest
       | [], true -> fold [] rest
       | [], false -> fold [ ".." ] rest)
    | part :: rest -> fold (part :: acc) rest
  in
  fold [] (String.split_on_char '/' path)
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

let persons_remain ~base_path =
  let persons = Filename.concat (Common.masc_dir_from_base_path ~base_path) accounts_dir in
  match Unix.lstat persons with
  | (_ : Unix.stats) -> Ok true
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false
  | exception Unix.Unix_error (error, _, _) -> Error error
;;

(* The real path of a runtime root: every path under it is spelled from this
   one spelling. *)
let real_root runtime_root =
  if Filename.is_relative runtime_root
  then Error "The runtime directory must be absolute."
  else (
    match Unix.realpath runtime_root with
    | exception (Unix.Unix_error _ | Sys_error _) ->
      Error "The runtime directory is unavailable."
    | root -> Ok root)
;;

let home ~runtime_root client ~account_id =
  if not (Fs_compat.is_capability_leaf account_id)
  then Error "Invalid login account identity."
  else
    Result.map
      (fun root -> List.fold_left Filename.concat root [ clients_dir; client_dir client; account_id ])
      (real_root runtime_root)
;;

let api_keys_dir = "api-keys"

let key_dir ~runtime_root ~account_id =
  Result.map
    (fun root ->
      List.fold_left
        Filename.concat
        root
        [ api_keys_dir; Authz_types.Provider_account_id.to_string account_id ])
    (real_root runtime_root)
;;

let key_file ~runtime_root ~account_id ~generation =
  Result.map
    (fun dir ->
      Filename.concat dir (string_of_int (Authz_types.Key_generation.to_int generation)))
    (key_dir ~runtime_root ~account_id)
;;
