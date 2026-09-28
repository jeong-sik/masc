(* The heading of a lane run's detail and of a measurement's: the screen's
   title, the record's id and the connection badge.

   The id was drawn whole and the badge took what was left, so at eighty
   columns a 54-cell run id left the badge four cells ("HTT…"), and a 64-cell
   sha256 left it one cell or none below 90 columns. The badge is the part of a heading
   that has to survive, so it is now drawn whole and the id gives way: folded
   in the middle, keeping the opening a lane's ids share and the hex tail that
   tells two of them apart. *)

let run_id = "exact-board-attention-d3104cd8683ae948b6ee1721639adf20"
let sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

let plain = Masc_tui_theme.strip_sgr
let cells text = Masc_tui_message_layout.display_width (plain text)

let holds needle text =
  let n = String.length needle and h = String.length text in
  let rec at i = i + n <= h && (String.sub text i n = needle || at (i + 1)) in
  at 0

let state ~mismatch =
  let state =
    Masc_tui_types.create_state ~workspace:"test" ~port:8935
      ~refresh_interval:2.0 ()
  in
  state.Masc_tui_types.connection_status <- Masc_tui_types.Connected;
  if mismatch then
    state.Masc_tui_types.workspace_identity <-
      Masc_tui_types.Workspace_identity_mismatch
        { local_base_path = "/a"; server_base_path = "/b" };
  state

let heading ~cols ~title ~id ~badge =
  Masc_tui_render_prim.detail_heading ~cols ~title ~id ~badge

type id_drawn =
  | Whole
  | Folded

(* What a folded id keeps of each end at the narrowest fold swept here:
   [fit_middle] gives a third of the room to the opening and the rest to the
   tail, and a Measurement heading at sixty columns leaves the id 19 cells,
   six of opening and twelve of tail. *)
let opening_cells = 4
let tail_cells = 8

let check_heading ~where ~cols ~title ~id ~badge expected =
  let drawn = heading ~cols ~title ~id ~badge in
  let inner = Masc_tui_ansi.framed_inner_width cols in
  Alcotest.(check bool)
    (where ^ ": the heading fits the frame, so nothing of it is cut")
    true
    (cells drawn <= inner);
  Alcotest.(check bool)
    (where ^ ": the badge is drawn whole, last")
    true
    (String.ends_with ~suffix:(plain badge) (plain drawn));
  match expected with
  | Whole ->
      Alcotest.(check bool) (where ^ ": the id is whole") true
        (holds id (plain drawn))
  | Folded ->
      let text = plain drawn in
      Alcotest.(check bool) (where ^ ": the id is folded") false (holds id text);
      Alcotest.(check bool)
        (where ^ ": the fold is marked")
        true
        (holds Masc_tui_message_layout.cut_mark text);
      Alcotest.(check bool)
        (where ^ ": the opening stays")
        true
        (holds (String.sub id 0 opening_cells) text);
      Alcotest.(check bool)
        (where ^ ": the distinguishing tail stays")
        true
        (holds
           (String.sub id (String.length id - tail_cells) tail_cells)
           text)

let badge ~mismatch = Masc_tui_render_prim.connection_badge (state ~mismatch)

(* Title 14 cells and two of gap, badge 16 and two of gap: the 54-cell id
   needs a frame of 88 inside, so it is folded at 60 and 80 columns and whole
   at 100. *)
let test_a_lane_run_heading () =
  let title = Masc_tui_render_prim.lane_run_detail_title in
  let badge = badge ~mismatch:false in
  List.iter
    (fun (cols, expected) ->
      check_heading
        ~where:(Printf.sprintf "Lane Run, %d columns" cols)
        ~cols ~title ~id:run_id ~badge expected)
    [ (60, Folded); (80, Folded); (100, Whole) ]

(* Title 17 cells: the 64-cell sha256 needs 101 inside, so it is folded up to
   100 columns and whole at 120. *)
let test_a_measurement_heading () =
  let title = Masc_tui_render_prim.measurement_detail_title in
  let badge = badge ~mismatch:false in
  List.iter
    (fun (cols, expected) ->
      check_heading
        ~where:(Printf.sprintf "Measurement, %d columns" cols)
        ~cols ~title ~id:sha256 ~badge expected)
    [ (60, Folded); (80, Folded); (100, Folded); (120, Whole) ]

(* The workspace mismatch is the reading the badge exists to carry, and it
   makes the badge 37 cells. At eighty columns the id still keeps both ends. *)
let test_a_mismatched_workspace_keeps_its_badge () =
  let title = Masc_tui_render_prim.lane_run_detail_title in
  let badge = badge ~mismatch:true in
  check_heading ~where:"Lane Run, workspace mismatch, 80 columns" ~cols:80
    ~title ~id:run_id ~badge Folded;
  (* At sixty the badge leaves the id a single cell: only the mark says one
     was there, and the badge is still whole. *)
  let drawn = heading ~cols:60 ~title ~id:run_id ~badge in
  Alcotest.(check bool) "60 columns: the badge is drawn whole" true
    (String.ends_with ~suffix:(plain badge) (plain drawn)
    && cells drawn <= Masc_tui_ansi.framed_inner_width 60)

let () =
  Alcotest.run "tui_detail_heading"
    [ ( "detail heading"
      , [ Alcotest.test_case "a lane run heading" `Quick test_a_lane_run_heading
        ; Alcotest.test_case "a measurement heading" `Quick
            test_a_measurement_heading
        ; Alcotest.test_case "a mismatched workspace keeps its badge" `Quick
            test_a_mismatched_workspace_keeps_its_badge
        ] )
    ]
