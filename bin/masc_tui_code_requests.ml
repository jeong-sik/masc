(** Code reads and language-server requests; completion is delivered to the caller. *)

open Masc_tui_types
open Masc_tui_async_protocol

(* The Code surface's two loads: one directory level, one whole file. Plain
   HTTP GETs forked off the render loop, answered on the async mailbox and
   stamped with what they answer for, so a slow reply cannot dress a newer
   selection. *)
(* The scope, as the two optional query axes the fetchers take. The match
   is exhaustive: a fourth scope must decide its axis here. *)
let code_scope_axes_of = function
  | Code_scope_project -> None, None
  | Code_scope_keeper keeper -> Some keeper, None
  | Code_scope_repo repo -> None, Some repo
;;

let code_scope_axes state = code_scope_axes_of state.code_scope

let launch_file_finder state ~host ~deliver =
  if not (server_authority_ready state) then
    Masc_tui_loader.report_action state "error" "File finder needs a confirmed workspace"
  else begin
    state.code_navigation <- None;
    close_code_finder state;
    let origin = { cfo_workspace = state.workspace_authority;
      cfo_reading = state.workspace_read_authority;
      cfo_scope = state.code_scope; cfo_dir = state.code_dir;
      cfo_file = Masc_tui_fetched.current_request state.code_file } in
    state.palette_open <- true;
    state.palette_mode <- Palette_files origin;
    let expected_workspace = state.server_identity in
    match Masc_tui_fetched.start ~equal:code_scope_path_equal state.code_catalog
            ~key:(origin.cfo_scope, origin.cfo_dir) with
    | Masc_tui_fetched.Already_loading -> ()
    | Masc_tui_fetched.Started (catalog, request) ->
        state.code_catalog <- catalog;
        let port = state.port in
        let keeper, repo = code_scope_axes_of origin.cfo_scope in
        Masc_tui_async_read.launch
          ~deliver:(fun result -> deliver (Code_catalog_loaded (request, result)))
          (fun () -> match expected_workspace with
             | None -> Error "File finder has no workspace identity"
             | Some expected_workspace -> Masc_tui_http.fetch_workspace_file_catalog
                 ?keeper ?repo ~expected_workspace ~host ~port ~path:origin.cfo_dir ())
  end

let open_found_file state ~host ~deliver ~path =
  match state.palette_mode, code_finder_catalog state, state.server_identity with
  | Palette_files origin, Masc_tui_fetched.Ready catalog, Some expected_workspace
      when state.palette_open && code_finder_current state origin
           && List.mem path catalog.Masc.Tui_decode.wfc_files ->
      (match Masc_tui_fetched.start ~equal:code_scope_path_equal state.code_finder_file
               ~key:(origin.cfo_scope, path) with
       | Masc_tui_fetched.Already_loading -> ()
       | Masc_tui_fetched.Started (reading, request) ->
           state.code_finder_file <- reading;
           let port = state.port in
           let keeper, repo = code_scope_axes_of origin.cfo_scope in
           Masc_tui_async_read.launch
             ~deliver:(fun result -> deliver (Code_finder_file_loaded (request, result)))
             (fun () -> Masc_tui_http.fetch_workspace_file ?keeper ?repo
                 ~expected_workspace ~host ~port ~path ()))
  | (Palette_files _ | Palette_locations _ | Palette_jump | Palette_choice _),
    (Masc_tui_fetched.Absent | Masc_tui_fetched.Loading | Masc_tui_fetched.Ready _
    | Masc_tui_fetched.Stale _ | Masc_tui_fetched.Failed _), (Some _ | None) -> ()

let launch_entries_load state ~host ~deliver =
  if server_authority_ready state then begin
  (* Read here, not inside the daemon. The daemon runs later, and the scope it
     read then was whichever one was current by then -- so a request made in
     one scope could be sent under another. *)
  let scope = state.code_scope in
  let dir = state.code_dir in
  (* One listing per key. A request for the key already loading is not sent
     twice; a request for any other key is, and the answer to the one it
     replaced is dropped when it lands. *)
  match
    Masc_tui_fetched.start
      ~equal:code_scope_path_equal
      state.code_listing
      ~key:(scope, dir)
  with
  | Masc_tui_fetched.Already_loading -> ()
  | Masc_tui_fetched.Started (listing, request) ->
    state.code_listing <- listing;
    let port = state.port in
    Masc_tui_async_read.launch
      ~deliver:(fun result -> deliver (Code_entries_loaded (request, result)))
      (fun () ->
         let keeper, repo = code_scope_axes_of scope in
         Masc_tui_http.fetch_workspace_entries ?keeper ?repo ~host ~port ~path:dir ())
  end

;;

let launch_navigation_read state ~host ~deliver owner request =
  let expected_workspace = state.server_identity in
  let port = state.port in
  let keeper, repo = code_scope_axes_of owner.cno_destination.cj_scope in
  let path = Masc_tui_fetched.request_key request in
  Masc_tui_async_read.launch
    ~deliver:(fun result -> deliver (Code_file_loaded (Navigate_code_file owner, request, result)))
    (fun () -> match expected_workspace with
       | None -> Error "Navigation has no workspace identity"
       | Some expected_workspace ->
           Masc_tui_http.fetch_workspace_file ?keeper ?repo
             ~expected_workspace ~host ~port ~path ())

let return_to_reading state ~host ~deliver =
  match Masc_tui_code_results.start_return state with
  | Masc_tui_code_results.No_return -> ()
  | Masc_tui_code_results.Return_committed -> launch_entries_load state ~host ~deliver
  | Masc_tui_code_results.Read_navigation_file (owner, request) ->
      launch_navigation_read state ~host ~deliver owner request

let launch_file_load ?(intent = Open_code_file) state ~host ~deliver ~path =
  if not (server_authority_ready state) then
    Masc_tui_loader.report_action state "error"
      "Cannot open Code file while workspace identity is unconfirmed; retry after reconnecting"
  else begin
  state.code_navigation <- None;
  let scope = state.code_scope in
  let expected_workspace = state.server_identity in
  match Masc_tui_fetched.start ~equal:String.equal state.code_file ~key:path with
  | Masc_tui_fetched.Already_loading -> ()
  | Masc_tui_fetched.Started (next, request) ->
    state.code_file <- next;
    Option.iter (fun address -> state.code_saved_refreshes <- List.filter
      (fun pending -> not (Masc_tui_code_draft.equal_address address pending)) state.code_saved_refreshes)
      (code_draft_address state);
    state.code_file_resume_intent <- intent;
    let port = state.port in
    Masc_tui_async_read.launch
      ~deliver:(fun result -> deliver (Code_file_loaded (intent, request, result)))
      (fun () ->
         let keeper, repo = code_scope_axes_of scope in
         match expected_workspace with
         | None -> Error "Code has no confirmed workspace identity"
         | Some expected_workspace -> Masc_tui_http.fetch_workspace_file ?keeper ?repo
             ~expected_workspace ~host ~port ~path ())
  end

;;

(* The 50-commit first page covers the pane; the route caps at 200 anyway. *)
let code_history_limit = 50

let code_file_activity_address scope path =
  match scope with
  | Code_scope_repo repo_id -> Ok (Some repo_id, path)
  | Code_scope_keeper _ ->
    (match Playground_paths.parse_bundle_relative_repo_path path with
     | Some (repo_id, relative_path) -> Ok (Some repo_id, relative_path)
     | None ->
       Error
         "this Keeper file is outside a registered repository clone, so it has no shared \
          repository address")
  | Code_scope_project -> Ok (None, path)
;;

let code_history_entry_at_ms = function
  | Hist_commit (row : Masc.Tui_decode.git_log_row) -> row.gl_at_ms
  | Hist_keeper_change (change : Masc.Tui_decode.file_change) -> change.fc_at *. 1000.
;;

let launch_history_load state ~host ~deliver ~path =
  if server_authority_ready state then begin
  let scope = state.code_scope in
  match
    Masc_tui_fetched.start
      ~equal:code_scope_path_equal
      state.code_history
      ~key:(scope, path)
  with
  | Masc_tui_fetched.Already_loading -> ()
  | Masc_tui_fetched.Started (next, request) ->
    state.code_history <- next;
    let port = state.port in
    let activity_address = code_file_activity_address scope path in
    Masc_tui_async_read.launch
      ~deliver:(fun result -> deliver (Code_history_loaded (request, result)))
      (fun () ->
         let keeper, repo = code_scope_axes_of scope in
         let git =
           Masc_tui_http.fetch_git_log
             ?keeper
             ?repo
             ~host
             ~port
             ~path
             ~limit:code_history_limit
             ()
         in
         let commits, chl_git_error = match git with
           | Ok commits -> commits, None
           | Error detail -> [], Some detail
         in
         let changes, chl_activity_note =
           match activity_address with
           | Error detail -> [], "Keeper activity unavailable: " ^ detail
           | Ok (repo_id, file_path) ->
             (match
                Masc_tui_http.fetch_ide_file_activity ~host ~port ~repo_id ~file_path
              with
              | Error detail -> [], "Keeper activity unavailable: " ^ detail
              | Ok snapshot ->
                let incomplete =
                  snapshot.fas_incomplete_over_budget
                  + snapshot.fas_incomplete_malformed
                in
                let unattributed =
                  snapshot.fas_unattributed_over_budget
                  + snapshot.fas_unattributed_malformed
                in
                let missing_note =
                  [ (if incomplete = 0
                     then None
                     else
                       Some
                         (Printf.sprintf
                            "%d exact-address row%s incomplete"
                            incomplete
                            (if incomplete = 1 then "" else "s")))
                  ; (if unattributed = 0
                     then None
                     else
                       Some
                         (Printf.sprintf
                            "%d fleet row%s had no readable address"
                            unattributed
                            (if unattributed = 1 then "" else "s")))
                  ]
                  |> List.filter_map Fun.id
                  |> function
                  | [] -> ""
                  | notes -> "; " ^ String.concat "; " notes
                in
                ( snapshot.fas_changes
                , Printf.sprintf
                    "Keeper activity: %.0fh durable window, %d exact change%s%s"
                    snapshot.fas_window_hours
                    (List.length snapshot.fas_changes)
                    (if List.length snapshot.fas_changes = 1 then "" else "s")
                    missing_note ))
         in
         let chl_entries =
           List.stable_sort
             (fun a b ->
                Float.compare (code_history_entry_at_ms b) (code_history_entry_at_ms a))
             (List.map (fun c -> Hist_commit c) commits
              @ List.map (fun change -> Hist_keeper_change change) changes)
         in
         Ok { chl_entries; chl_git_error; chl_activity_note })
  end

;;

let launch_diff_load state ~host ~deliver ~base_ref ~path =
  if server_authority_ready state then begin
  match Masc_tui_fetched.start ~equal:String.equal state.code_diff ~key:path with
  | Masc_tui_fetched.Already_loading -> ()
  | Masc_tui_fetched.Started (next, request) ->
    state.code_diff <- next;
    let port = state.port in
    Masc_tui_async_read.launch
      ~deliver:(fun result -> deliver (Code_diff_loaded (request, result)))
      (fun () ->
         let keeper, repo = code_scope_axes state in
         Masc_tui_loader.load_git_diff ?repo ~host ~port ~keeper ~path ~base_ref ())
  end

;;

(* Same fiber-and-mailbox shape as the notes read below. Scoped by the same
   keeper / repo axes the file itself was read through, so the margin
   describes the checkout on screen rather than whichever one the server
   would default to. *)
let launch_blame_load state ~host ~deliver ~path =
  if server_authority_ready state then begin
  match Masc_tui_fetched.start ~equal:String.equal state.code_blame ~key:path with
  | Masc_tui_fetched.Already_loading -> ()
  | Masc_tui_fetched.Started (next, request) ->
    state.code_blame <- next;
    let port = state.port in
    let keeper, repo = code_scope_axes state in
    Masc_tui_async_read.launch
      ~deliver:(fun result -> deliver (Code_blame_loaded (request, result)))
      (fun () -> Masc_tui_http.fetch_git_blame ?keeper ?repo ~host ~port ~path ())
  end

;;

(* Ask the language server about [symbol] on the pane's cursor line. The
   question rides the surface's workspace axes, so a keeper checkout and a
   repository ask about their own bytes. *)
let start_lsp_question
      ?line
      state
      ~host
      ~deliver
      ~report
      ~(question : string)
      ~(symbol : string)
  =
  if server_authority_ready state then begin
  match Masc_tui_fetched.current_key state.code_file with
  | None -> report "error" "no file is open on the Code surface"
  | Some path ->
    (match Masc_tui_code_results.start_lsp_question ?line state ~question ~symbol with
     | None -> ()
     | Some request ->
       let query = Masc_tui_fetched.request_key request in
       let port = state.port in
       let line = query.clq_line in
       let keeper, repo = code_scope_axes state in
       let run () =
         let result =
           try
             Masc_tui_http.fetch_lsp_question
               ?keeper
               ?repo
               ~host
               ~port
               ~path
               ~line
               ~symbol
               ~question
               ()
           with
           | Eio.Cancel.Cancelled _ as exn -> raise exn
           | exn -> Error (Printexc.to_string exn)
         in
         deliver (Code_lsp_answered (request, result))
       in
       (match Eio_context.get_switch_opt () with
        | Some sw ->
          Eio.Fiber.fork_daemon ~sw (fun () ->
            run ();
            `Stop_daemon)
        | None -> deliver (Code_lsp_answered (request, Error "Eio switch is unavailable"))))
  end

;;

let save_draft state ~host ~deliver =
  let ( let* ) = Result.bind in
  let* request, draft = Masc_tui_code_results.begin_draft_save state in
  let authority = state.workspace_authority in
  let reading = state.workspace_read_authority in
  let port = state.port in
  Masc_tui_async_read.launch
    ~deliver:(fun result -> deliver (Code_draft_saved (request,
      match result with Ok outcome -> outcome | Error detail -> Masc_tui_code_draft.Save_uncertain detail)))
    (fun () ->
      if authority <> state.workspace_authority || reading != state.workspace_read_authority then
        Ok (Masc_tui_code_draft.Save_refused "Workspace authority changed before sending the save")
      else match write_authority_refusal state authority with
        | Some detail -> Ok (Masc_tui_code_draft.Save_refused detail)
        | None -> Ok (Masc_tui_http.save_workspace_file_draft ~host ~port draft));
  Ok ()

let reread_draft state ~host ~deliver =
  match current_code_draft state with
  | None -> Error "No draft for this file"
  | Some _ when not (server_authority_ready state) ->
    Error "Confirm the workspace before rereading the draft's file"
  | Some draft -> match Masc_tui_code_draft.phase draft with
    | Masc_tui_code_draft.Saving _ -> Error "Wait for the submitted save before rereading"
    | Masc_tui_code_draft.Editable | Masc_tui_code_draft.Rejected _ | Masc_tui_code_draft.Needs_review _ ->
      state.code_file <- Masc_tui_fetched.cancel_pending
        ~reason:"Superseded by draft comparison" state.code_file;
      let address = Masc_tui_code_draft.address draft in
      launch_file_load ~intent:Refresh_code_file state ~host ~deliver ~path:address.path;
      state.code_draft_review <- Option.map (fun request -> draft, request)
        (Masc_tui_fetched.current_request state.code_file);
      Ok ()
