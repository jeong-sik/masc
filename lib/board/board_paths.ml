(* Board persistence path resolvers.

   Extracted from [Board_core] to shrink the godfile. Pure
   path-string + filesystem-side-effect helpers. *)

let board_base_path () = Env_config_core.base_path ()

let board_masc_dir () =
  Common.masc_dir_from_base_path ~base_path:(board_base_path ())
;;

let capture_workspace_masc_dir workspace_masc_dir =
  if String.equal workspace_masc_dir "" then
    invalid_arg "Board_paths.capture_workspace_masc_dir: workspace_masc_dir must not be empty";
  let workspace_masc_dir =
    if Filename.is_relative workspace_masc_dir then
      Filename.concat (Sys.getcwd ()) workspace_masc_dir
    else workspace_masc_dir
  in
  Fs_compat.realpath_lenient workspace_masc_dir
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

let posts_file ~workspace_masc_dir = file_path ~workspace_masc_dir Posts

let posts_initialization_guard_file ~workspace_masc_dir =
  Filename.concat workspace_masc_dir "board_posts.initialized.jsonl"

let workspace_masc_dir (store : Board_types.store) =
  Board_workspace_binding.workspace_masc_dir store.workspace_binding

let observe_workspace (store : Board_types.store) =
  let observed = match store.posts_source with
    | Posts_unobserved -> None
    | Posts_readable { observation; _ } -> Some observation
    | Posts_refused { last_observed; _ } | Posts_unsettled { last_observed; _ } -> last_observed
  in
  match observed with
  | None -> Board_workspace_binding.observe store.workspace_binding
  | Some observation ->
    Result.map (fun () -> observation.Board_types.workspace_observation)
      (Board_workspace_binding.revalidate store.workspace_binding observation.workspace_observation)

let check_workspace store = Result.map (fun _ -> ()) (observe_workspace store)

let store_file_path store file =
  file_path ~workspace_masc_dir:(workspace_masc_dir store) file

let persist_path store = store_file_path store Posts
let comments_path store = store_file_path store Comments
let reactions_path store = store_file_path store Reactions
let sub_boards_path store = store_file_path store Sub_boards

let ensure_dir path =
  if String.equal path "" || String.equal path "." || String.equal path "/"
  then ()
  else Fs_compat.mkdir_p path
;;

let ensure_masc_dir (store : Board_types.store) =
  let open Result.Syntax in
  let* () = check_workspace store in
  let dir = workspace_masc_dir store in
  ensure_dir (Filename.dirname dir);
  ensure_dir dir;
  Ok ()
;;
