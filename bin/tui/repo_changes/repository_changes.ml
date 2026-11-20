module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Admission = Masc_tui_transport.Workspace_admission
module Tui_decode = Masc.Tui_decode

let tree_diff_base_ref = "HEAD"

let pr_number_of_subject subject =
  let n = String.length subject in
  let rec scan i best =
    if i >= n then best
    else if
      subject.[i] = '(' && i + 2 < n && subject.[i + 1] = '#'
    then begin
      let rec digits j acc =
        if j < n && subject.[j] >= '0' && subject.[j] <= '9' then
          digits (j + 1) ((acc * 10) + (Char.code subject.[j] - 48))
        else (j, acc)
      in
      let stop, value = digits (i + 2) 0 in
      if value > 0 && stop < n && subject.[stop] = ')' then
        scan (stop + 1) (Some value)
      else scan (i + 1) best
    end
    else scan (i + 1) best
  in
  scan 0 None

(* The codebase slug for the surface's scope, when it has one. Only a
   repository row carries the server-minted slug (the client
   never re-derives it); the other scopes honestly have none. *)
(* Same fiber-and-mailbox shape as the notes read below. Scoped by the same
   keeper / repo axes the file itself was read through, so the margin
   describes the checkout on screen rather than whichever one the server
   would default to. *)
let repository_change_scope_equal left right =
  match left, right with
  | Tui_decode.Repository_change_project, Tui_decode.Repository_change_project ->
      true
  | ( Tui_decode.Repository_change_repository left_id
    , Tui_decode.Repository_change_repository right_id ) ->
      String.equal left_id right_id
  | Tui_decode.Repository_change_project, Tui_decode.Repository_change_repository _
  | Tui_decode.Repository_change_repository _, Tui_decode.Repository_change_project ->
      false

let launch_repository_changes_load (state : T.state) ~mailbox ~scope =
  if T.server_authority_ready state then begin
  let enqueue_async = Admission.workspace_enqueue state in
  let host = Admission.server_peer_host in
  let port = state.T.port in
  Admission.launch_async_read state ~mailbox
    ~deliver:(fun result ->
      enqueue_async mailbox (P.Repository_msg (P.Repository_changes_loaded (scope, result))))
    (fun () ->
      match scope with
      | Tui_decode.Repository_change_project ->
          Masc_tui_loader.load_project_changes ~host ~port
      | Tui_decode.Repository_change_repository repository_id ->
          Masc_tui_loader.load_repository_changes ~host ~port ~repository_id)
  end

let launch_repository_changes_diff_load (state : T.state) ~mailbox ~scope ~path =
  if T.server_authority_ready state then begin
  let enqueue_async = Admission.workspace_enqueue state in
  state.T.repository_changes_diff_generation <- state.T.repository_changes_diff_generation + 1;
  let request =
    { T.rdr_scope = scope; rdr_path = path
    ; rdr_generation = state.T.repository_changes_diff_generation }
  in
  let host = Admission.server_peer_host in
  let port = state.T.port in
  let repo =
    match scope with
    | Tui_decode.Repository_change_repository repository_id -> Some repository_id
    | Tui_decode.Repository_change_project -> None
  in
  Admission.launch_async_read state ~mailbox
    ~deliver:(fun result ->
      enqueue_async mailbox (P.Repository_msg (P.Repository_changes_diff_loaded (request, result))))
    (fun () ->
      Masc_tui_loader.load_git_diff ~host ~port ?repo ~keeper:None ~path
        ~against:(Masc_tui_http.Working_tree_against tree_diff_base_ref) ())
  end

let open_repository_change_diff (state : T.state) ~mailbox ~scope
    (change : Tui_decode.repository_change) =
  state.T.repository_changes_diff <- None;
  state.T.repository_changes_diff_error <- None;
  state.T.repository_changes_diff_path <- Some change.Tui_decode.rc_path;
  state.T.repository_changes_diff_hscroll <- 0;
  state.T.repository_changes_diff_max_width <- 0;
  state.T.repository_changes_diff_scroll <- 0;
  launch_repository_changes_diff_load state ~mailbox ~scope ~path:change.Tui_decode.rc_path

let close_repository_changes_diff (state : T.state) =
  state.T.repository_changes_diff <- None;
  state.T.repository_changes_diff_error <- None;
  state.T.repository_changes_diff_path <- None;
  state.T.repository_changes_diff_hscroll <- 0;
  state.T.repository_changes_diff_max_width <- 0;
  state.T.repository_changes_diff_scroll <- 0

let open_repository_changes (state : T.state) ~mailbox ~scope =
  state.T.repository_changes_open <- true;
  state.T.repository_changes_scope <- Some scope;
  state.T.repository_changes <- None;
  state.T.repository_changes_error <- None;
  state.T.repository_changes_cursor <- 0;
  state.T.repository_changes_scroll <- 0;
  state.T.repository_changes_diff <- None;
  state.T.repository_changes_diff_error <- None;
  state.T.repository_changes_diff_path <- None;
  state.T.repository_changes_diff_hscroll <- 0;
  state.T.repository_changes_diff_max_width <- 0;
  state.T.repository_changes_diff_scroll <- 0;
  launch_repository_changes_load state ~mailbox ~scope

let refresh_repository_changes (state : T.state) ~mailbox =
  match state.T.repository_changes_scope with
  | None -> ()
  | Some scope ->
      (match state.T.repository_changes_diff_path with
       | Some path ->
           launch_repository_changes_diff_load state ~mailbox ~scope ~path
       | None ->
           launch_repository_changes_load state ~mailbox ~scope)

let open_repository_change_in_code (state : T.state) ~mailbox ~scope
    (change : Tui_decode.repository_change) =
  T.set_code_scope state
    (match scope with
     | Tui_decode.Repository_change_project -> T.Code_scope_project
     | Tui_decode.Repository_change_repository repository_id ->
         T.Code_scope_repo repository_id);
  let parent = Filename.dirname change.Tui_decode.rc_path in
  state.T.code_dir <- (if String.equal parent "." then "" else parent);
  state.T.code_cursor <- 0;
  state.T.code_listing <- Masc_tui_fetched.clear state.T.code_listing;
  state.T.code_file <- Masc_tui_fetched.clear state.T.code_file;
  state.T.code_file_resume_intent <- T.Refresh_code_file;
  state.T.code_focus_file <- T.Left_pane;
  T.close_repository_changes state;
  state.T.view <- T.Code;
  Masc_tui_code_requests.launch_entries_load state ~host:Admission.server_peer_host ~deliver:(Admission.deliver_code state mailbox);
  Masc_tui_code_requests.launch_file_load state ~host:Admission.server_peer_host ~deliver:(Admission.deliver_code state mailbox) ~path:change.Tui_decode.rc_path

(* One step back on the Code surface, for Esc and for Left. Both take the step
   [Masc_tui_keys.code_back_step] names; when none is left, [leave] runs. Esc
   passes the way out to the ring parent and Left passes nothing, so Left
   stays on the surface. *)
let step_code_back (state : T.state) ~mailbox ~leave =
  let reload () =
    state.T.code_cursor <- 0;
    state.T.code_listing <- Masc_tui_fetched.clear state.T.code_listing;
    Masc_tui_code_requests.launch_entries_load state ~host:Admission.server_peer_host
      ~deliver:(Admission.deliver_code state mailbox)
  in
  match Masc_tui_keys.code_back_step state with
  | Masc_tui_keys.Close_code_notes -> state.T.code_notes_open <- false
  | Masc_tui_keys.Close_code_diff -> T.close_code_diff state
  | Masc_tui_keys.Close_code_history -> state.T.code_history_open <- false
  | Masc_tui_keys.Return_to_code_tree -> state.T.code_focus_file <- T.Left_pane
  | Masc_tui_keys.Climb_code_directory ->
      (* Up one directory; "." from Filename.dirname means the root, which
         this surface spells "". *)
      let parent = Filename.dirname state.T.code_dir in
      state.T.code_dir <- (if String.equal parent "." then "" else parent);
      reload ()
  | Masc_tui_keys.Climb_to_code_project ->
      (* Above a keeper's or a repository's root sits the project tree the
         surface started on. *)
      T.set_code_scope state T.Code_scope_project;
      reload ()
  | Masc_tui_keys.Leave_code_for_workspace -> leave ()
