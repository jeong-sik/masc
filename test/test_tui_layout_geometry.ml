(* Geometry harness for the TUI's pure layout decisions
   (RFC tui-one-screen-grammar §10).

   Each case sweeps terminal sizes through one decision and checks what must
   hold at every size: rows exactly as wide as asked, never more rows than
   asked, column widths and gaps that add up, a too-small reason whose numbers
   agree with the decision, and a decision that a larger terminal cannot undo.
   The surface frame [finish_surface] assembles is measured too, because the
   decision's row budget is only true if the drawer spends the same rows.
   No case reads wording, a position on the screen or the order of rows.

   A size that once broke stays in [pinned_rows] / [pinned_cols] with the
   reason it is there. *)

module Viewport = Masc_tui_render_schedule.Viewport
module Schedule = Masc_tui_render_schedule
module Card = Masc_tui_card
module Layout = Masc_tui_message_layout

let range ~from ~upto ~step =
  List.init (((upto - from) / step) + 1) (fun index -> from + (index * step))

let dedup sizes = List.sort_uniq compare sizes

(* The sweep: columns 8 to 240 every 7, rows 8 to 80 every 3. No column
   threshold exists, so the narrow terminals are swept too. *)
let swept_cols = range ~from:8 ~upto:240 ~step:7
let swept_rows = range ~from:8 ~upto:80 ~step:3

(* Terminal rows that once broke a decision. *)
let pinned_rows =
  [ (* The body's budget gave the composer's row back on a short terminal,
       but [finish_surface] draws the composer at every size. With no agenda
       strip, 15 rows drew a frame of 16; with the strip up, 16 rows did once
       the budget weighed the composer after the agenda. *)
    15; 16; 17
  ; (* PR #49459: an 8-row terminal cut the too-small count at 40, 43 and 56
       columns. *)
    8 ]

let pinned_cols = [ 40; 43; 56 ]

(* Agenda rows the strip can take, and one more than it does today. *)
let agenda_rows_cases = [ 0; 1; 2 ]

let below_strip rows = Viewport.below_strip ~terminal_rows:rows

let decide ~cols ~rows ~agenda_rows () =
  Viewport.too_small ~terminal_rows:(below_strip rows) ~terminal_cols:cols
    ~agenda_rows ~notice_needs_full_frame:(fun () -> false)

let fits ~cols ~rows ~agenda_rows =
  Option.is_none (decide ~cols ~rows ~agenda_rows ())

(* Rows either side of every row threshold, as the decision states it on the
   shortest terminal. *)
let boundary_rows =
  List.concat_map
    (fun agenda_rows ->
       match decide ~cols:80 ~rows:1 ~agenda_rows () with
       | Some (Viewport.Rows_short { need_rows; _ }) -> [ need_rows - 1; need_rows; need_rows + 1 ]
       | Some Viewport.Notice_needs_full_frame | None -> [])
    agenda_rows_cases

let terminal_rows_list = dedup (swept_rows @ boundary_rows @ pinned_rows)

(* Failures a case names before it only counts the rest. *)
let failures_named = 20

let report failures =
  let shown = List.filteri (fun index _ -> index < failures_named) failures in
  let more = List.length failures - List.length shown in
  if more > 0 then shown @ [ Printf.sprintf "... %d more" more ] else shown

let expect_none label failures =
  Alcotest.(check (list string)) label [] (report (List.rev failures))

(* -------------------------------------------------------------------- *)
(* The too-small decision. *)

(* The decision fits exactly where the body holds the fixed budget. *)
let fits_where_the_body_holds_the_budget () =
  let failures = ref [] in
  let fail fmt = Printf.ksprintf (fun text -> failures := text :: !failures) fmt in
  List.iter
    (fun agenda_rows ->
       List.iter
         (fun rows ->
            let body = Viewport.body_rows ~terminal_rows:(below_strip rows) ~agenda_rows in
            let fits_now = fits ~cols:80 ~rows ~agenda_rows in
            if body < 1 then fail "agenda %d, %d rows: body %d" agenda_rows rows body;
            if fits_now <> (body >= Viewport.minimum_fixed_chrome_rows) then
              fail "agenda %d, %d rows: fits %b with body %d" agenda_rows rows fits_now body)
         terminal_rows_list)
    agenda_rows_cases;
  expect_none "the decision fits where the body holds the budget" !failures

let reason_agrees_with_decision () =
  let failures = ref [] in
  let fail fmt = Printf.ksprintf (fun text -> failures := text :: !failures) fmt in
  let cols_list = dedup (swept_cols @ pinned_cols) in
  List.iter
    (fun agenda_rows ->
       List.iter
         (fun cols ->
            List.iter
              (fun rows ->
                 match decide ~cols ~rows ~agenda_rows () with
                 | None -> ()
                 | Some Viewport.Notice_needs_full_frame ->
                     fail "agenda %d, %dx%d: a notice reason with no notice" agenda_rows cols rows
                 | Some (Viewport.Rows_short { have; need_rows }) ->
                     let at = Printf.sprintf "agenda %d, %dx%d" agenda_rows cols rows in
                     if have.cols <> cols then fail "%s: have %d columns" at have.cols;
                     if have.rows <> rows then fail "%s: have %d rows" at have.rows;
                     if have.rows >= need_rows then fail "%s: needs %d rows" at need_rows;
                     if not (fits ~cols ~rows:need_rows ~agenda_rows) then
                       fail "%s: does not fit at the %d rows it needs" at need_rows;
                     (match decide ~cols ~rows:(need_rows - 1) ~agenda_rows () with
                      | Some (Viewport.Rows_short { need_rows = again; _ }) when again = need_rows -> ()
                      | Some (Viewport.Rows_short { need_rows = again; _ }) ->
                          fail "%s: one row short of %d needs %d" at need_rows again
                      | Some Viewport.Notice_needs_full_frame | None ->
                          fail "%s: one row short of %d already fits" at need_rows))
              terminal_rows_list)
         cols_list)
    agenda_rows_cases;
  expect_none "the reason's numbers are the decision's" !failures

let notice_is_the_reason_only_when_rows_fit () =
  let failures = ref [] in
  let fail fmt = Printf.ksprintf (fun text -> failures := text :: !failures) fmt in
  List.iter
    (fun agenda_rows ->
       List.iter
         (fun rows ->
            let asked = ref false in
            let reason =
              Viewport.too_small ~terminal_rows:(below_strip rows) ~terminal_cols:80
                ~agenda_rows ~notice_needs_full_frame:(fun () -> asked := true; true)
            in
            match fits ~cols:80 ~rows ~agenda_rows, reason with
            | true, Some Viewport.Notice_needs_full_frame -> ()
            | false, Some (Viewport.Rows_short _) ->
                if !asked then fail "agenda %d, %d rows: notice asked while rows short" agenda_rows rows
            | true, (Some (Viewport.Rows_short _) | None)
            | false, (Some Viewport.Notice_needs_full_frame | None) ->
                fail "agenda %d, %d rows: wrong reason with a wide notice" agenda_rows rows)
         terminal_rows_list)
    agenda_rows_cases;
  expect_none "a wide notice decides only when the rows fit" !failures

(* A terminal larger in both axes than one that fits also fits. *)
let decision_is_monotone () =
  let failures = ref [] in
  let fail fmt = Printf.ksprintf (fun text -> failures := text :: !failures) fmt in
  let cols_list = dedup (swept_cols @ pinned_cols) in
  let sizes =
    List.concat_map (fun cols -> List.map (fun rows -> (cols, rows)) terminal_rows_list) cols_list
  in
  List.iter
    (fun agenda_rows ->
       let fitting = List.filter (fun (cols, rows) -> fits ~cols ~rows ~agenda_rows) sizes in
       List.iter
         (fun (cols, rows) ->
            List.iter
              (fun (wider, taller) ->
                 if wider >= cols && taller >= rows && not (fits ~cols:wider ~rows:taller ~agenda_rows)
                 then
                   fail "agenda %d: %dx%d fits, %dx%d does not" agenda_rows cols rows wider taller)
              sizes)
         fitting)
    agenda_rows_cases;
  expect_none "a larger terminal still fits" !failures

(* The size line's form. PR #49459's count, cut to its first digit, is a
   form wider than the terminal; a count-carrying form must be chosen at
   the pinned widths, and no chosen form is wider than the terminal. *)
let hint_forms_fit () =
  let failures = ref [] in
  let fail fmt = Printf.ksprintf (fun text -> failures := text :: !failures) fmt in
  let module Hint = Masc_tui_too_small_hint in
  let order = function
    | Hint.Full -> 0
    | Hint.Size_and_need -> 1
    | Hint.Need -> 2
    | Hint.Need_count -> 3
    | Hint.Key_only -> 4
  in
  let cols_list = dedup (swept_cols @ pinned_cols) in
  List.iter
    (fun ko ->
       List.iter
         (fun agenda_rows ->
            List.iter
              (fun rows ->
                 let previous = ref (order Hint.Key_only) in
                 List.iter
                   (fun cols ->
                      match decide ~cols ~rows ~agenda_rows () with
                      | None | Some Viewport.Notice_needs_full_frame -> ()
                      | Some (Viewport.Rows_short { have; need_rows }) ->
                          let at = Printf.sprintf "ko %b, agenda %d, %dx%d" ko agenda_rows cols rows in
                          let form = Hint.choose ~ko ~cols ~have ~need_rows in
                          let width = Layout.display_width (Hint.text ~ko ~have ~need_rows form) in
                          (match form with
                           | Hint.Full | Hint.Size_and_need | Hint.Need | Hint.Need_count ->
                               if width > cols then fail "%s: a form of %d cells" at width
                           | Hint.Key_only ->
                               if List.mem cols pinned_cols then fail "%s: the count is gone" at);
                          (* A wider terminal never takes a narrower form. *)
                          if order form > !previous then fail "%s: a narrower form than at fewer columns" at;
                          previous := order form)
                   cols_list)
              (List.filter (fun rows -> not (fits ~cols:80 ~rows ~agenda_rows)) terminal_rows_list))
         agenda_rows_cases)
    [ true; false ];
  expect_none "the size line keeps its count at the pinned widths and fits" !failures

(* -------------------------------------------------------------------- *)
(* The surface frame [finish_surface] assembles: strip, body, agenda strip
   and composer, at every size the decision lets a surface draw in. *)

let agenda_strip_up (state : Masc_tui_types.state) =
  state.schedules_agenda <-
    Some
      { Masc_tui_types.scs_status = "ok"
      ; scs_read_error = None
      ; scs_request_count = None
      ; scs_truncated = false
      ; scs_payload_target = None
      ; scs_paging = Masc_tui_types.Schedule_paging_unavailable
      ; scs_next_due_iso = None
      ; scs_counts = None
      ; scs_rows = []
      ; scs_observed_at = 1793005140.
      ; scs_runner_status = Masc.Tui_decode.Runner_unrecognised "unknown"
      };
  state.schedules_agenda_freshness <- Masc_tui_agenda.Refresh_needed

let frame_cols = dedup (swept_cols @ pinned_cols)

(* The frame a surface of [drawn] rows ends in on a [cols] x [rows]
   terminal, measured the way [Masc_tui_render] measures it. *)
let surface_frame state ~cols ~rows ~drawn =
  ignore
    (Masc_tui_render_schedule.Terminal_size_cache.refresh Masc_tui_ansi.terminal_size_cache
       ~probe:(fun () -> Some (rows, cols)));
  let below, inner_cols = Masc_tui_render_prim.get_terminal_size () in
  let buf = Buffer.create 256 in
  for index = 1 to drawn do
    Buffer.add_string buf (Printf.sprintf "row %d\n" index)
  done;
  fst (Masc_tui_render_prim.finish_surface state ~surface_key:"geometry" ~rows:below ~cols:inner_cols buf)

let widest frame =
  List.fold_left (fun widest line -> max widest (Layout.display_width line)) 0
    frame.Masc_tui_frame_presenter.lines

let surface_frame_fits_the_terminal () =
  let failures = ref [] in
  let fail fmt = Printf.ksprintf (fun text -> failures := text :: !failures) fmt in
  Masc_tui_render_prim.acting_pane_reserved_cols := 0;
  let measured = ref 0 in
  List.iter
    (fun agenda_up ->
       let state = Masc_tui_types.create_state ~workspace:"geometry" ~port:1 () in
       if agenda_up then agenda_strip_up state;
       let agenda_rows = Masc_tui_types.agenda_chrome_rows state in
       if agenda_up && agenda_rows = 0 then fail "the agenda strip did not come up";
       let fitting_rows = List.filter (fun rows -> fits ~cols:1 ~rows ~agenda_rows) terminal_rows_list in
       (* The widest row the frame draws on a one-column terminal. Under it
          some row is wider than the terminal, and the too-small decision does
          not stop that yet (RFC tui-one-screen-grammar §12, issue #53189).
          The row count is measured at every width. *)
       let floor =
         match fitting_rows with
         | rows :: _ -> widest (surface_frame state ~cols:1 ~rows ~drawn:3)
         | [] -> fail "agenda %d: no row count fits" agenda_rows; 0
       in
       List.iter
         (fun cols ->
            List.iter
              (fun rows ->
                 incr measured;
                 (* A surface that drew a few rows, and one that drew more
                    than its budget. *)
                 List.iter
                   (fun drawn ->
                      let frame = surface_frame state ~cols ~rows ~drawn in
                      let at = Printf.sprintf "agenda %d, %dx%d, %d drawn" agenda_rows cols rows drawn in
                      let lines = List.length frame.Masc_tui_frame_presenter.lines in
                      if lines > rows then fail "%s: %d lines" at lines;
                      if frame.terminal_rows <> rows then
                        fail "%s: declares %d rows" at frame.terminal_rows;
                      if cols >= floor && widest frame > cols then
                        fail "%s: a row of %d cells" at (widest frame))
                   [ 3; rows * 2 ])
              fitting_rows)
         frame_cols)
    [ false; true ];
  if !measured = 0 then fail "no size fitted";
  expect_none "the surface frame is never taller or wider than the terminal" !failures

(* -------------------------------------------------------------------- *)
(* Cards. *)

let style =
  { Card.border = "\027[90m"
  ; focused_border = "\027[94m"
  ; title_style = "\027[1m"
  ; reset = "\027[0m"
  }

let edge ?key ?status ?count ?(focus = Card.Unfocused) name =
  { Card.name; key; status; count; focus; border_accent = None; footer_keys = [] }

let failed = { Card.symbol = Card.Mark Masc_tui_value.Mark.Failed; word = "실패"; tone = "\027[31m" }
let unreported =
  { Card.symbol = Card.Unknown Masc_tui_value.Unknown.Unreported; word = ""; tone = "\027[2m" }

let edges =
  [ edge ""
  ; edge "Decisions"
  ; edge ~key:("p", "\027[1m") ~status:failed ~count:(Card.Whole 7) "결정을 기다리는 일"
  ; edge ~status:unreported ~count:(Card.Partial { loaded = 50; total = 2000 })
      (String.make 70 'n')
  ; edge ~focus:Card.Focused_list ~count:(Card.Whole 1_234_567) "Keepers"
  ; edge ~focus:Card.Focused_other ~status:failed ~count:(Card.Whole 3) "📦 packages"
  ]

(* Bodies that ask for no rows, a few short ones, rows wider than any card,
   and wide characters. *)
let bodies =
  [ (fun ~cells:_ -> [])
  ; (fun ~cells:_ -> [ "one" ])
  ; (fun ~cells:_ -> List.init 5 (fun index -> Printf.sprintf "row %d" index))
  ; (fun ~cells:_ -> [ String.make 400 'w'; "\027[31m" ^ String.make 90 'x' ^ "\027[0m" ])
  ; (fun ~cells -> List.init 3 (fun _ -> String.concat "" (List.init cells (fun _ -> "가"))))
  ]

let cards =
  List.concat_map (fun edge -> List.map (fun body -> { Card.edge; body }) bodies) edges

(* Stacks for a grid of [columns] columns: one card each, two and three
   stacked, an empty column. *)
let stacks ~columns =
  let take count from = List.filteri (fun index _ -> index < count) from in
  let card index = List.nth cards (index mod List.length cards) in
  [ List.init columns (fun index -> [ card index ])
  ; List.init columns (fun index -> [ card (index * 3); card ((index * 3) + 1) ])
  ; List.init columns (fun index -> take 3 (List.filteri (fun i _ -> i >= index * 5) cards))
  ; List.init columns (fun index -> if index = columns - 1 then [] else [ card (index + 7) ])
  ]

(* The card layouts the screens use, by minimum card width, gap and most
   columns, and two denser ones. *)
let card_layouts = [ (44, 2, 2); (52, 2, 2); (20, 1, 4); (30, 2, 3) ]

(* Inner widths: the swept terminals' and, for every layout, one either side
   of each width where another column fits. *)
let inner_widths =
  let swept = List.map (fun cols -> Masc_tui_frame.inner_width ~cols) (swept_cols @ pinned_cols) in
  let boundaries =
    List.concat_map
      (fun (min_card_width, gap, max_columns) ->
         List.concat_map
           (fun columns ->
              let at = (columns * min_card_width) + ((columns - 1) * gap) in
              [ at - 1; at; at + 1 ])
           (range ~from:1 ~upto:max_columns ~step:1))
      card_layouts
  in
  dedup (List.filter (fun width -> width >= 0) (swept @ boundaries))

let body_rows_list =
  dedup (List.map (fun rows -> Viewport.body_rows ~terminal_rows:(below_strip rows) ~agenda_rows:0)
           terminal_rows_list)

let widths_add_up () =
  let failures = ref [] in
  let fail fmt = Printf.ksprintf (fun text -> failures := text :: !failures) fmt in
  List.iter
    (fun (min_card_width, gap, max_columns) ->
       let layout = Printf.sprintf "min %d gap %d max %d" min_card_width gap max_columns in
       List.iter
         (fun inner_width ->
            let columns = Card.columns_that_fit ~inner_width ~gap ~min_card_width ~max_columns in
            let need count = (count * min_card_width) + ((count - 1) * gap) in
            if columns < 1 || columns > max_columns then
              fail "%s, inner %d: %d columns" layout inner_width columns;
            if columns > 1 && need columns > inner_width then
              fail "%s, inner %d: %d columns need %d" layout inner_width columns (need columns);
            if columns < max_columns && need (columns + 1) <= inner_width then
              fail "%s, inner %d: %d columns where %d fit" layout inner_width columns (columns + 1);
            let widths = Card.column_widths ~inner_width ~gap ~columns in
            let total = List.fold_left ( + ) 0 widths + (gap * (columns - 1)) in
            if List.length widths <> columns then
              fail "%s, inner %d: %d widths for %d columns" layout inner_width (List.length widths) columns;
            if total <> inner_width then
              fail "%s, inner %d: widths and gaps add up to %d" layout inner_width total;
            let widest = List.fold_left max 0 widths and narrowest = List.fold_left min max_int widths in
            if widest - narrowest > 1 then
              fail "%s, inner %d: widths %d..%d" layout inner_width narrowest widest;
            if columns > 1 && narrowest < min_card_width then
              fail "%s, inner %d: a column of %d under the minimum" layout inner_width narrowest)
         inner_widths)
    card_layouts;
  expect_none "column widths and gaps add up to the inner width" !failures

(* The selection as a grid takes it beside each card: out of reach of every
   card, within reach of every card, and held by the first card of the first
   column. What the selection can reach decides which cards may squash, so
   the sweep runs every case. *)
let selection_cases =
  [ ("unselectable", fun _ _ -> Card.Unselectable)
  ; ("selectable", fun _ _ -> Card.Selectable)
  ; ( "held"
    , fun column index ->
        if column = 0 && index = 0 then Card.Holds_selected_row else Card.Selectable )
  ]

let with_selection selection_of stack =
  List.mapi
    (fun column cards -> List.mapi (fun index card -> (card, selection_of column index)) cards)
    stack

let grid_fits_its_rectangle () =
  let failures = ref [] in
  let fail fmt = Printf.ksprintf (fun text -> failures := text :: !failures) fmt in
  List.iter
    (fun ko ->
       List.iter
         (fun (min_card_width, gap, max_columns) ->
            List.iter
              (fun inner_width ->
                 let columns = Card.columns_that_fit ~inner_width ~gap ~min_card_width ~max_columns in
                 List.iteri
                   (fun shape stack ->
                      List.iter
                        (fun (selection, selection_of) ->
                           let at = Printf.sprintf "ko %b, min %d gap %d, inner %d, shape %d, %s"
                               ko min_card_width gap inner_width shape selection in
                           let layout max_rows =
                             Card.grid ~ko ~style ~inner_width ~gap ~row_gap:1 ~max_rows
                               (with_selection selection_of stack) in
                           let check_width asked rows =
                             List.iteri
                               (fun row line ->
                                  let width = Layout.display_width line in
                                  if width <> inner_width then
                                    fail "%s: %s rows asked, row %d is %d cells" at asked row width)
                               rows in
                           match layout max_int with
                           | None -> fail "%s: no grid with unbounded rows" at
                           | Some natural ->
                               let height = List.length natural in
                               check_width "unbounded" natural;
                               List.iter
                                 (fun max_rows ->
                                    match layout max_rows with
                                    | Some rows ->
                                        let drawn = List.length rows in
                                        check_width (string_of_int max_rows) rows;
                                        if drawn > max_rows then
                                          fail "%s: %d rows asked, %d drawn" at max_rows drawn
                                        else if height <= max_rows && drawn <> height then
                                          fail "%s: %d rows asked, %d drawn of %d that fit" at
                                            max_rows drawn height
                                    | None when height > max_rows -> ()
                                    | None ->
                                        fail "%s: %d rows asked, %d needed, none drawn" at
                                          max_rows height)
                                 body_rows_list)
                        selection_cases)
                   (stacks ~columns))
              inner_widths)
         card_layouts)
    [ true; false ];
  expect_none "a grid is exactly its width and never taller than asked" !failures

let card_fills_its_rectangle () =
  let failures = ref [] in
  let fail fmt = Printf.ksprintf (fun text -> failures := text :: !failures) fmt in
  let widths = dedup (range ~from:0 ~upto:24 ~step:1 @ inner_widths) in
  List.iter
    (fun ko ->
       List.iteri
         (fun index card ->
            List.iter
              (fun width ->
                 List.iter
                   (fun height ->
                      let rows = Card.render ~ko ~style ~width ~height card in
                      if List.length rows <> height then
                        fail "card %d, %dx%d: %d rows" index width height (List.length rows);
                      List.iteri
                        (fun row line ->
                           let cells = Layout.display_width line in
                           if cells <> width then
                             fail "card %d, %dx%d: row %d is %d cells" index width height row cells)
                        rows)
                   (range ~from:0 ~upto:8 ~step:1))
              widths)
         cards)
    [ true; false ];
  expect_none "a card is exactly the rectangle it was given" !failures

(* -------------------------------------------------------------------- *)
(* The Dashboard's cards. *)

let overview_cards_fit () =
  let failures = ref [] in
  let fail fmt = Printf.ksprintf (fun text -> failures := text :: !failures) fmt in
  let overview_edges =
    { Masc_tui_overview_cards.decisions = edge ~status:failed ~count:(Card.Whole 2) "결정"
    ; continuation = edge "Continue"
    ; capacity = edge ~status:unreported "Capacity"
    ; actions = edge ~count:(Card.Whole 1) "Needs you"
    }
  in
  let long = String.concat " " (List.init 30 (fun index -> Printf.sprintf "word%d" index)) in
  let decisions = [ (0, "geek-scout 에게 답하기"); (1, long) ] in
  let continuation = [ (2, "kidsnote-incoming-dd-manager"); (3, String.make 120 'k') ] in
  let status ~cells = [ String.make (cells + 9) 's'; "ok" ] in
  List.iter
    (fun actions ->
       List.iter
         (fun inner ->
            List.iter
              (fun rows ->
                 let at = Printf.sprintf "inner %d, %d rows, %d actions" inner rows (List.length actions) in
                 match
                   Masc_tui_overview_cards.draw ~ko:true ~edges:overview_edges
                     ~inner ~rows ~is_selected:(fun action -> action = 1)
                     ~decisions ~decisions_whole:true ~continuation ~status
                     ~keep_actions_card:false ~actions
                 with
                 | None -> ()
                 | Some lines ->
                     if List.length lines > rows then fail "%s: %d lines" at (List.length lines);
                     List.iteri
                       (fun row line ->
                          let width = Layout.display_width line in
                          if width <> inner then fail "%s: row %d is %d cells" at row width)
                       lines)
              body_rows_list)
         inner_widths)
    [ []; [ (4, "approve the release"); (5, long) ] ];
  expect_none "the Dashboard's cards are exactly the inner width and fit the rows" !failures

(* -------------------------------------------------------------------- *)
(* The Keeper roster's columns. *)

(* The narrowest row the roster allocates: every column at its floor. Below
   it the fixed columns alone are wider than the frame, and the too-small
   decision does not stop that yet (RFC tui-one-screen-grammar §12, issue
   #53189). *)
let roster_floor =
  Schedule.keeper_columns_used_width
    (Schedule.allocate_keeper_columns ~prioritize_runtime:false ~inner_width:0 ~widest_runtime:0 ())

(* The swept terminals' inner widths from the roster's floor up, and one
   either side of every width where the roster shows or drops a column. *)
let roster_inner_widths =
  let swept =
    List.filter (fun width -> width >= roster_floor)
      (List.map (fun cols -> Masc_tui_frame.inner_width ~cols) (swept_cols @ pinned_cols))
  in
  let shown inner_width =
    let columns =
      Schedule.allocate_keeper_columns ~prioritize_runtime:false ~inner_width ~widest_runtime:0 ()
    in
    (columns.kcol_show_flags, columns.kcol_show_runtime, columns.kcol_show_detail)
  in
  let lowest = List.fold_left min max_int swept and highest = List.fold_left max 0 swept in
  let changes =
    List.concat_map
      (fun inner_width ->
         if shown inner_width <> shown (inner_width - 1) then
           [ inner_width - 1; inner_width; inner_width + 1 ]
         else [])
      (range ~from:(lowest + 1) ~upto:highest ~step:1)
  in
  dedup (List.filter (fun width -> width >= roster_floor) ((roster_floor :: swept) @ changes))

let keeper_columns_fit () =
  let failures = ref [] in
  let fail fmt = Printf.ksprintf (fun text -> failures := text :: !failures) fmt in
  List.iter
    (fun inner_width ->
       List.iter
         (fun (runtime_visible, detail_beside_runtime, prioritize_runtime) ->
            List.iter
              (fun (widest_runtime, widest_detail) ->
                 let columns =
                   Schedule.allocate_keeper_columns ~runtime_visible ~detail_beside_runtime
                     ~widest_detail ~prioritize_runtime ~inner_width ~widest_runtime ()
                 in
                 let used = Schedule.keeper_columns_used_width columns in
                 if used > inner_width then
                   fail "inner %d, runtime %b, detail beside %b, priority %b, widest %d/%d: %d cells"
                     inner_width runtime_visible detail_beside_runtime prioritize_runtime
                     widest_runtime widest_detail used)
              [ (0, 0); (20, 0); (49, 40) ])
         [ (true, true, false); (true, true, true); (false, true, false); (true, false, false) ])
    roster_inner_widths;
  expect_none "the roster's columns never overrun the inner width" !failures

let () =
  Alcotest.run "tui layout geometry"
    [ ( "too-small decision"
      , [ Alcotest.test_case "fits where the body holds the budget" `Quick
            fits_where_the_body_holds_the_budget
        ; Alcotest.test_case "the reason's numbers are the decision's" `Quick
            reason_agrees_with_decision
        ; Alcotest.test_case "a wide notice decides only when rows fit" `Quick
            notice_is_the_reason_only_when_rows_fit
        ; Alcotest.test_case "a larger terminal still fits" `Quick decision_is_monotone
        ; Alcotest.test_case "the size line keeps its count" `Quick hint_forms_fit
        ] )
    ; ( "surface frame"
      , [ Alcotest.test_case "never taller or wider than the terminal" `Quick
            surface_frame_fits_the_terminal ] )
    ; ( "cards"
      , [ Alcotest.test_case "widths and gaps add up" `Quick widths_add_up
        ; Alcotest.test_case "a grid is its rectangle" `Quick grid_fits_its_rectangle
        ; Alcotest.test_case "a card is its rectangle" `Quick card_fills_its_rectangle
        ; Alcotest.test_case "the Dashboard's cards fit" `Quick overview_cards_fit
        ] )
    ; ( "keeper roster"
      , [ Alcotest.test_case "columns fit the inner width" `Quick keeper_columns_fit ] )
    ]
