(** Code reply application. Request identity remains the admission boundary;
    the loop executes the explicit followup for layout or a new file read. *)

open Masc_tui_types
module Message_layout = Masc_tui_message_layout

type followup = No_followup | Reveal_cursor | Load_file of string

let push_code_jump state =
  state.code_return <- None;
  state.code_jump_back <-
    { cj_scope = state.code_scope; cj_dir = state.code_dir;
      cj_file = Masc_tui_fetched.current_key state.code_file;
      cj_cursor = state.code_file_cursor; cj_scroll = state.code_file_scroll;
      cj_hscroll = state.code_file_hscroll; cj_tree_cursor = state.code_cursor;
      cj_focus = state.code_focus_file } :: state.code_jump_back

type return_followup =
  | No_return
  | Return_committed
  | Read_return_file of code_return_owner * string Masc_tui_fetched.request

let return_owner_current state owner =
  code_finder_current state owner.cro_origin
  && state.code_jump_back == owner.cro_history

let restore_position state target =
  let last_line = match Masc_tui_fetched.current state.code_file with
    | Some (_, (Masc_tui_fetched.Ready rows | Masc_tui_fetched.Stale (rows, _))) ->
        max 0 (Array.length rows - 1)
    | None | Some (_, (Masc_tui_fetched.Absent | Masc_tui_fetched.Loading
                    | Masc_tui_fetched.Failed _)) -> 0 in
  let clamp last value = max 0 (min last value) in
  state.code_file_cursor <- clamp last_line target.cj_cursor;
  state.code_file_scroll <- clamp last_line target.cj_scroll;
  state.code_file_hscroll <- clamp (max 0 (state.code_file_max_width - 1)) target.cj_hscroll;
  state.code_cursor <- max 0 target.cj_tree_cursor;
  state.code_focus_file <- target.cj_focus;
  state.code_target_line <- None

let commit_return_location state target rest =
  let changed = state.code_scope <> target.cj_scope
    || not (String.equal state.code_dir target.cj_dir) in
  state.code_return <- None;
  set_code_scope state target.cj_scope;
  state.code_dir <- target.cj_dir;
  state.code_jump_back <- rest;
  if changed then state.code_listing <- Masc_tui_fetched.clear state.code_listing

let start_return state =
  if not (server_authority_ready state) then begin
    state.code_lsp_note <- Some "Cannot return until the workspace is confirmed";
    No_return
  end else match state.code_return with
  | Some reading when return_owner_current state reading.crr_owner -> No_return
  | Some _ | None ->
    state.code_return <- None;
    match state.code_jump_back with
    | [] -> state.code_lsp_note <- Some "No jump to return from"; No_return
    | target :: rest ->
      match target.cj_file with
      | None ->
          commit_return_location state target rest;
          state.code_file <- Masc_tui_fetched.clear state.code_file;
          state.code_file_resume_intent <- Refresh_code_file;
          restore_position state target;
          state.code_focus_file <- Left_pane;
          Return_committed
      | Some path ->
        match Masc_tui_fetched.current state.code_file with
        | Some (current, Masc_tui_fetched.Ready _)
            when state.code_scope = target.cj_scope && String.equal current path ->
            commit_return_location state target rest;
            restore_position state target;
            Return_committed
        | None | Some (_, (Masc_tui_fetched.Absent | Masc_tui_fetched.Loading
                         | Masc_tui_fetched.Ready _ | Masc_tui_fetched.Stale _
                         | Masc_tui_fetched.Failed _)) ->
          let owner = { cro_origin = {
            cfo_workspace = state.workspace_authority;
            cfo_reading = state.workspace_read_authority;
            cfo_scope = state.code_scope; cfo_dir = state.code_dir;
            cfo_file = Masc_tui_fetched.current_request state.code_file };
            cro_history = state.code_jump_back } in
          match Masc_tui_fetched.start ~equal:String.equal Masc_tui_fetched.initial ~key:path with
          | Masc_tui_fetched.Already_loading -> No_return
          | Masc_tui_fetched.Started (file, request) ->
              state.code_return <- Some { crr_owner = owner; crr_file = file };
              state.code_lsp_note <- Some ("Returning to "
                ^ Masc.Tui_terminal_text.sanitize_terminal_text path);
              Read_return_file (owner, request)

let apply_return_file state owner request result =
  match state.code_return with
  | Some reading when reading.crr_owner == owner && return_owner_current state owner
      && Masc_tui_fetched.is_current ~equal:String.equal reading.crr_file request ->
      (match result with
       | Error detail ->
           state.code_return <- None;
           state.code_lsp_note <- Some ("Return failed: "
             ^ Masc.Tui_terminal_text.sanitize_terminal_text detail)
       | Ok _ ->
           state.code_return <- Some { reading with crr_file =
             Masc_tui_fetched.complete ~equal:String.equal reading.crr_file request result })
  | Some _ | None -> ()

let apply_entries (state : state) request result =
  state.code_listing <-
    Masc_tui_fetched.complete ~equal:code_scope_path_equal
      state.code_listing request result;
  (match result with
   | Ok _
     when code_scope_path_equal
            (Masc_tui_fetched.request_key request)
            (code_listing_key state) ->
       state.code_cursor <-
         max 0
           (min state.code_cursor (List.length (code_entries state) - 1))
   | Ok _ | Error _ -> ())

;;

let apply_catalog (state : state) request result =
  match state.palette_mode with
  | Palette_files origin
      when state.palette_open && code_finder_current state origin
           && code_scope_path_equal (origin.cfo_scope, origin.cfo_dir)
                (Masc_tui_fetched.request_key request) ->
      state.code_catalog <- Masc_tui_fetched.complete ~equal:code_scope_path_equal
          state.code_catalog request result
  | Palette_files _ | Palette_jump | Palette_choice _ -> ()

let apply_open_file ~preserve_view (state : state) request result = (
  let path = Masc_tui_fetched.request_key request in
  (* An answer for a file the operator has moved past describes bytes
     that are no longer on screen, and everything below resets the
     scroll, the cursor and the sibling panes to match it. The sibling
     loads already guarded on the open path; this one never did. *)
  if not (Masc_tui_fetched.is_current ~equal:String.equal state.code_file request)
  then ()
  else
  match result with
  | Ok content ->
      state.code_file_resume_intent <- Refresh_code_file;
      (* Recovery retains the selected file even if its first read did not
         finish. Its sibling reads restart independently; this completion
         must preserve their owners and any answers that arrived first. *)
      (* Lex once at load: comment and string state crosses rows, so a
         window could not answer. Past the budget the file draws plain
         rather than slowly. *)
      let language =
        if String.length content > 500_000 then None
        else Masc_tui_code_lexer.language_of_path path
      in
      let rows =
        Masc_tui_code_lexer.rows_of_source ~language content
        |> List.map
             (List.map (fun (text, kind) ->
                  (Masc.Tui_terminal_text.sanitize_terminal_text text, kind)))
      in
      (* [rows] stays a list for the memo scan and the width fold just
         below, both of which read it once front to back. The pane keeps
         the array. *)
      state.code_file <-
        Masc_tui_fetched.complete ~equal:String.equal state.code_file request
          (Ok (Array.of_list rows));
      (* The jump that asked for this file may have named a line; the
         reset and the jump live together so neither overwrites the
         other. Consumed once -- the next plain open starts at the top. *)
      if preserve_view then begin
        let last_line = max 0 (List.length rows - 1) in
        (match state.code_target_line with
         | Some line ->
             let target = max 0 (min (line - 1) last_line) in
             state.code_file_scroll <- target;
             state.code_file_cursor <- target
         | None ->
             state.code_file_scroll <- min state.code_file_scroll last_line;
             state.code_file_cursor <- min state.code_file_cursor last_line);
        state.code_target_line <- None
      end else begin
        state.code_file_scroll <-
          (match state.code_target_line with
           | Some line -> max 0 (line - 1)
           | None -> 0);
        state.code_file_cursor <- state.code_file_scroll;
        state.code_lsp_note <- None;
        state.code_target_line <- None;
        state.code_file_hscroll <- 0
      end;
      (* The widest row is the horizontal clamp; measured here, once,
         not on every l press over ten thousand rows. *)
      state.code_file_max_width <-
        List.fold_left
          (fun widest segments ->
            let row_width =
              List.fold_left
                (fun acc (text, _) ->
                  acc + Message_layout.display_width text)
                0 segments
            in
            max widest row_width)
          0 rows;
      state.code_file_hscroll <- min state.code_file_hscroll
        (max 0 (state.code_file_max_width - 1));
      state.code_memos <- Masc_tui_memo.of_file ~path rows;
      if not preserve_view then begin
      state.code_focus_file <- Right_pane;
      (* A new file starts on its content; the old file's history or
         diff would caption the wrong bytes. *)
      state.code_lsp_query <- Masc_tui_fetched.clear state.code_lsp_query;
      state.code_history <- Masc_tui_fetched.clear state.code_history;
      state.code_history_open <- false;
      state.code_history_expanded <- None;
      state.code_history_scroll <- 0;
      state.code_diff <- Masc_tui_fetched.clear state.code_diff;
      state.code_diff_open <- false;
      state.code_diff_scroll <- 0;
      state.code_diff_hscroll <- 0;
      state.code_diff_max_width <- 0;
      state.code_notes_open <- false;
      state.code_notes_scroll <- 0;
      state.code_blame <- Masc_tui_fetched.clear state.code_blame
      end
  | Error detail ->
      state.code_memos <- [];
      state.code_file <-
        Masc_tui_fetched.complete ~equal:String.equal state.code_file request
          (Error detail))

;;

let apply_file ?(intent = Open_code_file) state request result =
  match intent with
  | Open_code_file -> apply_open_file ~preserve_view:false state request result
  | Refresh_code_file -> apply_open_file ~preserve_view:true state request result
  | Return_code_file owner -> apply_return_file state owner request result

let take_ready_return_file state ~input_pending =
  if input_pending then false
  else match state.code_return with
  | Some reading when return_owner_current state reading.crr_owner ->
      (match reading.crr_owner.cro_history, Masc_tui_fetched.current reading.crr_file with
       | target :: rest, Some (path, Masc_tui_fetched.Ready content) ->
           commit_return_location state target rest;
           state.code_file <- Masc_tui_fetched.clear state.code_file;
           (match Masc_tui_fetched.start ~equal:String.equal state.code_file ~key:path with
            | Masc_tui_fetched.Already_loading -> false
            | Masc_tui_fetched.Started (file, request) ->
                state.code_file <- file;
                state.code_target_line <- None;
                apply_open_file ~preserve_view:false state request (Ok content);
                restore_position state target;
                true)
       | ([] | _ :: _), (None | Some (_, (Masc_tui_fetched.Absent | Masc_tui_fetched.Loading
                        | Masc_tui_fetched.Ready _ | Masc_tui_fetched.Stale _
                        | Masc_tui_fetched.Failed _))) -> false)
  | Some _ -> state.code_return <- None; false
  | None -> false

let take_ready_found_file (state : state) ~input_pending =
  if input_pending then false
  else match state.palette_mode, Masc_tui_fetched.current state.code_finder_file with
  | Palette_files origin, Some ((scope, path), Masc_tui_fetched.Ready content)
      when state.palette_open && code_finder_current state origin
           && scope = origin.cfo_scope ->
           push_code_jump state;
           close_code_finder state;
           let parent = Filename.dirname path in
           state.code_dir <- (if String.equal parent "." then "" else parent);
           state.code_cursor <- 0;
           state.code_listing <- Masc_tui_fetched.clear state.code_listing;
           state.code_file <- Masc_tui_fetched.clear state.code_file;
           state.code_target_line <- None;
           (match Masc_tui_fetched.start ~equal:String.equal state.code_file ~key:path with
            | Masc_tui_fetched.Already_loading -> false
            | Masc_tui_fetched.Started (file, file_request) ->
                state.code_file <- file;
                apply_file state file_request (Ok content);
                true)
  | (Palette_files _ | Palette_jump | Palette_choice _),
    (None | Some (_, (Masc_tui_fetched.Absent | Masc_tui_fetched.Loading
     | Masc_tui_fetched.Ready _ | Masc_tui_fetched.Stale _ | Masc_tui_fetched.Failed _))) -> false

let apply_found_file ?(input_pending = false) (state : state) request result =
  let scope, _ = Masc_tui_fetched.request_key request in
  match state.palette_mode with
  | Palette_files origin
      when state.palette_open && code_finder_current state origin
           && scope = origin.cfo_scope
           && Masc_tui_fetched.is_current ~equal:code_scope_path_equal
                state.code_finder_file request ->
      state.code_finder_file <- Masc_tui_fetched.complete ~equal:code_scope_path_equal
          state.code_finder_file request result;
      take_ready_found_file state ~input_pending
  | Palette_files _ | Palette_jump | Palette_choice _ -> false

let apply_blame (state : state) request result =
  (* An answer that arrives after the operator moved on describes bytes
     that are no longer on screen, and a margin naming the wrong authors
     is worse than no margin. Opening a file clears the blame, so a
     request from before that is no longer the one being waited on and
     [complete] drops it -- the hand-written path comparison this arm
     used to carry said the same thing in more places. *)
  state.code_blame <-
    Masc_tui_fetched.complete ~equal:String.equal state.code_blame request result

;;

let start_lsp_question ?line (state : state) ~question ~symbol =
  match Masc_tui_fetched.current_request state.code_file with
  | None -> None
  | Some file ->
      let key = { clq_scope = state.code_scope; clq_file = file;
                  clq_question = question; clq_symbol = symbol;
                  clq_line = Option.value ~default:(state.code_file_cursor + 1) line } in
      (match Masc_tui_fetched.start ~equal:code_lsp_query_equal state.code_lsp_query ~key with
       | Masc_tui_fetched.Already_loading -> None
       | Masc_tui_fetched.Started (next, request) ->
           state.code_lsp_query <- next;
           Some request)
;;

let apply_lsp_answer (state : state) request result =
  let query = Masc_tui_fetched.request_key request in
  let current_file = match Masc_tui_fetched.current_request state.code_file with
    | None -> false
    | Some current ->
        Masc_tui_fetched.same_request ~equal:String.equal current query.clq_file in
  if not (Masc_tui_fetched.is_current ~equal:code_lsp_query_equal state.code_lsp_query request)
     || query.clq_scope <> state.code_scope || not current_file
  then No_followup
  else begin
  state.code_lsp_query <-
    Masc_tui_fetched.complete ~equal:code_lsp_query_equal state.code_lsp_query request
      (Result.map (fun _ -> ()) result);
  let question, symbol = query.clq_question, query.clq_symbol in
  (match result with
   | Error detail ->
       state.code_lsp_note <- Some (symbol ^ ": " ^ detail);
       No_followup
   | Ok (Masc.Tui_decode.Lsp_hover text) ->
       state.code_lsp_note <-
         Some
           (match text with
            | Some t ->
                symbol ^ ": " ^ Masc.Tui_terminal_text.sanitize_terminal_text t
            | None -> symbol ^ ": the server has nothing to say here");
       No_followup
   | Ok (Masc.Tui_decode.Lsp_locations []) ->
       state.code_lsp_note <-
         Some (Printf.sprintf "no %s found for %S" question symbol);
       No_followup
   | Ok (Masc.Tui_decode.Lsp_locations (location :: _)) ->
       let open Masc.Tui_decode in
       if location.ll_inside then begin
         (* Jump there: same file just moves the cursor, another file
            opens with the line as its target. Either way the place the
            jump left from goes on the back stack first. *)
         push_code_jump state;
         state.code_lsp_note <-
           Some
             (Printf.sprintf "%s: %s:%d" symbol location.ll_path
                location.ll_line);
         match Masc_tui_fetched.current state.code_file with
         | Some (open_path, Masc_tui_fetched.Ready rows)
           when String.equal open_path location.ll_path ->
             let cursor =
               max 0
                 (min (location.ll_line - 1) (Array.length rows - 1))
             in
             state.code_file_cursor <- cursor;
             (* Follow the jump: a definition past the fold is a cursor
                the operator cannot see otherwise. *)
             Reveal_cursor
         (* A different file, or this one not readable yet: ask for it.
            [start] answers Already_loading if that is the read already in
            flight, so a jump into the file being read does not double it. *)
         | Some
             ( _
             , ( Masc_tui_fetched.Absent | Masc_tui_fetched.Loading
               | Masc_tui_fetched.Ready _ | Masc_tui_fetched.Stale _
               | Masc_tui_fetched.Failed _ ) )
         | None ->
             state.code_target_line <- Some location.ll_line;
             Load_file location.ll_path
       end
       else begin
         (* Outside the workspace (stdlib, a package): say where rather
            than open a path the surface cannot serve. *)
         state.code_lsp_note <-
           Some
             (Printf.sprintf "%s: outside the workspace at %s:%d" symbol
                location.ll_path location.ll_line);
         No_followup
       end)
  end

;;

let apply_diff (state : state) request result =
  let landed =
    Masc_tui_fetched.is_current ~equal:String.equal state.code_diff request
    && Result.is_ok result
  in
  state.code_diff <-
    Masc_tui_fetched.complete ~equal:String.equal state.code_diff request result;
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

let apply_history (state : state) request result =
  (* The scope travels in the key, so a slow answer from a repository the
     operator has left cannot caption the file now open at the same
     relative path. *)
  let landed =
    Masc_tui_fetched.is_current ~equal:code_scope_path_equal state.code_history
      request
    && Result.is_ok result
  in
  state.code_history <-
    Masc_tui_fetched.complete ~equal:code_scope_path_equal state.code_history
      request result;
  if landed then begin
    state.code_history_scroll <- 0;
    state.code_history_expanded <- None
  end

;;
