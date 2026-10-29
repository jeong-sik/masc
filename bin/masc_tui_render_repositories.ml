(** Repository Studio, Workspace Activity, Git Changes and File Changes screens. *)

open Masc_tui_types
open Tui_decode
open Masc_tui_ansi
open Masc_tui_render_prim

module Message_layout = Masc_tui_message_layout
module Rows = Masc_tui_rows
module Keeper_chat = Masc_tui_keeper_chat_projection
module Render_schedule = Masc_tui_render_schedule
module Span = Masc_tui_span
module Diff = Masc_tui_diff

(* The repositories a keeper can work in.  The server sends both the stored
   path spelling and the absolute path it actually resolves.  The latter is
   what an operator needs before opening a shell or comparing another
   checkout; resolving the stored spelling again in the TUI would use the
   TUI's cwd instead of the server's base path. *)
let repository_context_fields (repo : Masc.Tui_decode.repository) =
  let stored_path =
    if String.equal repo.rp_local_path repo.rp_resolved_local_path then []
    else ["Stored as", repo.rp_local_path]
  in
  let keepers = match repo.rp_keepers with
    | [] -> "none assigned" | names -> String.concat ", " names in
  let failure = match Masc.Tui_decode.repository_status_reason repo.rp_status with
    | None -> [] | Some reason -> ["Error", reason] in
  failure @ ["Path", repo.rp_resolved_local_path] @ stored_path @ ["Keepers", keepers]

let repository_context_lines ~width repo =
  repository_context_fields repo
  |> List.concat_map (fun (label, value) ->
      Masc_tui_text_block.rows ~max_cells:(max 1 width)
        (Printf.sprintf "  %s: %s" label value))

let selected_repository_reading (state : state) =
  let selected = Option.bind state.repositories (fun snapshot ->
    List.nth_opt snapshot.rs_repositories state.repositories_cursor) in
  let errors = match state.repositories_error with
    | None -> [] | Some reason ->
        [(if Option.is_some state.repositories then "Refresh failed · retained reading"
          else "Read failed"), reason] in
  let capture ~title fields =
    Masc_tui_detail_reading.create ~title
      (List.map (fun (heading,body) -> {Masc_tui_detail_reading.heading;body}) fields) in
  match selected with
  | None ->
      if errors=[] then None else Some (capture ~title:"Workspace / inventory" errors)
  | Some (repo : Masc.Tui_decode.repository) ->
      let format_fields fields =
        fields
        |> List.map (fun (label, value) -> Printf.sprintf "%s: %s" label value)
        |> String.concat "\n"
      in
      Some (capture ~title:("Workspace / " ^ repo.rp_name)
        (errors
         @ [ ( ui_text state
                 ~ko:"1. 저장소 기본 정보"
                 ~en:"1. Repository & Remote"
             , format_fields
                 [ "Repository", repo.rp_name
                 ; "ID", repo.rp_id
                 ; "Status", Masc.Tui_decode.repository_status_word repo.rp_status
                 ; "Remote", repo.rp_url
                 ; "Default branch", repo.rp_default_branch
                 ; "Auto sync", (if repo.rp_auto_sync then "on" else "off")
                 ] )
           ; ( ui_text state
                 ~ko:"2. 로컬 경로 · 배정된 키퍼"
                 ~en:"2. Local Path & Keepers"
             , format_fields (repository_context_fields repo) )
           ]))

type workspace_activity_column = Activity_date | Activity_keeper | Activity_task | Activity_result | Activity_path

let workspace_activity_cells ~cols ~date ~keeper ~task ~result ~path =
  let width = function
    | Activity_date -> 16 | Activity_keeper -> 18 | Activity_task -> 16
    | Activity_result -> String.length "RESULT" | Activity_path -> 8 in
  let layout = Masc_tui_table.fit ~inner_width:(max 1 (framed_inner_width cols - 2))
    ~width ~flex:Activity_path ~drop_order:[Activity_task; Activity_date; Activity_keeper]
    [Activity_date; Activity_keeper; Activity_task; Activity_result; Activity_path] in
  List.map (fun column ->
    let header, value, fold = match column with
      | Activity_date -> "DATE", date, Masc_tui_table.Fold_tail
      | Activity_keeper -> "KEEPER", keeper, Masc_tui_table.Fold_middle
      | Activity_task -> "TASK", task, Masc_tui_table.Fold_middle
      | Activity_result -> "RESULT", result, Masc_tui_table.Fold_tail
      | Activity_path -> "FILE", path, Masc_tui_table.Fold_middle in
    Masc_tui_table.cell ~header ~fold
      ~width:(if column = Activity_path then layout.flex_width else width column) value) layout.shown

let render_workspace_activity (state : state) repo_id =
  let terminal_rows, cols = get_terminal_size () in
  let rows, cursor, selected = workspace_activity_selection state in
  let title = match state.workspace_activity_context_scroll with
    | None -> " MASC Workspace / Activity · " ^ Terminal_text.single_line repo_id
    | Some requested ->
        let count = List.length (workspace_activity_context_lines state ~cols) in
        let height = workspace_activity_context_height state
          ~surface_rows:(surface_body_rows state ~terminal_rows) in
        let scroll = max 0 (min requested (max 0 (count - height))) in
        " Context [" ^ Masc_tui_scroll.window_text ~scroll ~height count ^ "]" in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"workspace-activity"
    ~title:(screen_title title)
    ~hints:(match state.workspace_activity_context_scroll with
      | None -> "v:context  j/k:select  PgUp/PgDn:page  Enter:file  r:refresh  Esc:back"
      | Some _ -> "j/k:scroll  PgUp/PgDn:page  Home/End:edges  Enter:file  r:refresh  Esc:list")
    ~body:(fun ~budget c ->
      let listing ~budget reading =
          c.push (Printf.sprintf "  Last %.0fh · %d recorded changes · %d successful · %d incomplete repo calls · %d unlocated fleet calls"
            reading.Tui_decode.ras_window_hours (List.length rows)
            (List.length (List.filter (fun ((change : Tui_decode.file_change), _) -> change.fc_succeeded) rows))
            reading.ras_incomplete reading.ras_unattributed);
          let names = List.map (fun ((change : Tui_decode.file_change), _) -> change.fc_keeper) rows |> List.sort_uniq String.compare in
          c.push ("  Changes by Keeper: " ^ String.concat " · " (List.map (fun name ->
              Printf.sprintf "%s %d" (Terminal_text.single_line name)
                (List.length (List.filter (fun ((change : Tui_decode.file_change), _) -> change.fc_keeper = name) rows))) names));
          c.push_styled ~style:(Theme.recede ()) "  Recorded clone writes from all Keepers · Enter opens file; H history, m notes in Code";
          let cells = workspace_activity_cells ~cols in
          c.push ("  " ^ Masc_tui_table.header_row (cells ~date:"" ~keeper:"" ~task:"" ~result:"" ~path:""));
          c.push_divider ();
          let room = max 1 (budget - 7) in
          let first = max 0 (cursor - room + 1) in
          let rows_window = Rows.of_list ~first:first ~height:room rows in
          for i = 0 to room - 1 do
            match Rows.at rows_window (first + i) with
            | None -> if i = 0 && rows = [] then c.push "  No recorded clone writes in this window" else c.push_empty ()
            | Some (change, path) ->
                let tm = Unix.localtime change.Tui_decode.fc_at in
                let date = Printf.sprintf "%04d-%02d-%02d %02d:%02d"
                  (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min in
                let task = match change.fc_task_id with None -> "unlinked" | Some id -> id in
                let line = "  " ^ Masc_tui_table.row (cells ~date
                  ~keeper:(Terminal_text.single_line change.fc_keeper)
                  ~task:(Terminal_text.single_line task)
                  ~result:(if change.fc_succeeded then "ok" else "failed")
                  ~path:(Terminal_text.single_line path)) in
                if first + i = cursor then c.push_selected line else c.push line
          done;
          c.push_divider ();
          c.push (match selected with
            | None -> "  Task and file links appear when a recorded change names them"
            | Some (_, path) ->
                "  v:context · " ^ Message_layout.fit_middle
                  (max 1 (framed_inner_width cols - Message_layout.display_width "  v:context · "))
                  (Terminal_text.single_line path))
      in
      let show ~budget reading = match state.workspace_activity_context_scroll with
        | None -> listing ~budget reading
        | Some requested ->
            let lines = workspace_activity_context_lines state ~cols in
            let scroll = max 0 (min requested (max 0 (List.length lines - budget))) in
            let window = Rows.of_list ~first:scroll ~height:budget lines in
            for index = 0 to budget - 1 do
              match Rows.at window (scroll + index) with
              | None -> c.push_empty () | Some line -> c.push line
            done in
      match Masc_tui_fetched.view_for ~equal:String.equal state.workspace_activity ~key:repo_id with
      | Masc_tui_fetched.Absent | Masc_tui_fetched.Loading -> c.push "  Reading recorded file changes..."
      | Masc_tui_fetched.Failed message -> c.push_styled ~style:(Theme.bad ()) ("  " ^ Terminal_text.single_line message)
      | Masc_tui_fetched.Ready reading -> show ~budget reading
      (* The changes already read stay, with the failed refresh above them so
         they read as the last good reading rather than a fresh one. *)
      | Masc_tui_fetched.Stale (reading, message) ->
          c.push_styled ~style:(Theme.bad ())
            ("  Refresh failed, showing the last read: " ^ Terminal_text.single_line message);
          show ~budget:(max 1 (budget - 1)) reading)

let repository_studio_geometry (state : state) ~cols ~budget ~cursor =
  let repos = match state.repositories with
    | None -> [] | Some snapshot -> snapshot.rs_repositories in
  let shown = List.length repos in
      let width = framed_inner_width cols in
      let named_width =
        Render_schedule.workspace_minimum_width + 4
      in
      let detail_minimum = Message_layout.display_width "Keepers: none assigned" + 4 in
      let split = width >= named_width + detail_minimum + 2 && budget >= 8 in
      let detail_width = if split then min (width - named_width - 2) (max detail_minimum (width / 3)) else width in
      let list_width = if split then width - detail_width - 2 else width in
      let selected = List.nth_opt repos cursor in
      let context_lines = match selected with
        | None -> []
        | Some repo -> repository_context_lines ~width:(detail_width - 4) repo in
      let detail_title = match selected with
        | None -> "Selected repository"
        | Some repo -> Terminal_text.single_line repo.rp_name in
      let errors = match state.repositories_error with
        | None -> []
        | Some detail ->
            Message_layout.wrap_words ~max_cells:(max 1 (list_width - 4))
              (Terminal_text.single_line detail)
            |> List.map (fun line -> Theme.bad () ^ line ^ Ansi.reset) in
      (* Keep the header, panel edges and a selected repository visible.
         The stacked layout also needs the selected-context panel edges. *)
      let error_budget = max 0 (budget - if split then 4 else 6) in
      let errors =
        if List.length errors <= error_budget then errors
        else List.take (max 0 (error_budget - 1)) errors
          @ (if error_budget > 0 then ["v:read complete error"] else []) in
      let context_budget = max 0 (if split then budget - 2 else budget - 6 - List.length errors) in
      let truncated = List.length context_lines > context_budget in
      let show_notice = truncated && context_budget >= 2 in
      let visible_context =
        List.take (max 0 (context_budget - if show_notice then 1 else 0)) context_lines in
      let detail = studio_panel ~width:detail_width ~title:detail_title
          ~lines:(visible_context @
            (if show_notice
             then ["v:read complete context"] else [])) in
      let list_budget =
        if split then budget else max 4 (budget - List.length detail) in
      let room = max 1 (list_budget - 3 - List.length errors) in
      let overflowing = shown > room && room > 1 in
      let content_height = if overflowing && room > 1 then room - 1 else room in
  (split, list_width, detail_width, detail, errors, content_height, overflowing)

let repository_studio_content_height state ~cols ~budget ~cursor =
  let _, _, _, _, _, content_height, _ =
    repository_studio_geometry state ~cols ~budget ~cursor in
  content_height

let render_repository_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let repos =
    match state.repositories with
    | None -> []
    | Some s -> s.Masc.Tui_decode.rs_repositories
  in
  let shown = List.length repos in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let title =
    match state.repositories with
    | None ->
        let reading_note =
          match state.repositories_error with
          | None -> title_missing_reading ~error:None
          | Some _ -> ""
        in
        Printf.sprintf "%s  %s  %s  %s"
          (screen_title " MASC Workspace") reading_note timestamp
          (connection_badge state)
    | Some _ ->
        Printf.sprintf "%s (%d)  %s  %s"
          (screen_title " MASC Workspace") shown timestamp
          (connection_badge state)
  in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"repositories"
    ~title ~hints:(Masc_tui_keys.footer_hints state.view)
    ~body:(fun ~budget c ->
      let split, list_width, detail_width, detail, errors, content_height, overflowing =
        repository_studio_geometry state ~cols ~budget ~cursor:state.repositories_cursor in
      let repository_layout = Render_schedule.workspace_layout
          ~inner_width:(max 1 (list_width - 4)) in
      let max_scroll = max 0 (shown - content_height) in
      let scroll = max 0 (min max_scroll
          (Masc_tui_scroll.ensure_visible ~cursor:state.repositories_cursor
             ~height:content_height state.repositories_scroll)) in
      let repos_window = Rows.of_list ~first:scroll ~height:content_height repos in
      let lines =
        if shown = 0 then
          [match empty_page_of ~snapshot:state.repositories ~error:state.repositories_error with
           | Page_failed -> page_failed_note
           | Page_unread -> page_unread_note
           | Page_empty -> "(no repositories registered)"]
        else List.init content_height (fun i ->
          let idx = i + scroll in
          match Rows.at repos_window idx with
          | None -> ""
          | Some r ->
              let line = Render_schedule.workspace_row ~layout:repository_layout
                { Render_schedule.wrow_name = Terminal_text.single_line r.rp_name
                ; wrow_branch = Terminal_text.single_line r.rp_default_branch
                ; wrow_status = Terminal_text.single_line
                    (Masc.Tui_decode.repository_status_word r.rp_status)
                ; wrow_sync = if r.rp_auto_sync then "auto" else "manual"
                ; wrow_path = Terminal_text.single_line r.rp_resolved_local_path } in
              if idx = state.repositories_cursor then
                Theme.selection ^ fit_width line (list_width - 4) ^ Ansi.reset
              else line)
      in
      let lines = [Theme.recede () ^ Render_schedule.workspace_header_row ~layout:repository_layout ^ Ansi.reset]
        @ errors @ lines
        @ (if overflowing then
             ["repositories " ^ Masc_tui_scroll.window_text ~scroll ~height:content_height shown]
           else []) in
      let listing = studio_panel ~width:list_width ~title:"Repositories · j/k select" ~lines in
      if split then begin
        let height = max (List.length listing) (List.length detail) in
        let count = min budget height in
        (* Both panels through the list-window helper the scroll panes read:
           one array per panel, each row reads its own cells. No row of the
           loop walks either list to find itself -- the walk is what #40177's
           for-shaped zip left here, and it survives a [List.init] reshape,
           so the guard going green on that reshape would have been the
           shape leaving, not the walk. *)
        let left = Rows.of_list ~first:0 ~height:count listing in
        let right = Rows.of_list ~first:0 ~height:count detail in
        for index = 0 to count - 1 do
          c.push
            (fit_width (Option.value (Rows.at left index) ~default:"") list_width
            ^ "  "
            ^ fit_width (Option.value (Rows.at right index) ~default:"")
                detail_width)
        done
      end else begin
        List.iter c.push listing;
        List.iter c.push detail
      end)

type repository_changes_geometry =
  { rcg_context_lines : string list
  ; rcg_header : bool
  ; rcg_error_rows : int
  ; rcg_list_height : int
  }

(* Selection context costs rows before the list. At short heights it is
   folded as a unit, so a partial context never makes a checkout claim and a
   selected file always has a row. Keys and drawing ask this same geometry
   for the cursor they are about to select. *)
let repository_changes_geometry (state : state) ~cols ~budget ~cursor =
  let budget = max 1 budget in
  let path = Option.bind state.repository_changes (fun snapshot ->
    List.nth_opt snapshot.rcs_changes cursor |> Option.map (fun row -> row.rc_path)) in
  let context_lines = build_change_context_lines ~cols (resolve_change_context state ~path_opt:path) in
  let error_rows =
    match state.repository_changes_error with
    | None -> 0
    | Some _ when budget >= 3 -> 2
    | Some _ when budget >= 2 -> 1
    | Some _ -> 0 in
  let header = budget - error_rows >= 3 in
  let header_rows = if header then 2 else 0 in
  let context_lines =
    if 2 * List.length context_lines <= budget - error_rows - header_rows - 1
    then context_lines else [] in
  let list_height = max 1
      (budget - error_rows - header_rows - (2 * List.length context_lines)) in
  { rcg_context_lines = context_lines; rcg_header = header;
    rcg_error_rows = error_rows; rcg_list_height = list_height }

let repository_changes_content_height state ~cols ~budget ~cursor =
  (repository_changes_geometry state ~cols ~budget ~cursor).rcg_list_height

let repository_changes_context_visible state ~cols ~budget ~cursor =
  (repository_changes_geometry state ~cols ~budget ~cursor).rcg_context_lines <> []

type repository_change_authority =
  { rca_scope : acting_pane_scope
  ; rca_repository : Tui_decode.repository_change_scope option
  ; rca_surface : string
  ; rca_rows : int
  ; rca_cols : int
  ; rca_path : string
  ; rca_context : change_context
  }

(* The candidate names the full related record, not just the visible text.
   The caller publishes it only when this exact frame is presented. *)
let repository_changes_authority state ~surface_key ~terminal_rows ~cols =
  let rows = surface_body_rows state ~terminal_rows in
  let path =
    match state.repository_changes_open, surface_key, state.repository_changes_diff_path with
    | true, "repository-changes", None
      when repository_changes_context_visible state ~cols
          ~budget:(max 1 (rows - Masc_tui_frame.chrome_rows))
          ~cursor:state.repository_changes_cursor ->
        Option.bind state.repository_changes (fun snapshot ->
          List.nth_opt snapshot.rcs_changes state.repository_changes_cursor
          |> Option.map (fun row -> row.rc_path))
    | true, "repository-changes-diff", Some path
      when repository_changes_diff_context_visible state ~terminal_rows ~cols ~path -> Some path
    | (true | false), _, _ -> None in
  Option.map (fun path ->
    { rca_scope = state.workspace_authority, state.workspace_read_authority
    ; rca_repository = state.repository_changes_scope
    ; rca_surface = surface_key; rca_rows = terminal_rows; rca_cols = cols
    ; rca_path = path
    ; rca_context = resolve_change_context state ~path_opt:(Some path) }) path

let same_repository_change_authority left right =
  same_acting_pane_scope left.rca_scope right.rca_scope
  && left.rca_repository = right.rca_repository
  && String.equal left.rca_surface right.rca_surface
  && left.rca_rows = right.rca_rows && left.rca_cols = right.rca_cols
  && String.equal left.rca_path right.rca_path
  && left.rca_context = right.rca_context

let render_repository_changes (state : state) =
  match state.repository_changes_diff_path with
  | Some path -> render_repository_changes_diff state ~path
  | None ->
      let terminal_rows, cols = get_terminal_size () in
      let changes =
        match state.repository_changes with
        | Some snapshot -> snapshot.Masc.Tui_decode.rcs_changes
        | None -> []
      in
      let scope_name =
        match state.repository_changes_scope, state.repositories with
        | Some Tui_decode.Repository_change_project, _ -> "Project workspace"
        | Some (Tui_decode.Repository_change_repository id), Some snapshot ->
            (match
               List.find_opt
                 (fun (repo : Masc.Tui_decode.repository) ->
                   String.equal repo.rp_id id)
                 snapshot.rs_repositories
             with
             | Some repo -> repo.rp_name
             | None -> id)
        | Some (Tui_decode.Repository_change_repository id), None -> id
        | None, _ -> "Git workspace"
      in
      let title =
        detail_heading ~cols ~lead:(Lead_text " MASC Git Changes — ")
          ~id:scope_name
          ~after:(Printf.sprintf " (%d)%s" (List.length changes)
            (if Option.is_some state.repository_changes_error then " · read failed" else ""))
          ~tail:(connection_badge state)
      in
      let recorded_changes = current_keeper_chat_file_changes state in
      surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols ~surface_key:"repository-changes"
        ~title ~hints:Masc_tui_keys.footer_hints_git_changes
        ~body:(fun ~budget c ->
          let geometry = repository_changes_geometry state ~cols ~budget
              ~cursor:state.repository_changes_cursor in
          List.iter
            (fun ctx_line ->
              c.push ctx_line;
              c.push_divider ())
            geometry.rcg_context_lines;
          if geometry.rcg_header then begin
            c.push_styled ~style:(Theme.recede ())
              (Printf.sprintf "  %-18s %s" "State" "Path");
            c.push_divider ()
          end;
          (match state.repository_changes_error, geometry.rcg_error_rows with
           | None, _ -> ()
           | Some detail, rows when rows > 0 ->
               c.push_styled ~style:(Theme.bad ())
                 ("  " ^ Keeper_chat.terminal_safe_text detail);
               if rows = 2 then c.push_divider ()
           | Some _, _ -> ());
          let room = geometry.rcg_list_height in
          if changes = [] then
            c.push_styled ~style:(Theme.recede ())
              (match state.repository_changes, state.repository_changes_error with
               | None, None -> "  (loading Git changes)"
               | Some _, None -> "  (working tree clean)"
               | _, Some _ -> "  (Git changes unavailable)")
          else
            let max_scroll = max 0 (List.length changes - room) in
            let scroll = max 0 (min state.repository_changes_scroll max_scroll) in
            let scroll =
              match List.nth_opt changes state.repository_changes_cursor with
              | None -> scroll
              | Some _ -> Masc_tui_scroll.ensure_visible
                  ~cursor:state.repository_changes_cursor ~height:room scroll in
            let changes_window = Rows.of_list ~first:scroll ~height:room changes in
            for i = 0 to room - 1 do
              let idx = scroll + i in
              match Rows.at changes_window idx with
              | None -> c.push_empty ()
              | Some row ->
                  let attr =
                    match recorded_changes, geometry.rcg_context_lines with
                    | Some snap, _ :: _ ->
                        (match
                           List.find_opt
                             (file_change_matches_path ~scope:state.repository_changes_scope row.rc_path)
                             snap.Masc.Tui_decode.fcs_changes
                         with
                         | Some fc ->
                             let t =
                               match fc.fc_task_id with
                               | Some tid -> tid
                               | None -> fc.fc_keeper
                             in
                             " [record:" ^ t ^ "]"
                         | None -> "")
                    | Some _, [] | None, _ -> ""
                  in
                  let path = Terminal_text.single_line row.rc_path in
                  let path_cells = Message_layout.display_width path in
                  let available = max 1 (framed_inner_width cols - 21) in
                  (* A partial record label can look like a different task.
                     Drop it when it would crowd out the path; the selected
                     record still has its own context above the list. *)
                  let attr =
                    if Message_layout.display_width attr + min 8 path_cells <= available
                    then attr else ""
                  in
                  let line =
                    Printf.sprintf "%s%-18s %s%s"
                      (if geometry.rcg_error_rows = 0 && Option.is_some state.repository_changes_error
                       then "! " else "  ")
                      (repository_change_status row)
                      (Message_layout.truncate_middle
                         (max 1 (available - Message_layout.display_width attr)) path)
                      attr
                  in
                  if idx = state.repository_changes_cursor then c.push_selected line
                  else c.push line
            done)

let render_repositories (state : state) =
  if state.repository_changes_open then render_repository_changes state
  else render_repository_list state

(* One line of what the change put there. An edit shows the text it wrote
   rather than the text it removed: the question a reader has is what the file
   says now. A write shows its size, because the whole body is never one row
   and a truncated first line of a new file says less than its length. *)
let change_row_summary (change : Masc.Tui_decode.file_change) =
  let content =
    match change.Masc.Tui_decode.fc_kind with
    | Masc.Tui_decode.Fc_edited { after; _ } -> Terminal_text.preview_line after
    | Masc.Tui_decode.Fc_inserted { text; _ } -> Terminal_text.preview_line text
    | Masc.Tui_decode.Fc_written { content } ->
      Printf.sprintf "(wrote %d bytes)" (String.length content)
    | Masc.Tui_decode.Fc_materialized { bytes; _ } ->
      Printf.sprintf "(materialized %d bytes)" bytes
  in
  match file_change_evidence_label change.fc_line_evidence with
  | None -> content
  | Some label ->
    Printf.sprintf "%s%s[%s]%s %s" Ansi.bold (Theme.info ()) label Ansi.reset
      content

let change_kind_badge (change : Masc.Tui_decode.file_change) =
  match change.Masc.Tui_decode.fc_kind with
  | Masc.Tui_decode.Fc_edited _ -> Theme.category Theme.Slot_2, "EDIT"
  | Masc.Tui_decode.Fc_inserted _ -> Theme.category Theme.Slot_2, "MEMO"
  | Masc.Tui_decode.Fc_written _ -> (Masc_tui_theme.tone Masc_tui_theme.Accent), "WRITE"
  | Masc.Tui_decode.Fc_materialized _ ->
    (Masc_tui_theme.tone Masc_tui_theme.Accent), "WRITE"

let change_result_badge (change : Masc.Tui_decode.file_change) =
  if change.Masc.Tui_decode.fc_succeeded then Theme.ok (), "APPLIED"
  else Theme.bad (), "FAILED"

(* A row of the diff, drawn as layers rather than as one styled string.

   Three styles overlap on every line: the row's background, the gutter's
   weight, and the text's own colour. Concatenating them would let the
   gutter's reset close the background, and the line would lose its colour
   from the marker onward -- the fault [Masc_tui_span] exists for. *)
let diff_row_span ?(hscroll = 0) ~width (row : Diff.row) =
  let background, marker, text =
    match row with
    | Diff.Removed line -> (Span.bg Theme.Syntax.diff_removed_bg, "-", line)
    | Diff.Added line -> (Span.bg Theme.Syntax.diff_added_bg, "+", line)
    | Diff.Context line -> (Span.plain, " ", line)
  in
  (* Context is dim so the changed lines are what an eye lands on. The marker
     is bold against the same background, which is what tells the two apart
     where the terminal has no colour. *)
  let text_style =
    match row with
    | Diff.Context _ -> Span.combine background (Span.weight Ansi.dim)
    | Diff.Removed _ | Diff.Added _ -> background
  in
  let composed =
    Span.concat
      [ Span.text (Span.combine background (Span.weight Ansi.bold)) (marker ^ " ")
      ; Span.text text_style (Message_layout.drop_cells (Terminal_text.single_line text) hscroll)
      ]
  in
  (* Padded to the full width with the row's own background: colour that stops
     at the last character makes lines of different lengths look like
     different kinds of line. Truncated first, because padding does not
     shorten. *)
  Span.pad_to width background (Span.truncate width composed)

(* The two halves of one change. A write has no removed half: its before is
   empty, so every line arrives as an addition, which is what a new file is. *)
let change_diff_halves (change : Masc.Tui_decode.file_change) =
  match change.Masc.Tui_decode.fc_kind with
  | Masc.Tui_decode.Fc_edited { before; after; _ } -> (before, after)
  | Masc.Tui_decode.Fc_inserted { text; _ } -> ("", text)
  | Masc.Tui_decode.Fc_written { content } -> ("", content)
  | Masc.Tui_decode.Fc_materialized _ -> ("", "")

let render_changes_diff (state : state) (change : Masc.Tui_decode.file_change) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let before, after = change_diff_halves change in
  let diff_rows = Diff.rows ~before ~after in
  let removed, added = Diff.counts diff_rows in
  let total = List.length diff_rows in
  let header =
    detail_heading ~cols ~lead:(Lead_text (screen_title " MASC Change" ^ " "))
      ~id:(change_row_address change)
      ~after:(Printf.sprintf "  -%d +%d" removed added)
      ~tail:(connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  (* Facts about the change the rows themselves cannot carry. *)
  let notes =
    let turn =
      Printf.sprintf "  turn %s  task %s  %s"
        (Option.fold ~none:Masc_tui_theme.Glyph.no_value ~some:string_of_int
           change.Masc.Tui_decode.fc_turn)
        (Terminal_text.single_line
           (Option.value ~default:Masc_tui_theme.Glyph.no_value change.Masc.Tui_decode.fc_task_id))
        (if change.Masc.Tui_decode.fc_succeeded then "applied"
         else "the call failed; this is what it tried to write")
    in
    match change.Masc.Tui_decode.fc_kind with
    | Masc.Tui_decode.Fc_edited { replace_all = true; _ } ->
        (* Every occurrence changed, and the log records the text once. Showing
           one pair without saying so would undercount the change. *)
        [ turn; "  replace_all: every occurrence changed; the log holds the text once" ]
    | Masc.Tui_decode.Fc_edited { replace_all = false; _ }
    | Masc.Tui_decode.Fc_inserted _
    | Masc.Tui_decode.Fc_written _ -> [ turn ]
    | Masc.Tui_decode.Fc_materialized _ ->
        (* The call names the blob, not its bytes, so the log has no text to
           show. Saying so is the difference between an empty diff and a
           change that wrote nothing. *)
        [ turn; "  the log holds the blob's coordinates, not its bytes" ]
  in
  let notes =
    match file_change_evidence_label change.fc_line_evidence with
    | None -> notes
    | Some label -> notes @ [ "  producer lines " ^ label ]
  in
  List.iter (fun note -> box_line_styled buf cols ~style:(Theme.recede ()) note) notes;
  box_divider buf cols;
  (* Counted, not tallied. The tally read "7 + notes - 1" against four fixed
     rows plus the notes, which left the surface one row over its budget --
     and the row [finish_surface] then dropped was the footer, so the diff was
     the one screen that did not say how to leave it. *)
  let chrome_rows = count_frame_lines buf + listing_rows_below_the_body in
  (* The position row carries the esc hint at every count, so it is one of
     [listing_rows_below_the_body] and needs no row of its own. *)
  let content_height =
    Masc_tui_scroll.content_height ~rows ~chrome:chrome_rows ~count:total
      ~preview_keep:None ~overflow_takes_row:false
  in
  let max_scroll = max 0 (total - content_height) in
  let scroll = max 0 (min state.changes_diff_scroll max_scroll) in
  let diff_rows_window = Rows.of_list ~first:scroll ~height:content_height diff_rows in
  if total = 0 then begin
    box_line_styled buf cols ~style:(Theme.recede ())
      "  (the call recorded no text; there is nothing to compare)";
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for i = 0 to content_height - 1 do
      match Rows.at diff_rows_window (i + scroll) with
      | None -> box_empty buf cols
      | Some row -> box_line_span buf cols (diff_row_span ~hscroll:state.changes_diff_hscroll ~width:(framed_inner_width cols) row)
    done;
  let position = match Masc_tui_scroll.position_row ~scroll ~height:content_height total with
    | None -> ""
    | Some text -> " · " ^ String.trim text in
  box_line_styled buf cols ~style:(Theme.recede ())
    (Printf.sprintf "  col %d%s · esc closes" (state.changes_diff_hscroll + 1) position);
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols ~hints:"Shift-Left / Shift-Right:pan  j/k:scroll  Left / Esc:back  o:open in editor  q:quit");
  finish_surface state ~clamped:(Changes_diff_scroll scroll)
    ~surface_key:"changes" ~rows:terminal_rows ~cols buf

let render_changes_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let changes =
    match state.changes with
    | None -> []
    | Some s -> s.Masc.Tui_decode.fcs_changes
  in
  let shown = List.length changes in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let whose =
    match state.changes_keeper with
    | None -> "(no keeper selected)"
    | Some name -> name
  in
  let heading ~after =
    detail_heading ~cols
      ~lead:(Lead_text (screen_title " MASC Changes" ^ " "))
      ~id:whose ~after
      ~tail:(timestamp ^ "  " ^ connection_badge state)
  in
  let header =
    match state.changes with
    | None ->
        heading
          ~after:("  " ^ title_missing_reading ~error:state.changes_error)
    | Some s ->
        (* The window and the call count are stated because the list alone
           does not say what was looked at: no changes in a window and no
           calls in a window are different facts. *)
        heading
          ~after:
            (Printf.sprintf " (%d in %.0fh of %s)" shown
               s.Masc.Tui_decode.fcs_window_hours
               (Masc_tui_message_layout.count_noun
                  s.Masc.Tui_decode.fcs_calls_in_window "call"))
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  (* What the turn did takes the cells the drawn columns leave. *)
  let file_change_layout =
    Render_schedule.change_layout
      ~inner_width:(max 1 (framed_inner_width cols - 2))
  in
  let col_hdr =
    "  " ^ Render_schedule.change_header_row ~layout:file_change_layout
  in
  box_line_styled buf cols ~style:(Theme.recede ()) col_hdr;
  box_divider buf cols;
  (match state.changes_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  (* Changes the log could not carry are said out loud. A list that showed
     only what it had would tell an operator the turn wrote less than it did. *)
  let budget_note =
    match state.changes with
    | Some s when s.Masc.Tui_decode.fcs_over_budget > 0 ->
        Some
          (Printf.sprintf
             "  %d change(s) outgrew the tool-call log's inline budget; their text is not on disk"
             s.Masc.Tui_decode.fcs_over_budget)
    | Some _ | None -> None
  in
  (match budget_note with
   | None -> ()
   | Some note ->
       box_line_styled buf cols ~style:(Theme.recede ()) note;
       box_divider buf cols);
  (* The chrome and the preview's share both come from [scrolled_surface],
     which the keypress reads too. Working them out again here is what drifted
     the last time: this counted the over-budget note's two rows and the bound
     did not, and then the preview took half the body and the bound still did
     not know. *)
  let chrome_rows, preview_keep =
    match scrolled_surface state ~cols Changes with
    | Some s -> (s.sc_chrome, s.sc_preview_keep)
    | None -> (listing_chrome ~error:state.changes_error, None)
  in
  let total_content = max 1 (rows - chrome_rows) in
  (* The cursor row's recorded diff previews under the list, from the same
     local snapshot Enter renders -- no request rides a keypress. The list
     keeps at least [changes_preview_keep_rows] rows; the preview takes what
     remains.

     The split comes from Masc_tui_scroll because the keypress has to obey
     the height this draws. It also cannot depend on which row the cursor is
     on: reading the unclamped scroll to decide whether there is a preview
     made the height depend on the value that height was bounding, and the
     rows past the shortened list became unreachable. *)
  let preview_height =
    match preview_keep with
    | None -> 0
    | Some _ when shown = 0 -> 0
    | Some keep -> Masc_tui_scroll.preview_height ~total:total_content ~keep
  in
  (* The list's rows as the keypress counts them: what the preview leaves,
     less the scroll row while the list overflows. *)
  let content_height =
    match scrolled_surface state ~cols Changes with
    | Some s ->
        Masc_tui_scroll.content_height ~rows ~chrome:s.sc_chrome ~count:s.sc_count
          ~preview_keep:s.sc_preview_keep ~overflow_takes_row:s.sc_overflow_takes_row
    | None -> max 1 (total_content - preview_height)
  in
  let max_scroll = max 0 (shown - content_height) in
  let scroll = max 0 (min state.changes_scroll max_scroll) in
  let changes_window = Rows.of_list ~first:scroll ~height:content_height changes in
  (* The marked row, not the window's top row. They were the same field, so
     the mark never left the first drawn row: every row below it was visible
     and unselectable, and Enter always opened whichever change the window
     happened to start on. *)
  let cursor = max 0 (min state.changes_cursor (max 0 (shown - 1))) in
  let cursor_change = List.nth_opt changes cursor in
  if shown = 0 then begin
    let empty =
      match empty_page_of ~snapshot:state.changes ~error:state.changes_error with
      | Page_failed -> page_failed_note
      | Page_unread -> "  (pick a keeper on the Keepers surface, then press r)"
      | Page_empty -> "  (this keeper wrote no files in the window)"
    in
    box_line_styled buf cols ~style:(Theme.recede ()) empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for i = 0 to content_height - 1 do
      let idx = i + scroll in
      match Rows.at changes_window idx with
      | None -> box_empty buf cols
      | Some change ->
          let kind_style, kind = change_kind_badge change in
          let result_style, result = change_result_badge change in
          let line =
            "  "
            ^ Render_schedule.change_row ~op_style:kind_style ~result_style
                ~layout:file_change_layout
                { Render_schedule.crow_turn =
                    Option.fold ~none:Masc_tui_theme.Glyph.no_value ~some:string_of_int
                      change.Masc.Tui_decode.fc_turn
                ; crow_task =
                    Terminal_text.single_line
                      (Option.value ~default:Masc_tui_theme.Glyph.no_value
                         change.Masc.Tui_decode.fc_task_id)
                ; crow_op = kind
                ; crow_result = result
                ; crow_file =
                    Terminal_text.single_line (change_row_address change)
                ; crow_summary = change_row_summary change
                }
          in
          (* A call that failed still changed what the keeper tried to do, and
             it is the row an operator is looking for. Dim marks it as an
             attempt rather than hiding it. *)
          if idx = cursor then
            box_line_selected buf cols (Masc_tui_theme.strip_sgr line)
          else box_line buf cols line
    done;
  (match cursor_change with
   | None -> ()
   | Some change when preview_height >= 2 ->
       let before, after = change_diff_halves change in
       let diff_rows = Diff.rows ~before ~after in
       let removed, added = Diff.counts diff_rows in
       box_divider buf cols;
       box_line_styled buf cols ~style:(Theme.recede ())
         (Printf.sprintf "  preview %s  -%d +%d  (Enter opens, scrolls)"
            (Terminal_text.single_line (change_row_address change))
            removed added);
       let body_height = preview_height - 2 in
       let diff_rows_window = Rows.of_list ~first:0 ~height:body_height diff_rows in
       for i = 0 to body_height - 1 do
         match Rows.at diff_rows_window i with
         | Some row ->
             box_line_span buf cols (diff_row_span ~width:(framed_inner_width cols) row)
         | None -> box_empty buf cols
       done
   | Some _ -> ());
  if shown > content_height then
    box_line_styled buf cols ~style:(Theme.recede ())
      (Printf.sprintf "  [changes %s]" (Masc_tui_scroll.window_text ~scroll ~height:content_height shown));
  box_bottom buf cols;
  Buffer.add_string buf
    (* The footer is the key table's (for_surface Changes); never a literal here. *)
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints Changes));
  finish_surface state ~surface_key:"changes" ~rows:terminal_rows ~cols buf


(* What the tree holds for the file the cursor names. Separate from the
   tool-call reading by decision, not by accident: one says what the keeper
   tried to write and the other what survived, and a single view would make
   whichever it drew look like the whole answer. *)
let render_changes_tree_diff (state : state)
    (change : Masc.Tui_decode.file_change) =
  render_diff_surface state
    { ds_title = " MASC Tree"
    ; ds_address = Terminal_text.single_line (change_row_address change)
    ; ds_context_lines = []
    ; ds_diff = state.changes_tree_diff
    ; ds_error = state.changes_tree_diff_error
    ; ds_scroll = state.changes_diff_scroll
    ; ds_hscroll = state.changes_diff_hscroll
    ; ds_unchanged = "  (this file matches its last commit)"
    ; ds_esc_hint = "esc closes"
    ; ds_footer_hints = "Shift-Left / Shift-Right:pan  j/k:scroll  Left / Esc:back  o:open in editor  q:quit"
    ; ds_surface_key = "changes"
    ; ds_clamped = (fun scroll -> Changes_diff_scroll scroll)
    }

(* The surface has two readings: the list, and one change opened. The open row
   is held as an index, so a refresh that shortens the list closes the diff
   rather than drawing a change the answer no longer holds. *)
let render_changes (state : state) =
  match Masc_tui_types.opened_file_change state with
  | Some change ->
      (* A path being read names the tree reading. Both readings of the same
         row exist at once; which one is drawn is the operator's last key, not
         whichever answer arrived last. *)
      if Option.is_some state.changes_tree_diff_path then
        render_changes_tree_diff state change
      else render_changes_diff state change
  | None -> render_changes_list state

