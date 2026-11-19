(* A page key moves a list by the height the frame reports it drew that list
   in, less one (RFC tui-one-screen-grammar §3.1). The key reads the report
   and nothing else, so the report has to be the rows the renderer drew for
   the list. These tests draw a Board list and the Models table at two
   terminal sizes and every selection, and count the list's rows in the
   frame. *)

open Masc_tui_types
module Prim = Masc_tui_render_prim

let sizes = [ 24, 80; 40, 120 ]

(* The terminal the frame is drawn for, put back afterwards. *)
let with_size (rows, cols) draw =
  let cache = Masc_tui_ansi.terminal_size_cache in
  let previous = Masc_tui_ansi.get_terminal_size () in
  let previous_reserved = !Prim.acting_pane_reserved_cols in
  let set size =
    ignore
      (Masc_tui_render_schedule.Terminal_size_cache.refresh cache ~probe:(fun () -> Some size))
  in
  set (rows, cols);
  Prim.acting_pane_reserved_cols := 0;
  Fun.protect
    ~finally:(fun () ->
      set previous;
      Prim.acting_pane_reserved_cols := previous_reserved)
    draw

(* The frame's lines without colour, and the lists it reported drawn. *)
let draw render state =
  Prim.frame_lists := [];
  let frame, _ = render state in
  ( List.map Masc_tui_theme.strip_sgr frame.Masc_tui_frame_presenter.lines
  , !Prim.frame_lists )

let rows_naming marker lines =
  let has line =
    let length = String.length marker in
    let rec at index =
      index + length <= String.length line
      && (String.sub line index length = marker || at (index + 1))
    in
    at 0
  in
  List.length (List.filter has lines)

let reported list lists =
  List.filter_map
    (fun (drawn : drawn_list) -> if drawn.dl_list = list then Some drawn.dl_height else None)
    lists

let board_post index : board_post =
  { bp_id = Printf.sprintf "post-%02d" index
  ; bp_author = "author"
  ; bp_title = Printf.sprintf "zq-%02d" index
  ; bp_body = ""
  ; bp_votes = 0
  ; bp_comment_count = 0
  ; bp_created_at = "2026-11-19T00:00:00Z"
  ; bp_created_at_unix = Some 1_790_000_000.
  ; bp_updated_at = Some 1_790_000_000.
  ; bp_hearth = None
  ; bp_kind = None
  ; bp_closed = None
  ; bp_attachments = [] }

(* QA N01's shape on the Board: the list is cut below a heading, and its page
   was the body less eight, so PgDn at 80x24 moved past rows nobody saw.
   Every selection reports the Board list once, as tall as the post rows the
   frame drew. *)
let test_board_reports_the_rows_it_drew () =
  let posts = List.init 40 board_post in
  List.iter
    (fun size ->
      with_size size (fun () ->
        let state = create_state ~workspace:"" ~port:0 () in
        state.view <- Board;
        state.board_listing <-
          Masc_tui_fetched.Ready { bl_query = board_query state; bl_posts = posts };
        List.iter
          (fun cursor ->
            state.board_cursor <- cursor;
            let lines, lists = draw Masc_tui_render_board.render_board_list state in
            Alcotest.(check (list int))
              (Printf.sprintf "%dx%d, post %d: the height reported is the post rows drawn"
                 (snd size) (fst size) cursor)
              [ rows_naming "zq-" lines ] (reported Board_post_rows lists);
            Alcotest.(check int) "no other list is reported" 1 (List.length lists))
          [ 0; 1; 20; 39 ]))
    sizes

let model_row index : Masc_tui_model_runtime_table.row =
  { model = Printf.sprintf "mq-%02d" index
  ; provider = "prov"
  ; api_name = None
  ; reasoning_effort = None
  ; temperature = None
  ; context = None
  ; model_context = None
  ; max_tokens = Some 1000
  ; same_login = []
  ; login_group = None
  ; account_label = None }

let models_state ~emails rows =
  let state = create_state ~workspace:"" ~port:0 () in
  state.view <- Config;
  state.config_pane <- Config_models;
  let metadata : Masc_tui_runtime_config_view.metadata =
    { source_revision = "r"
    ; validation =
        Checked
          { valid = true; schema_version = 1; current_schema_version = 1
          ; forward_schema = false; issues = [] }
    ; routing = Routing_active; routing_requires_restart = false
    ; keeper = Not_configured; keeper_requires_restart = false
    ; configured_count = 0; pending_keys = []; applied_keys = []; preempted_keys = [] }
  in
  state.runtime_config_view <-
    Some
      { rcv_path = "runtime.toml"; rcv_source_text = ""; rcv_rows = []
      ; rcv_metadata = metadata
      ; rcv_account_emails = emails };
  state.config_models_rows <- rows;
  state

(* The Models table draws its column names on its first line until the
   selection passes the first window, so a window shows one binding fewer at
   the top than further down. A page is the fewest bindings any window shows
   whole: the report is that, the same for every selection, and no window
   draws fewer. Reported as the pane's height, PgDn from the top window
   passed the binding under its last row. The account lines above the table
   take one row when the account is read and two when it is not, so the
   table's height is the drawing's and no fixed share of the body. *)
let test_models_report_the_fewest_bindings_a_window_draws () =
  let count = 60 in
  let accounts =
    [ "read", Ok (Masc_tui_account_login.Email_rows { rows = []; unattributed = 0 })
    ; "unread", Error "account evidence unavailable" ]
  in
  List.iter
    (fun (size, (account, emails)) ->
      with_size size (fun () ->
        let state = models_state ~emails (List.init count model_row) in
        let drawn_at cursor =
          state.config_models_cursor <- cursor;
          Option.iter
            (fun (list : Masc_tui_render_config.models_list) ->
              state.config_scroll <- list.ml_window ~cursor state.config_scroll)
            (Masc_tui_render_config.config_models_list state ~terminal_rows:(fst size)
               ~cols:(snd size));
          let lines, lists = draw Masc_tui_render_config.render_config_models state in
          (rows_naming "mq-" lines, reported Model_bindings lists)
        in
        let readings = List.init count drawn_at in
        let fewest = List.fold_left (fun fewest (rows, _) -> min fewest rows) count readings in
        Alcotest.(check bool)
          (Printf.sprintf "%dx%d: the pane is shorter than the bindings" (snd size) (fst size))
          true (fewest < count);
        List.iteri
          (fun cursor (_, report) ->
            Alcotest.(check (list int))
              (Printf.sprintf "%dx%d, account %s, binding %d: the report is the fewest bindings drawn"
                 (snd size) (fst size) account cursor)
              [ fewest ] report)
          readings))
    (List.concat_map (fun size -> List.map (fun account -> size, account) accounts) sizes)

let () =
  Alcotest.run "tui render list heights"
    [ ( "reported heights"
      , [ Alcotest.test_case "the Board reports the rows it drew" `Quick
            test_board_reports_the_rows_it_drew
        ; Alcotest.test_case "the Models table reports the fewest bindings a window draws" `Quick
            test_models_report_the_fewest_bindings_a_window_draws
        ] )
    ]
