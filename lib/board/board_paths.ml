(* Board persistence path resolvers.

   Extracted from [Board_core] to shrink the godfile. Pure
   path-string + filesystem-side-effect helpers. *)

let board_base_path () = Env_config_core.base_path ()

let board_masc_dir () =
  Workspace_utils.masc_root_dir_from
    ~base_path:(board_base_path ())
    ~cluster_name:(Env_config_core.cluster_name ())
;;

let persist_path () = Filename.concat (board_masc_dir ()) "board_posts.jsonl"
let comments_path () = Filename.concat (board_masc_dir ()) "board_comments.jsonl"
let reactions_path () = Filename.concat (board_masc_dir ()) "board_reactions.jsonl"
let signal_outbox_path () =
  Filename.concat (board_masc_dir ()) "board_signal_outbox_v2.jsonl"
;;
let sub_boards_path () = Filename.concat (board_masc_dir ()) "board_sub_boards.jsonl"

let ensure_dir path =
  if String.equal path "" || String.equal path "." || String.equal path "/"
  then ()
  else Fs_compat.mkdir_p path
;;

let ensure_masc_dir () =
  let base = board_base_path () in
  let dir = board_masc_dir () in
  ensure_dir base;
  ensure_dir dir
;;
