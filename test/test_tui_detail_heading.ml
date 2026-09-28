(* The headings that name one record: what comes before its id, the id, what
   comes after, and the connection badge last.

   The id was drawn whole and the badge took what was left, so at eighty
   columns a 54-cell run id left the badge four cells ("HTT…"), and a 64-cell
   sha256 left it one cell or none below 90 columns. The badge is the part of
   a heading that has to survive, so the heading never shortens it and the id
   gives way: folded in the middle, keeping the opening a lane's ids share and
   the hex tail that tells two of them apart. *)

let run_id = "exact-board-attention-d3104cd8683ae948b6ee1721639adf20"
let sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
let fusion_id = "kmsg-0c9d3e7a41f25b86d0e4a19c7f3b2d58"

(* A lane candidate's runtime label: the lane and the runtime it names, 50
   cells. *)
let runtime_label = "board_attention_exact / ollama-cloud-deepseek-v4-1"

let keeper_name = "kidsnote-slack-context-collector"

let plain = Masc_tui_theme.strip_sgr
let cells text = Masc_tui_message_layout.display_width (plain text)
let inner cols = Masc_tui_ansi.framed_inner_width cols

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

(* A screen's heading before the id, as the renderer builds it. *)
let titled title = Masc_tui_ansi.screen_title title ^ "  "

let heading ~cols ~lead ~id ~after ~badge =
  Masc_tui_ansi.detail_heading ~cols ~lead ~id ~after ~badge

(* What the frame draws: [box_line] fits the row to the frame's inside,
   keeping its start and marking a cut at its end. *)
let framed ~cols drawn = plain (Masc_tui_message_layout.fit_width drawn (inner cols))

(* How the id is drawn at one width. A fold keeps [head] cells of the id's
   opening and [tail] of its end around the cut mark: [fit_middle] gives the
   opening a third of what is left after the mark. *)
type id_drawn =
  | Whole
  | Folded of { head : int; tail : int }
  | Left_out

let first n id = String.sub id 0 n
let last n id = String.sub id (String.length id - n) n

let check_heading ~where ~cols ~lead ~id ~after ~badge expected =
  let drawn = heading ~cols ~lead ~id ~after ~badge in
  let text = plain drawn in
  Alcotest.(check bool)
    (where ^ ": the heading fits the frame, so nothing of it is cut")
    true
    (cells drawn <= inner cols);
  Alcotest.(check bool)
    (where ^ ": what follows the id and the badge are drawn whole, last")
    true
    (String.ends_with ~suffix:(plain after ^ "  " ^ plain badge) text);
  match expected with
  | Whole -> Alcotest.(check bool) (where ^ ": the id is whole") true (holds id text)
  | Folded { head; tail } ->
      Alcotest.(check bool)
        (where
        ^ Printf.sprintf ": the id keeps %d cells of its opening and %d of its tail"
            head tail)
        true
        (holds (first head id ^ Masc_tui_message_layout.cut_mark ^ last tail id) text)
  | Left_out ->
      Alcotest.(check string) (where ^ ": the id is left out")
        (plain lead ^ plain after ^ "  " ^ plain badge)
        text

let check_widths ~name ~lead ~id ~after widths =
  let badge = badge ~mismatch:false () in
  List.iter
    (fun (cols, expected) ->
      check_heading
        ~where:(Printf.sprintf "%s, %d columns" name cols)
        ~cols ~lead ~id ~after ~badge expected)
    widths

(* Each width below: the frame's inside (the terminal less four), less the
   lead and what follows, less the badge "HTTP [connected]" (16) and its two
   cells of gap, is the id's room; a fold keeps a third of the room less the
   mark at the opening. *)

(* Lead 16 (title 14, gap 2): the 54-cell id has 22 at 60 columns, 42 at 80,
   62 at 100. *)
let test_a_lane_run_heading () =
  check_widths ~name:"Lane Run"
    ~lead:(titled Masc_tui_render_prim.lane_run_detail_title)
    ~id:run_id ~after:""
    [ (60, Folded { head = 7; tail = 14 })
    ; (80, Folded { head = 13; tail = 28 })
    ; (100, Whole)
    ]

(* Lead 19: the 64-cell sha256 has 19 at 60 columns, 39 at 80, 59 at 100 and
   79 at 120. *)
let test_a_measurement_heading () =
  check_widths ~name:"Measurement"
    ~lead:(titled Masc_tui_render_prim.measurement_detail_title)
    ~id:sha256 ~after:""
    [ (60, Folded { head = 6; tail = 12 })
    ; (80, Folded { head = 12; tail = 26 })
    ; (100, Folded { head = 19; tail = 39 })
    ; (120, Whole)
    ]

(* Lead 14: the 37-cell Fusion id (kmsg- and 32 hex digits) has 24 at 60
   columns and 44 at 80. *)
let test_a_fusion_heading () =
  check_widths ~name:"Fusion"
    ~lead:(titled Masc_tui_render_prim.fusion_title)
    ~id:fusion_id ~after:""
    [ (60, Folded { head = 7; tail = 16 }); (80, Whole); (100, Whole) ]

(* Lead 31: a 50-cell runtime label has 7 at 60 columns, 27 at 80, 47 at 100
   and 67 at 120. It used to make a 99-cell row in the 76 an eighty-column
   frame holds, and the badge was the part cut away. *)
let test_a_runtime_detail_heading () =
  check_widths ~name:"Runtime detail"
    ~lead:(titled Masc_tui_render_prim.runtime_detail_title)
    ~id:runtime_label ~after:""
    [ (60, Folded { head = 2; tail = 4 })
    ; (80, Folded { head = 8; tail = 18 })
    ; (100, Folded { head = 15; tail = 31 })
    ; (120, Whole)
    ]

(* The keeper's calls put the name between two parts: what it is ("Keepers ▸",
   11 cells) and what is read of it ("▸ calls (12)" and the clock, 27). The
   32-cell name has none at 60 columns, 20 at 80 and 40 at 100; the parts
   around it keep theirs. *)
let test_a_keeper_calls_heading () =
  check_widths ~name:"Keeper calls"
    ~lead:Masc_tui_render_prim.keeper_calls_lead ~id:keeper_name
    ~after:" \xe2\x96\xb8 calls (12)  ok  11:06:32"
    [ (60, Left_out); (80, Folded { head = 6; tail = 13 }); (100, Whole) ]

(* The workspace mismatch is the reading the badge exists to carry, and it
   makes the badge 37 cells. At eighty columns the id still has 21 cells and
   keeps both ends. *)
let test_a_mismatched_workspace_keeps_its_badge () =
  check_heading ~where:"Lane Run, workspace mismatch, 80 columns" ~cols:80
    ~lead:(titled Masc_tui_render_prim.lane_run_detail_title)
    ~id:run_id ~after:"" ~badge:(badge ~mismatch:true ())
    (Folded { head = 6; tail = 14 })

(* At sixty columns the title, the gaps and that badge leave the id exactly
   one cell: only the cut mark says an id was there, and the badge is whole. *)
let test_one_cell_left_is_the_mark_alone () =
  let title = Masc_tui_render_prim.lane_run_detail_title in
  let badge = badge ~mismatch:true () in
  let drawn =
    plain (heading ~cols:60 ~lead:(titled title) ~id:run_id ~after:"" ~badge)
  in
  Alcotest.(check string) "title, the mark between two gaps, the badge"
    (title ^ "  " ^ Masc_tui_message_layout.cut_mark ^ "  " ^ plain badge)
    drawn;
  Alcotest.(check int) "the row fills the frame" (inner 60) (cells drawn)

(* With no cell left the id is left out: the title, the two gaps with nothing
   between them, and the badge from its start. If that row is still wider
   than the frame, the frame keeps the badge's start -- the connection
   reading -- and cuts its end, which is the workspace mismatch after it.
   Sixty columns, Lane Run, workspace mismatch; the badge grows with the
   connection's word, and the id's room with it:
   - loading...        badge 38, room 0: the row is the frame's 56 exactly
                       and the badge is whole;
   - refreshing...     badge 41, room -3: the row is three past the frame;
   - refresh failed    badge 42, room -4;
   - server booting... badge 45, room -7. *)
type badge_drawn =
  | Badge_whole
  | Badge_cut

let test_no_cell_left_leaves_the_id_out () =
  let cols = 60 in
  let title = Masc_tui_render_prim.lane_run_detail_title in
  List.iter
    (fun (status, room, expected) ->
      let whole_badge = badge ~status ~mismatch:true () in
      let connection = badge ~status ~mismatch:false () in
      let where = Printf.sprintf "%s at %d columns" (plain connection) cols in
      Alcotest.(check int) (where ^ ": the id's room")
        room
        (inner cols - cells (titled title) - 2 - cells whole_badge);
      let drawn =
        framed ~cols
          (heading ~cols ~lead:(titled title) ~id:run_id ~after:""
             ~badge:whole_badge)
      in
      Alcotest.(check bool)
        (where ^ ": the id is left out and the connection reading follows")
        true
        (String.starts_with ~prefix:(title ^ "    " ^ plain connection) drawn);
      Alcotest.(check bool) (where ^ ": nothing of the id is drawn") false
        (holds (first 4 run_id) drawn || holds (last 4 run_id) drawn);
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
      [ (Connecting, 0, Badge_whole)
      ; (Reconnecting, -3, Badge_cut)
      ; (Disconnected, -4, Badge_cut)
      ; (Booting, -7, Badge_cut)
      ]

let () =
  Alcotest.run "tui_detail_heading"
    [ ( "detail heading"
      , [ Alcotest.test_case "a lane run heading" `Quick test_a_lane_run_heading
        ; Alcotest.test_case "a measurement heading" `Quick
            test_a_measurement_heading
        ; Alcotest.test_case "a fusion heading" `Quick test_a_fusion_heading
        ; Alcotest.test_case "a runtime detail heading" `Quick
            test_a_runtime_detail_heading
        ; Alcotest.test_case "a keeper calls heading" `Quick
            test_a_keeper_calls_heading
        ; Alcotest.test_case "a mismatched workspace keeps its badge" `Quick
            test_a_mismatched_workspace_keeps_its_badge
        ; Alcotest.test_case "one cell left is the mark alone" `Quick
            test_one_cell_left_is_the_mark_alone
        ; Alcotest.test_case "no cell left leaves the id out" `Quick
            test_no_cell_left_leaves_the_id_out
        ] )
    ]
