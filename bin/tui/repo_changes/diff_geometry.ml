module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Admission = Masc_tui_transport.Workspace_admission
module Tui_decode = Masc.Tui_decode
module Message_layout = Masc_tui_message_layout
module Terminal_text = Masc_tui_ansi.Terminal_text

let diff_text_max_width text =
  String.split_on_char '\n' text
  |> List.fold_left (fun widest line ->
       max widest (Message_layout.display_width (Terminal_text.single_line line))) 0

let git_diff_body_max_width (diff : Tui_decode.git_diff) =
  List.fold_left (fun widest (row : Tui_decode.git_diff_row) ->
    max widest (Message_layout.display_width
      (Terminal_text.single_line row.Tui_decode.gdr_text))) 0 diff.Tui_decode.gd_rows

let refresh_recorded_diff_bounds (state : T.state) ~reset =
  let width = match T.opened_file_change state with
    | None -> 0
    | Some change ->
        (match change.Tui_decode.fc_kind with
         | Tui_decode.Fc_edited { before; after; _ } ->
             max (diff_text_max_width before) (diff_text_max_width after)
         | Tui_decode.Fc_inserted { text; _ } -> diff_text_max_width text
         | Tui_decode.Fc_written { content } -> diff_text_max_width content
         | Tui_decode.Fc_materialized _ -> 0) in
  state.T.changes_diff_max_width <- width;
  state.T.changes_diff_hscroll <-
    if reset then 0
    else min state.T.changes_diff_hscroll (max 0 (width - 1))

(* Where the change is on this machine.

   All three shapes resolve inside the keeper's own bundle, because that is
   where the write happened. An operator's checkout of the same repository is
   a different tree and this surface does not know where it is; naming the
   keeper's copy is the answer that is true.

   A Docker keeper's bundle is not on this filesystem at all, so the path may
   not exist. The caller checks before handing it to an editor rather than
   opening an empty buffer under a real file's name. *)
let change_absolute_path ~base_path (change : Tui_decode.file_change) =
  let bundle =
    Filename.concat base_path
      (Playground_paths.bundle_root change.Tui_decode.fc_keeper)
  in
  match change.Tui_decode.fc_location with
  | Tui_decode.Fc_at_absolute_path { path } -> path
  | Tui_decode.Fc_in_bundle { bundle_path } -> Filename.concat bundle bundle_path
  | Tui_decode.Fc_in_repo { repo_id; relative_path } ->
      Filename.concat bundle
        (Playground_paths.bundle_relative_repo_path ~repo_id relative_path)

(* The address the git-diff read wants: relative to the keeper's playground,
   because that is the root the server resolves ?keeper= against. Absolute
   writes have no such address -- a worktree beside the clones is not under
   the playground -- so they have no tree reading either, and the caller is
   told rather than sent a path the server would resolve somewhere else. *)
let change_bundle_relative_path (change : Tui_decode.file_change) =
  match change.Tui_decode.fc_location with
  | Tui_decode.Fc_in_bundle { bundle_path } -> Some bundle_path
  | Tui_decode.Fc_in_repo { repo_id; relative_path } ->
      Some (Playground_paths.bundle_relative_repo_path ~repo_id relative_path)
  | Tui_decode.Fc_at_absolute_path _ -> None

(* What the tree holds for one file, against its last commit. HEAD rather
   than a branch point: the question the surface answers is "did this survive
   into the tree", and a merge base would answer a different one. *)
let launch_git_diff_load (state : T.state) ~mailbox ~keeper ~path =
  if T.server_authority_ready state then begin
  let enqueue_async = Admission.workspace_enqueue state in
  let host = Admission.server_peer_host in
  let port = state.T.port in
  Admission.launch_async_read state ~mailbox
    ~deliver:(fun result ->
      enqueue_async mailbox (P.Git_diff_loaded (path, result)))
    (fun () ->
      Masc_tui_loader.load_git_diff ~host ~port ~keeper ~path
        ~against:(Masc_tui_http.Working_tree_against Repository_changes.tree_diff_base_ref) ())
  end
