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

let launch_entries_load state ~host ~deliver =
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
;;

let launch_file_load state ~host ~deliver ~path =
  match Masc_tui_fetched.start ~equal:String.equal state.code_file ~key:path with
  | Masc_tui_fetched.Already_loading -> ()
  | Masc_tui_fetched.Started (next, request) ->
    state.code_file <- next;
    let port = state.port in
    Masc_tui_async_read.launch
      ~deliver:(fun result -> deliver (Code_file_loaded (request, result)))
      (fun () ->
         let keeper, repo = code_scope_axes state in
         Masc_tui_http.fetch_workspace_file ?keeper ?repo ~host ~port ~path ())
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
         match
           Masc_tui_http.fetch_git_log
             ?keeper
             ?repo
             ~host
             ~port
             ~path
             ~limit:code_history_limit
             ()
         with
         | Error detail -> Error detail
         | Ok commits ->
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
           Ok { chl_entries; chl_activity_note })
;;

let launch_diff_load state ~host ~deliver ~base_ref ~path =
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
;;

(* Same fiber-and-mailbox shape as the notes read below. Scoped by the same
   keeper / repo axes the file itself was read through, so the margin
   describes the checkout on screen rather than whichever one the server
   would default to. *)
let launch_blame_load state ~host ~deliver ~path =
  match Masc_tui_fetched.start ~equal:String.equal state.code_blame ~key:path with
  | Masc_tui_fetched.Already_loading -> ()
  | Masc_tui_fetched.Started (next, request) ->
    state.code_blame <- next;
    let port = state.port in
    let keeper, repo = code_scope_axes state in
    Masc_tui_async_read.launch
      ~deliver:(fun result -> deliver (Code_blame_loaded (request, result)))
      (fun () -> Masc_tui_http.fetch_git_blame ?keeper ?repo ~host ~port ~path ())
;;

(* Ask the language server about [symbol] on the pane's cursor line. The
   question rides the surface's workspace axes, so a keeper checkout and a
   repository ask about their own bytes. *)
let start_lsp_question
      state
      ~host
      ~deliver
      ~report
      ~(question : string)
      ~(symbol : string)
  =
  match Masc_tui_fetched.current_key state.code_file with
  | None -> report "error" "no file is open on the Code surface"
  | Some path ->
    state.code_lsp_note <- Some (Printf.sprintf "asking %s about %S" question symbol);
    let port = state.port in
    let line = state.code_file_cursor + 1 in
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
      deliver (Code_lsp_answered (question, symbol, result))
    in
    (match Eio_context.get_switch_opt () with
     | Some sw ->
       Eio.Fiber.fork_daemon ~sw (fun () ->
         run ();
         `Stop_daemon)
     | None ->
       deliver (Code_lsp_answered (question, symbol, Error "Eio switch is unavailable")))
;;
