(** Code response transitions on the UI state owner fiber. *)

open Masc_tui_types
module Message_layout = Masc_tui_message_layout

let entries_loaded (state : state) request result =
  state.code_listing
  <- Masc_tui_fetched.complete
       ~equal:code_scope_path_equal
       state.code_listing
       request
       result;
  match result with
  | Ok _
    when code_scope_path_equal
           (Masc_tui_fetched.request_key request)
           (code_listing_key state) ->
    state.code_cursor
    <- max 0 (min state.code_cursor (List.length (code_entries state) - 1))
  | Ok _ | Error _ -> ()
;;

let file_loaded (state : state) request result =
  let path = Masc_tui_fetched.request_key request in
  (* An answer for a file the operator has moved past describes bytes
         that are no longer on screen, and everything below resets the
         scroll, the cursor and the sibling panes to match it. The sibling
         loads already guarded on the open path; this one never did. *)
  if not (Masc_tui_fetched.is_current ~equal:String.equal state.code_file request)
  then ()
  else (
    match result with
    | Ok content ->
      (* Lex once at load: comment and string state crosses rows, so a
             window could not answer. Past the budget the file draws plain
             rather than slowly. *)
      let language =
        if String.length content > 500_000
        then None
        else Masc_tui_code_lexer.language_of_path path
      in
      let rows =
        Masc_tui_code_lexer.rows_of_source ~language content
        |> List.map
             (List.map (fun (text, kind) ->
                Masc.Tui_terminal_text.sanitize_terminal_text text, kind))
      in
      (* [rows] stays a list for the memo scan and the width fold just
             below, both of which read it once front to back. The pane keeps
             the array. *)
      state.code_file
      <- Masc_tui_fetched.complete
           ~equal:String.equal
           state.code_file
           request
           (Ok (Array.of_list rows));
      (* The jump that asked for this file may have named a line; the
             reset and the jump live together so neither overwrites the
             other. Consumed once -- the next plain open starts at the top. *)
      state.code_file_scroll
      <- (match state.code_target_line with
          | Some line -> max 0 (line - 1)
          | None -> 0);
      state.code_file_cursor <- state.code_file_scroll;
      state.code_lsp_note <- None;
      state.code_target_line <- None;
      state.code_file_hscroll <- 0;
      (* The widest row is the horizontal clamp; measured here, once,
             not on every l press over ten thousand rows. *)
      state.code_file_max_width
      <- List.fold_left
           (fun widest segments ->
              let row_width =
                List.fold_left
                  (fun acc (text, _) -> acc + Message_layout.display_width text)
                  0
                  segments
              in
              max widest row_width)
           0
           rows;
      state.code_memos <- Masc_tui_memo.of_file ~path rows;
      state.code_focus_file <- Right_pane;
      (* A new file starts on its content; the old file's history or
             diff would caption the wrong bytes. *)
      state.code_history <- Masc_tui_fetched.clear state.code_history;
      state.code_history_open <- false;
      state.code_history_scroll <- 0;
      state.code_diff <- Masc_tui_fetched.clear state.code_diff;
      state.code_diff_open <- false;
      state.code_diff_scroll <- 0;
      state.code_diff_hscroll <- 0;
      state.code_diff_max_width <- 0;
      state.code_notes_open <- false;
      state.code_notes_scroll <- 0;
      state.code_blame <- Masc_tui_fetched.clear state.code_blame
    | Error detail ->
      state.code_memos <- [];
      state.code_file
      <- Masc_tui_fetched.complete
           ~equal:String.equal
           state.code_file
           request
           (Error detail))
;;

let blame_loaded (state : state) request result =
  (* An answer that arrives after the operator moved on describes bytes
         that are no longer on screen, and a margin naming the wrong authors
         is worse than no margin. Opening a file clears the blame, so a
         request from before that is no longer the one being waited on and
         [complete] drops it -- the hand-written path comparison this arm
         used to carry said the same thing in more places. *)
  state.code_blame
  <- Masc_tui_fetched.complete ~equal:String.equal state.code_blame request result
;;

let lsp_answered
      (state : state)
      ~question
      ~symbol
      ~push_jump
      ~content_height
      ~load_file
      result
  =
  match result with
  | Error detail -> state.code_lsp_note <- Some (symbol ^ ": " ^ detail)
  | Ok (Masc.Tui_decode.Lsp_hover text) ->
    state.code_lsp_note
    <- Some
         (match text with
          | Some t -> symbol ^ ": " ^ Masc.Tui_terminal_text.sanitize_terminal_text t
          | None -> symbol ^ ": the server has nothing to say here")
  | Ok (Masc.Tui_decode.Lsp_locations []) ->
    state.code_lsp_note <- Some (Printf.sprintf "no %s found for %S" question symbol)
  | Ok (Masc.Tui_decode.Lsp_locations (location :: _)) ->
    let open Masc.Tui_decode in
    if location.ll_inside
    then (
      (* Jump there: same file just moves the cursor, another file
                opens with the line as its target. Either way the place the
                jump left from goes on the back stack first. *)
      push_jump ();
      state.code_lsp_note
      <- Some (Printf.sprintf "%s: %s:%d" symbol location.ll_path location.ll_line);
      match Masc_tui_fetched.current state.code_file with
      | Some (open_path, Masc_tui_fetched.Ready rows)
        when String.equal open_path location.ll_path ->
        let cursor = max 0 (min (location.ll_line - 1) (Array.length rows - 1)) in
        state.code_file_cursor <- cursor;
        (* Follow the jump: a definition past the fold is a cursor
                    the operator cannot see otherwise. *)
        state.code_file_scroll
        <- Masc_tui_scroll.ensure_visible
             ~cursor
             ~height:(content_height ())
             state.code_file_scroll
      (* A different file, or this one not readable yet: ask for it.
                [start] answers Already_loading if that is the read already in
                flight, so a jump into the file being read does not double it. *)
      | Some _ | None ->
        state.code_target_line <- Some location.ll_line;
        load_file ~path:location.ll_path)
    else
      (* Outside the workspace (stdlib, a package): say where rather
                than open a path the surface cannot serve. *)
      state.code_lsp_note
      <- Some
           (Printf.sprintf
              "%s: outside the workspace at %s:%d"
              symbol
              location.ll_path
              location.ll_line)
;;

let diff_loaded (state : state) request result =
  let landed =
    Masc_tui_fetched.is_current ~equal:String.equal state.code_diff request
    && Result.is_ok result
  in
  state.code_diff
  <- Masc_tui_fetched.complete ~equal:String.equal state.code_diff request result;
  if landed then begin
    state.code_diff_scroll <- 0;
    state.code_diff_hscroll <- 0;
    state.code_diff_max_width <-
      match result with
      | Error _ -> 0
      | Ok diff ->
          List.fold_left (fun widest (row : Masc.Tui_decode.git_diff_row) ->
            max widest (Message_layout.display_width
              (Masc.Tui_terminal_text.sanitize_terminal_text row.gdr_text))) 0 diff.gd_rows
  end
;;

let history_loaded (state : state) request result =
  (* The scope travels in the key, so a slow answer from a repository the
         operator has left cannot caption the file now open at the same
         relative path. *)
  let landed =
    Masc_tui_fetched.is_current ~equal:code_scope_path_equal state.code_history request
    && Result.is_ok result
  in
  state.code_history
  <- Masc_tui_fetched.complete
       ~equal:code_scope_path_equal
       state.code_history
       request
       result;
  if landed then state.code_history_scroll <- 0
;;
