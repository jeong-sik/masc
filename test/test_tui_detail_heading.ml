(* The heading of a lane run's detail, a measurement's and a Fusion run's:
   the screen's title, the record's id and the connection badge.

   The id was drawn whole and the badge took what was left, so at eighty
   columns a 54-cell run id left the badge four cells ("HTT…"), and a 64-cell
   sha256 left it one cell or none below 90 columns. The badge is the part of
   a heading that has to survive, so it is now never shortened by the heading
   and the id gives way: folded in the middle, keeping the opening a lane's
   ids share and the hex tail that tells two of them apart. *)

(* The source this suite stands over. scripts/ci/run-edited-tests.sh runs a
   suite that names a changed path in a double-quoted literal; the heading is
   laid out there, and the Lane Run PTY scenario leaves that module off its
   own list because 29 stanzas link it. *)
let source_modules = [ "bin/masc_tui_render_prim.ml" ]

let run_id = "exact-board-attention-d3104cd8683ae948b6ee1721639adf20"
let sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
let fusion_id = "kmsg-0c9d3e7a41f25b86d0e4a19c7f3b2d58"

let plain = Masc_tui_theme.strip_sgr
let cells text = Masc_tui_message_layout.display_width (plain text)

let holds needle text =
  let n = String.length needle and h = String.length text in
  let rec at i = i + n <= h && (String.sub text i n = needle || at (i + 1)) in
  at 0

let state ~mismatch ~status =
  let state =
    Masc_tui_types.create_state ~workspace:"test" ~port:8935
      ~refresh_interval:2.0 ()
  in
  state.Masc_tui_types.connection_status <- status;
  if mismatch then
    state.Masc_tui_types.workspace_identity <-
      Masc_tui_types.Workspace_identity_mismatch
        { local_base_path = "/a"; server_base_path = "/b" };
  state

let badge ?(status = Masc_tui_types.Connected) ~mismatch () =
  Masc_tui_render_prim.connection_badge (state ~mismatch ~status)

let heading ~cols ~title ~id ~badge =
  Masc_tui_render_prim.detail_heading ~cols ~title ~id ~badge

(* What the frame draws: [box_line] fits the row to the frame's inside,
   keeping its start and marking a cut at its end. *)
let framed ~cols drawn =
  plain
    (Masc_tui_message_layout.fit_width drawn
       (Masc_tui_ansi.framed_inner_width cols))

type id_drawn =
  | Whole
  | Folded

(* What a folded id keeps of each end at the narrowest fold swept here:
   [fit_middle] gives a third of the room to the opening and the rest to the
   tail, and a Measurement heading at sixty columns leaves the id 19 cells,
   six of opening and twelve of tail. *)
let opening_cells = 4
let tail_cells = 8

let opening id = String.sub id 0 opening_cells
let tail id = String.sub id (String.length id - tail_cells) tail_cells

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
      Alcotest.(check bool) (where ^ ": the opening stays") true
        (holds (opening id) text);
      Alcotest.(check bool)
        (where ^ ": the distinguishing tail stays")
        true
        (holds (tail id) text)

let check_widths ~title ~name ~id widths =
  let badge = badge ~mismatch:false () in
  List.iter
    (fun (cols, expected) ->
      check_heading
        ~where:(Printf.sprintf "%s, %d columns" name cols)
        ~cols ~title ~id ~badge expected)
    widths

(* Title 14 cells and two of gap, badge 16 and two of gap: the 54-cell id
   needs a frame of 88 inside, so it is folded at 60 and 80 columns and whole
   at 100. *)
let test_a_lane_run_heading () =
  check_widths ~title:Masc_tui_render_prim.lane_run_detail_title
    ~name:"Lane Run" ~id:run_id
    [ (60, Folded); (80, Folded); (100, Whole) ]

(* Title 17 cells: the 64-cell sha256 needs 101 inside, so it is folded up to
   100 columns and whole at 120. *)
let test_a_measurement_heading () =
  check_widths ~title:Masc_tui_render_prim.measurement_detail_title
    ~name:"Measurement" ~id:sha256
    [ (60, Folded); (80, Folded); (100, Folded); (120, Whole) ]

(* Title 12 cells: the 37-cell Fusion id (kmsg- and 32 hex digits) needs 69
   inside, so it is folded at 60 columns and whole from 80. *)
let test_a_fusion_heading () =
  check_widths ~title:Masc_tui_render_prim.fusion_detail_title ~name:"Fusion"
    ~id:fusion_id
    [ (60, Folded); (80, Whole); (100, Whole) ]

(* The workspace mismatch is the reading the badge exists to carry, and it
   makes the badge 37 cells. At eighty columns the id still keeps both ends. *)
let test_a_mismatched_workspace_keeps_its_badge () =
  check_heading ~where:"Lane Run, workspace mismatch, 80 columns" ~cols:80
    ~title:Masc_tui_render_prim.lane_run_detail_title ~id:run_id
    ~badge:(badge ~mismatch:true ())
    Folded

(* At sixty columns the title, the gaps and that badge leave the id exactly
   one cell: only the cut mark says an id was there, and the badge is whole. *)
let test_one_cell_left_is_the_mark_alone () =
  let title = Masc_tui_render_prim.lane_run_detail_title in
  let badge = badge ~mismatch:true () in
  let drawn = plain (heading ~cols:60 ~title ~id:run_id ~badge) in
  Alcotest.(check string) "title, the mark between two gaps, the badge"
    (plain title ^ "  " ^ Masc_tui_message_layout.cut_mark ^ "  " ^ plain badge)
    drawn;
  Alcotest.(check int) "the row fills the frame" 56 (cells drawn)

(* With no cell left the id is left out: the title, the two gaps with nothing
   between them, and the badge from its start. If that row is still wider
   than the frame, the frame keeps the badge's start -- the connection
   reading -- and cuts its end, which is the workspace mismatch after it.
   Sixty columns, Lane Run, workspace mismatch; the badge grows with the
   connection's word:
   - loading...        38 cells, nothing left for the id, the row is 56 and
                       fits exactly;
   - refreshing...     41, three short;
   - refresh failed    42, four short;
   - server booting... 45, seven short. *)
type badge_drawn =
  | Badge_whole
  | Badge_cut

let test_no_cell_left_leaves_the_id_out () =
  let cols = 60 in
  let title = Masc_tui_render_prim.lane_run_detail_title in
  List.iter
    (fun (status, word, expected) ->
      let where = Printf.sprintf "%s at %d columns" word cols in
      let whole_badge = badge ~status ~mismatch:true () in
      let connection = badge ~status ~mismatch:false () in
      let drawn =
        framed ~cols (heading ~cols ~title ~id:run_id ~badge:whole_badge)
      in
      Alcotest.(check bool)
        (where ^ ": the id is left out and the connection reading follows")
        true
        (String.starts_with
           ~prefix:(plain title ^ "    " ^ plain connection)
           drawn);
      Alcotest.(check bool) (where ^ ": nothing of the id is drawn") false
        (holds (opening run_id) drawn || holds (tail run_id) drawn);
      match expected with
      | Badge_whole ->
          Alcotest.(check bool) (where ^ ": the badge is whole") true
            (String.ends_with ~suffix:(plain whole_badge) drawn)
      | Badge_cut ->
          Alcotest.(check bool) (where ^ ": the frame cut the badge's end")
            true
            (String.ends_with ~suffix:Masc_tui_message_layout.cut_mark drawn
            && not (holds (plain whole_badge) drawn)))
    Masc_tui_types.
      [ (Connecting, "loading...", Badge_whole)
      ; (Reconnecting, "refreshing...", Badge_cut)
      ; (Disconnected, "refresh failed", Badge_cut)
      ; (Booting, "server booting...", Badge_cut)
      ]

let () =
  Alcotest.run "tui_detail_heading"
    [ ( "detail heading"
      , [ Alcotest.test_case "a lane run heading" `Quick test_a_lane_run_heading
        ; Alcotest.test_case "a measurement heading" `Quick
            test_a_measurement_heading
        ; Alcotest.test_case "a fusion heading" `Quick test_a_fusion_heading
        ; Alcotest.test_case "a mismatched workspace keeps its badge" `Quick
            test_a_mismatched_workspace_keeps_its_badge
        ; Alcotest.test_case "one cell left is the mark alone" `Quick
            test_one_cell_left_is_the_mark_alone
        ; Alcotest.test_case "no cell left leaves the id out" `Quick
            test_no_cell_left_leaves_the_id_out
        ] )
    ]
