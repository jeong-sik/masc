(* Board persistence path resolvers and JSONL rotation policy.

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

(** Max JSONL file size before rotation (10 MB).
    Prevents unbounded disk growth from agent feedback loops. *)
let max_jsonl_bytes = 10 * 1024 * 1024

(** Rotate a JSONL file if it exceeds [max_jsonl_bytes].
    Keeps one backup (.1) and truncates the active file.
    Safe: uses rename (atomic on same filesystem). *)
let rotate_if_needed path =
  try
    let st = Unix.stat path in
    if st.Unix.st_size > max_jsonl_bytes
    then (
      let backup = path ^ ".1" in
      (try Sys.rename backup (path ^ ".2") with
       | Sys_error _ -> ());
      Sys.rename path backup;
      Log.BoardLog.info "rotated %s (was %d bytes)" path st.Unix.st_size)
  with
  | Unix.Unix_error (e, fn, arg) ->
    Log.BoardLog.warn "rotate error: %s(%s): %s" fn arg (Unix.error_message e)
  | Sys_error msg -> Log.BoardLog.warn "rotate error: %s" msg
;;
