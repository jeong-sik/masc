(** Code reply application. Request identity remains the admission boundary;
    the loop executes the explicit followup for layout or a new file read. *)

open Masc_tui_types
module Message_layout = Masc_tui_message_layout

type followup =
  | No_followup
  | Reveal_cursor
  | Choose_location
  | Read_location_file of code_navigation_owner * string Masc_tui_fetched.request

let push_code_jump state =
  state.code_navigation <- None;
  state.code_jump_back <-
    { cj_scope = state.code_scope; cj_dir = state.code_dir;
      cj_file = Masc_tui_fetched.current_key state.code_file;
      cj_cursor = state.code_file_cursor; cj_scroll = state.code_file_scroll;
      cj_hscroll = state.code_file_hscroll; cj_tree_cursor = state.code_cursor;
      cj_focus = state.code_focus_file } :: state.code_jump_back

type return_followup =
  | No_return
  | Return_committed
  | Read_navigation_file of code_navigation_owner * string Masc_tui_fetched.request

let restore_position state target =
  let last_line = match Masc_tui_fetched.current state.code_file with
    | Some (_, (Masc_tui_fetched.Ready { cfd_rows = rows; _ }
               | Masc_tui_fetched.Stale ({ cfd_rows = rows; _ }, _))) ->
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

let commit_navigation_location state target rest =
  let changed = state.code_scope <> target.cj_scope
    || not (String.equal state.code_dir target.cj_dir) in
  state.code_navigation <- None;
  set_code_scope state target.cj_scope;
  state.code_dir <- target.cj_dir;
  state.code_jump_back <- rest;
  if changed then state.code_listing <- Masc_tui_fetched.clear state.code_listing

let start_navigation state ~action ~target ~path =
  if not (server_authority_ready state) || state.view <> Code then None
  else begin
    state.code_file <- Masc_tui_fetched.cancel_pending
        ~reason:"File read cancelled by navigation" state.code_file;
    state.code_file_resume_intent <- Refresh_code_file;
    let owner = { cno_origin = {
      cfo_workspace = state.workspace_authority;
      cfo_reading = state.workspace_read_authority;
      cfo_scope = state.code_scope; cfo_dir = state.code_dir;
      cfo_file = Masc_tui_fetched.current_request state.code_file };
      cno_history = state.code_jump_back; cno_destination = target;
      cno_action = action } in
    match Masc_tui_fetched.start ~equal:String.equal Masc_tui_fetched.initial ~key:path with
    | Masc_tui_fetched.Already_loading -> None
    | Masc_tui_fetched.Started (file, request) ->
        state.code_navigation <- Some { cnr_owner = owner; cnr_file = file };
        Some (owner, request)
  end

let start_return state =
  if not (server_authority_ready state) then begin
    state.code_lsp_note <- Some "Cannot return until the workspace is confirmed";
    No_return
  end else match state.code_navigation with
  | Some reading when code_navigation_owner_current state reading.cnr_owner
      && reading.cnr_owner.cno_action = Return_to_history -> No_return
  | Some _ | None ->
    state.code_navigation <- None;
    match state.code_jump_back with
    | [] -> state.code_lsp_note <- Some "No jump to return from"; No_return
    | target :: rest ->
      (* Ordinary opens can still own this source, including same-key refreshes
         that expose Ready. Retire them before capturing the return owner so a
         late callback cannot reset the current or restored reading. *)
      state.code_file <- Masc_tui_fetched.cancel_pending
          ~reason:"File read cancelled by return navigation" state.code_file;
      state.code_file_resume_intent <- Refresh_code_file;
      match target.cj_file with
      | None ->
          commit_navigation_location state target rest;
          state.code_file <- Masc_tui_fetched.clear state.code_file;
          state.code_file_resume_intent <- Refresh_code_file;
          restore_position state target;
          state.code_focus_file <- Left_pane;
          Return_committed
      | Some path ->
        match Masc_tui_fetched.current state.code_file with
        | Some (current, Masc_tui_fetched.Ready _)
            when state.code_scope = target.cj_scope && String.equal current path ->
            commit_navigation_location state target rest;
            restore_position state target;
            Return_committed
        | None | Some (_, (Masc_tui_fetched.Absent | Masc_tui_fetched.Loading
                         | Masc_tui_fetched.Ready _ | Masc_tui_fetched.Stale _
                         | Masc_tui_fetched.Failed _)) ->
          match start_navigation state ~action:Return_to_history ~target ~path with
          | None -> No_return
          | Some (owner, request) -> Read_navigation_file (owner, request)

let apply_navigation_file state owner request result =
  match state.code_navigation with
  | Some reading when reading.cnr_owner == owner && code_navigation_owner_current state owner
      && Masc_tui_fetched.is_current ~equal:String.equal reading.cnr_file request ->
      (match result with
       | Error detail ->
           state.code_navigation <- None;
           state.code_lsp_note <- Some ("Navigation failed: "
             ^ Masc.Tui_terminal_text.sanitize_terminal_text detail)
       | Ok _ ->
           state.code_navigation <- Some { reading with cnr_file =
             Masc_tui_fetched.complete ~equal:String.equal reading.cnr_file request result })
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
  | Palette_files _ | Palette_locations _ | Palette_jump | Palette_choice _ -> ()

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
  | Ok (source : Masc.Tui_decode.workspace_file_source) ->
      let content = source.wfs_content in
      if not preserve_view then state.code_draft_open <- false;
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
          (Ok { cfd_source = content; cfd_revision = source.wfs_revision; cfd_rows = Array.of_list rows });
      Option.iter (fun draft ->
        let review_owned = match state.code_draft_review with
          | Some (owner, reading) -> reading == request
              && Masc_tui_code_draft.same_draft owner draft
          | None -> false in
        let observe = match Masc_tui_code_draft.phase draft with
          | Masc_tui_code_draft.Needs_review _ -> review_owned
          | Masc_tui_code_draft.Editable | Masc_tui_code_draft.Rejected _ -> true
          | Masc_tui_code_draft.Saving _ -> false in
        if observe then put_code_draft state (Masc_tui_code_draft.observe
          { text = content; revision = source.wfs_revision } draft);
        if review_owned then state.code_draft_review <- None) (current_code_draft state);
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
  | Navigate_code_file owner -> apply_navigation_file state owner request result

let copy_file_source (state : state) =
  if not (server_authority_ready state) then
    Error "Confirm the workspace before copying file source"
  else if state.view <> Code || state.code_focus_file <> Right_pane
          || state.code_history_open || state.code_diff_open || state.code_notes_open
          || state.code_draft_open then
    Error "Focus file content to copy its source"
  else match Masc_tui_fetched.current state.code_file with
    | Some (path, Masc_tui_fetched.Ready document) -> Ok (path, document.cfd_source)
    | None | Some (_, (Masc_tui_fetched.Absent | Masc_tui_fetched.Loading
                     | Masc_tui_fetched.Stale _ | Masc_tui_fetched.Failed _)) ->
        Error "File source is not currently readable"

let take_ready_navigation_file state ~input_pending =
  if input_pending then false
  else match state.code_navigation with
  | Some reading when code_navigation_owner_current state reading.cnr_owner ->
      (match Masc_tui_fetched.current reading.cnr_file with
       | Some (path, Masc_tui_fetched.Ready content) ->
         let history = match reading.cnr_owner.cno_action, reading.cnr_owner.cno_history with
           | Return_to_history, [] -> None
           | Return_to_history, _ :: rest -> Some rest
           | Follow_location, ([] | _ :: _) ->
               push_code_jump state;
               Some state.code_jump_back in
         (match history with
          | None -> false
          | Some history ->
           let target = reading.cnr_owner.cno_destination in
           commit_navigation_location state target history;
           state.code_file <- Masc_tui_fetched.clear state.code_file;
           (match Masc_tui_fetched.start ~equal:String.equal state.code_file ~key:path with
            | Masc_tui_fetched.Already_loading -> false
            | Masc_tui_fetched.Started (file, request) ->
                state.code_file <- file;
                state.code_target_line <- None;
                apply_open_file ~preserve_view:false state request (Ok content);
                restore_position state target;
                true))
       | None | Some (_, (Masc_tui_fetched.Absent | Masc_tui_fetched.Loading
                        | Masc_tui_fetched.Stale _ | Masc_tui_fetched.Failed _)) -> false)
  | Some _ -> state.code_navigation <- None; false
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
  | (Palette_files _ | Palette_locations _ | Palette_jump | Palette_choice _),
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
  | Palette_files _ | Palette_locations _ | Palette_jump | Palette_choice _ -> false

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
  (match state.palette_mode with
   | Palette_locations _ -> close_code_finder state
   | Palette_jump | Palette_choice _ | Palette_files _ -> state.code_location_offer <- None);
  state.code_navigation <- None;
  (if state.code_file_resume_intent = Open_code_file then
   match Masc_tui_fetched.current state.code_file with
   | Some (_, (Masc_tui_fetched.Ready _ | Masc_tui_fetched.Stale _)) ->
       state.code_file <- Masc_tui_fetched.cancel_pending
         ~reason:"File read cancelled by language-server question" state.code_file;
       state.code_file_resume_intent <- Refresh_code_file
   | None | Some (_, (Masc_tui_fetched.Absent | Masc_tui_fetched.Loading
                   | Masc_tui_fetched.Failed _)) -> ());
  match Masc_tui_fetched.current_request state.code_file with
  | None -> None
  | Some file ->
      let key = { clq_workspace = state.workspace_authority;
                  clq_reading = state.workspace_read_authority;
                  clq_scope = state.code_scope; clq_dir = state.code_dir; clq_file = file;
                  clq_question = question; clq_symbol = symbol;
                  clq_line = Option.value ~default:(state.code_file_cursor + 1) line } in
      (match Masc_tui_fetched.start ~equal:code_lsp_query_equal state.code_lsp_query ~key with
       | Masc_tui_fetched.Already_loading -> None
       | Masc_tui_fetched.Started (next, request) ->
           state.code_lsp_query <- next;
           state.code_lsp_note <- None;
           Some request)
;;

let follow_lsp_location (state : state) ~symbol (location : Masc.Tui_decode.lsp_location) =
  let open Masc.Tui_decode in
  if location.ll_inside then begin
    state.code_lsp_note <-
      Some
        (Printf.sprintf "%s: %s:%d" symbol location.ll_path
           location.ll_line);
    match Masc_tui_fetched.current state.code_file with
    | Some (open_path, Masc_tui_fetched.Ready { cfd_rows = rows; _ })
      when String.equal open_path location.ll_path ->
        push_code_jump state;
        state.code_file <- Masc_tui_fetched.cancel_pending
            ~reason:"File read cancelled by location navigation" state.code_file;
        state.code_file_resume_intent <- Refresh_code_file;
        let cursor =
          max 0
            (min (location.ll_line - 1) (Array.length rows - 1))
        in
        state.code_file_cursor <- cursor;
        state.code_file_hscroll <- 0;
        state.code_focus_file <- Right_pane;
        (* Follow the jump: a definition past the fold is a cursor
           the operator cannot see otherwise. *)
        Reveal_cursor
    (* Keep the source while a separate navigation owner reads a different
       or currently unreadable destination. Only its successful commit adds
       the source history entry. *)
    | Some
        ( _
        , ( Masc_tui_fetched.Absent | Masc_tui_fetched.Loading
          | Masc_tui_fetched.Ready _ | Masc_tui_fetched.Stale _
          | Masc_tui_fetched.Failed _ ) )
    | None ->
        let parent = Filename.dirname location.ll_path in
        let target = { cj_scope = state.code_scope;
          cj_dir = (if String.equal parent "." then "" else parent);
          cj_file = Some location.ll_path;
          cj_cursor = max 0 (location.ll_line - 1);
          cj_scroll = max 0 (location.ll_line - 1);
          cj_hscroll = 0; cj_tree_cursor = 0; cj_focus = Right_pane } in
        (match start_navigation state ~action:Follow_location
             ~target ~path:location.ll_path with
         | Some (owner, request) -> Read_location_file (owner, request)
         | None -> No_followup)
  end
  else begin
    (* Outside the workspace (stdlib, a package): say where rather
       than open a path the surface cannot serve. *)
    state.code_lsp_note <-
      Some
        (Printf.sprintf "%s: outside the workspace at %s:%d" symbol
           location.ll_path location.ll_line);
    No_followup
  end
;;

let apply_lsp_answer (state : state) request result =
  let query = Masc_tui_fetched.request_key request in
  if not (Masc_tui_fetched.is_current ~equal:code_lsp_query_equal state.code_lsp_query request)
     || not (code_lsp_query_current state query)
  then ()
  else begin
  state.code_lsp_query <-
    Masc_tui_fetched.complete ~equal:code_lsp_query_equal state.code_lsp_query request
      (Result.map (fun _ -> ()) result);
  let question, symbol = query.clq_question, query.clq_symbol in
  (match result with
   | Error detail ->
       state.code_lsp_note <- Some (symbol ^ ": " ^ detail);
       ()
   | Ok (Masc.Tui_decode.Lsp_hover text) ->
       state.code_lsp_note <-
         Some
           (match text with
            | Some t ->
                symbol ^ ": " ^ Masc.Tui_terminal_text.sanitize_terminal_text t
            | None -> symbol ^ ": the server has nothing to say here");
       ()
   | Ok (Masc.Tui_decode.Lsp_locations []) ->
       state.code_lsp_note <-
         Some (Printf.sprintf "no %s found for %S" question symbol);
       ()
   | Ok (Masc.Tui_decode.Lsp_locations locations) ->
       state.code_file <- Masc_tui_fetched.cancel_pending
         ~reason:"File read cancelled by location offer" state.code_file;
       state.code_file_resume_intent <- Refresh_code_file;
       let offer = { clo_origin = {
           cfo_workspace = state.workspace_authority;
           cfo_reading = state.workspace_read_authority;
           cfo_scope = state.code_scope; cfo_dir = state.code_dir;
           cfo_file = Masc_tui_fetched.current_request state.code_file };
         clo_query = request; clo_locations = locations } in
       state.code_location_offer <- Some offer;
       ())
  end
;;

let retire_lsp_input state =
  match state.palette_mode with
  | Palette_locations offer when state.palette_open
      && code_location_offer_current state offer -> ()
  | Palette_locations _ | Palette_jump | Palette_choice _ | Palette_files _ ->
      (* Workspace recovery reissues the current key, including settled ones. *)
      state.code_lsp_query <- Masc_tui_fetched.clear state.code_lsp_query;
      state.code_location_offer <- None
;;

let choose_lsp_location state offer location =
  let owns_picker = match state.palette_mode with
    | Palette_locations current -> state.palette_open && current == offer
    | Palette_jump | Palette_choice _ | Palette_files _ -> false in
  if not owns_picker || not (code_location_offer_current state offer)
     || not (List.exists (fun candidate -> candidate == location) offer.clo_locations)
  then No_followup
  else begin
    let query = Masc_tui_fetched.request_key offer.clo_query in
    close_code_finder state;
    follow_lsp_location state ~symbol:query.clq_symbol location
  end
;;

let take_ready_lsp_locations state ~input_pending =
  match state.code_location_offer with
  | None -> No_followup
  | Some offer when not (code_location_offer_current state offer) ->
      state.code_location_offer <- None;
      No_followup
  | Some _ when input_pending -> No_followup
  | Some offer ->
      match state.palette_open, state.palette_mode with
      | true, Palette_locations current when current == offer -> No_followup
      | true, (Palette_jump | Palette_choice _ | Palette_files _ | Palette_locations _) ->
          state.code_location_offer <- None;
          No_followup
      | false, (Palette_jump | Palette_choice _ | Palette_files _ | Palette_locations _) ->
          match offer.clo_locations with
          | [] -> state.code_location_offer <- None; No_followup
          | [location] ->
              let query = Masc_tui_fetched.request_key offer.clo_query in
              state.code_location_offer <- None;
              follow_lsp_location state ~symbol:query.clq_symbol location
          | _ :: _ :: _ ->
              state.palette_open <- true;
              state.palette_mode <- Palette_locations offer;
              state.palette_query <- "";
              state.palette_cursor <- 0;
              Choose_location
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


module Draft = Masc_tui_code_draft

let prepare_draft state =
  if not (server_authority_ready state) || not (code_edit_focus state) then
    Error "Focus a readable file in a confirmed workspace before editing"
  else match current_code_draft state with
    | Some draft -> (match Draft.phase draft with
        | Draft.Saving _ -> Error "Wait for this draft's save before editing"
        | Draft.Editable | Draft.Rejected _ | Draft.Needs_review _ -> Ok draft)
    | None -> match code_draft_address state, Masc_tui_fetched.current state.code_file with
      | Some address, Some (_, Masc_tui_fetched.Ready source) ->
        Ok (Draft.create ~address ~source:{text=source.cfd_source; revision=source.cfd_revision})
      | (None | Some _), (None | Some (_, (Masc_tui_fetched.Absent | Masc_tui_fetched.Loading
          | Masc_tui_fetched.Stale _ | Masc_tui_fetched.Failed _ | Masc_tui_fetched.Ready _))) ->
        Error "The current file has no editable source revision"

let edit_draft state draft text =
  let ( let* ) = Result.bind in
  let* () = match code_draft_address state with
    | Some address when Draft.equal_address address (Draft.address draft)
        && server_authority_ready state -> Ok ()
    | Some _ | None -> Error "Workspace or file changed; the editor cannot replace another draft" in
  let* next = Draft.edit text draft in
  put_code_draft state next;
  state.code_lsp_note <- None;
  state.code_draft_open <- true; state.code_draft_scroll <- 0;
  Ok ()

let discard_draft state = match current_code_draft state with
  | None -> Error "No draft for this file"
  | Some draft when not (Draft.can_discard draft) -> Error "Wait for the submitted save before discarding"
  | Some draft ->
    state.code_drafts <- List.filter (fun existing -> existing != draft) state.code_drafts;
    state.code_draft_open <- false; state.code_draft_review <- None; Ok ()

let adopt_draft_revision state = match
  (if server_authority_ready state then current_code_draft state else None) with
  | None -> Error "No draft for this file"
  | Some draft -> Result.map (put_code_draft state) (Draft.adopt_current draft)

let begin_draft_save state =
  let ( let* ) = Result.bind in
  let* () = match write_authority_refusal state state.workspace_authority with
    | None when code_edit_focus state -> Ok ()
    | None -> Error "Focus the file or its draft before saving"
    | Some detail -> Error detail in
  let* draft = match current_code_draft state with
    | Some draft -> Ok draft | None -> Error "No edited draft to save" in
  let* submitted, ticket = Draft.begin_save draft in
  put_code_draft state submitted;
  state.code_draft_open <- true;
  state.code_draft_review <- None;
  Ok ({ csr_address=Draft.address submitted; csr_ticket=ticket;
    csr_file=Masc_tui_fetched.current_request state.code_file }, submitted)

let complete_draft_save state request outcome =
  let refresh = ref false in
  state.code_drafts <- List.filter_map (fun draft ->
    if not (Draft.equal_address request.csr_address (Draft.address draft)) then Some draft
    else match Draft.complete request.csr_ticket outcome draft with
      | Draft.Ignored -> Some draft
      | Draft.Retained next -> Some next
      | Draft.Committed _ ->
        state.code_saved_refreshes <- request.csr_address :: List.filter
          (fun address -> not (Draft.equal_address address request.csr_address)) state.code_saved_refreshes;
        (match code_draft_address state with
         | Some address when Draft.equal_address address request.csr_address -> state.code_draft_open <- false
         | Some _ | None -> ());
        let original_reading = match request.csr_file,
            Masc_tui_fetched.current_request state.code_file with
          | Some before, Some current -> before == current
          | None, _ | Some _, None -> false in
        refresh := original_reading && state.view = Code && server_authority_ready state
          && Option.is_none state.code_navigation && not state.palette_open
          && Option.is_none state.search
          && (match code_draft_address state with
              | Some address -> Draft.equal_address address request.csr_address | None -> false);
        if !refresh then begin
          state.code_draft_open <- false;
          state.code_lsp_note <- Some "Draft saved; refreshing server source"
        end;
        None) state.code_drafts;
  !refresh

let saved_refresh_path state ~input_pending =
  if input_pending || state.view <> Code || not (server_authority_ready state)
     || state.palette_open || Option.is_some state.search
     || Option.is_some state.code_navigation || Masc_tui_fetched.in_flight state.code_file
  then None
  else match code_draft_address state with
    | Some address when List.exists (Draft.equal_address address) state.code_saved_refreshes -> Some address.path
    | Some _ | None -> None
