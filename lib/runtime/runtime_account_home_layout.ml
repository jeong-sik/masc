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
