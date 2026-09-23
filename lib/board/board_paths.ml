(* Board persistence path resolvers.

   Extracted from [Board_core] to shrink the godfile. Pure
   path-string + filesystem-side-effect helpers. *)

let board_base_path () = Env_config_core.base_path ()

let board_masc_dir () =
  Workspace_utils.masc_root_dir_from
    ~base_path:(board_base_path ())
    ~cluster_name:(Env_config_core.cluster_name ())
;;

type persisted_file = Posts | Comments | Reactions | Sub_boards | Votes
let file_path ~workspace_masc_dir file =
  let filename = match file with
    | Posts -> "board_posts.jsonl"
    | Comments -> "board_comments.jsonl"
    | Reactions -> "board_reactions.jsonl"
    | Sub_boards -> "board_sub_boards.jsonl"
    | Votes -> "board_votes.jsonl" in
  Filename.concat workspace_masc_dir filename

let store_file_path (store : Board_types.store) file =
  let workspace_masc_dir = match store.workspace_masc_dir with
    | Some workspace -> workspace
    | None -> board_masc_dir () in
  file_path ~workspace_masc_dir file

let persist_path () = file_path ~workspace_masc_dir:(board_masc_dir ()) Posts
let comments_path () = file_path ~workspace_masc_dir:(board_masc_dir ()) Comments
let reactions_path () = file_path ~workspace_masc_dir:(board_masc_dir ()) Reactions
let sub_boards_path () = file_path ~workspace_masc_dir:(board_masc_dir ()) Sub_boards

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
