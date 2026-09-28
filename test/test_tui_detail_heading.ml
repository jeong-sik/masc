(* The headings that name one record: what comes before its id, the id, the
   readings about it, and the tail -- the clock where the screen draws one,
   and the connection badge.

   The id was drawn whole and the badge took what was left, so at eighty
   columns a 54-cell run id left the badge four cells ("HTT…"). Then the badge
   was kept and the id took what was left, which on a keeper's calls left the
   name -- the screen's subject -- no room at all while the readings after it
   were drawn whole and ran the row past the frame. The order now: the tail
   whole, the lead whole, the id down to a floor, the readings, then the id's
   remaining cells. *)

let run_id = "exact-board-attention-d3104cd8683ae948b6ee1721639adf20"
let sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
let fusion_id = "kmsg-0c9d3e7a41f25b86d0e4a19c7f3b2d58"

(* A lane candidate's runtime label: the lane and the runtime it names, 50
   cells. *)
let runtime_label = "board_attention_exact / ollama-cloud-deepseek-v4-1"

let keeper_name = "kidsnote-slack-context-collector"
let task_id = "task-39712-detail-heading-review"
let clock = "11:06:32"

(* What render_keeper_calls puts after the name for a page it has read: the
   count, then the log's health and the age of its latest entry, which the
   server sends whenever it has a latest timestamp
   (lib/dashboard_tool_source_freshness.ml). *)
let calls_reading = " \xe2\x96\xb8 calls (12)  ok \xc2\xb7 latest 12s ago"

(* What render_changes_list puts after the name: how many changes, over which
   window, out of how many calls. *)
let changes_reading = " (12 in 24h of 340 calls)"

let plain = Masc_tui_theme.strip_sgr
let cells text = Masc_tui_message_layout.display_width (plain text)
let inner cols = Masc_tui_ansi.framed_inner_width cols
let cut_mark = Masc_tui_message_layout.cut_mark

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

(* A screen's title before the id, as the renderer builds it. *)
let titled title = Masc_tui_ansi.Lead_text (Masc_tui_ansi.screen_title title ^ "  ")

let lead_text = function
  | Masc_tui_ansi.Lead_text text -> text
  | Masc_tui_ansi.Lead_strip _ -> invalid_arg "lead_text: a strip"

let heading ~cols ~lead ~id ~after ~tail =
  Masc_tui_ansi.detail_heading ~cols ~lead ~id ~after ~tail

let first n id = String.sub id 0 n
let last n id = String.sub id (String.length id - n) n

(* How a part is drawn at one width. A folded id keeps [head] cells of its
   opening and [tail] of its end around the cut mark: [fit_middle] gives the
   opening a third of what is left after the mark. A cut part keeps [kept]
   cells of its start before the mark. *)
type id_drawn =
  | Whole
  | Folded of { head : int; tail : int }
  | Left_out

type part_drawn =
  | Part_whole
  | Part_cut of { kept : int }
  | Part_dropped

let expected_id id = function
  | Whole -> id
  | Folded { head; tail } -> first head id ^ cut_mark ^ last tail id
  | Left_out -> ""

let expected_part text = function
  | Part_whole -> plain text
  | Part_cut { kept } -> first kept (plain text) ^ cut_mark
  | Part_dropped -> ""

(* The whole row, spelled out: nothing of it is left to the frame's cut. *)
let check_heading ~where ~cols ~lead ~id ~after ~tail ?(lead_drawn = Part_whole)
    ~id_drawn ~after_drawn () =
  let drawn = heading ~cols ~lead:(Masc_tui_ansi.Lead_text lead) ~id ~after ~tail in
  Alcotest.(check string) (where ^ ": the row")
    (expected_part lead lead_drawn
    ^ expected_id id id_drawn
    ^ expected_part after after_drawn
    ^ "  " ^ plain tail)
    (plain drawn);
  Alcotest.(check bool) (where ^ ": the row fits the frame") true
    (cells drawn <= inner cols)

let connected = badge ~mismatch:false ()

(* The ids with nothing after them. Each width: the frame's inside (the
   terminal less four) less the lead and the tail -- two cells of gap and the
   badge "HTTP [connected]", 16 -- is the id's room. *)

(* Lead 16: the 54-cell id has 22 at 60 columns, 42 at 80, 62 at 100. *)
let test_a_lane_run_heading () =
  List.iter
    (fun (cols, id_drawn) ->
      check_heading
        ~where:(Printf.sprintf "Lane Run, %d columns" cols)
        ~cols ~lead:(lead_text (titled Masc_tui_render_prim.lane_run_detail_title))
        ~id:run_id ~after:"" ~tail:connected ~id_drawn ~after_drawn:Part_whole ())
    [ (60, Folded { head = 7; tail = 14 })
    ; (80, Folded { head = 13; tail = 28 })
    ; (100, Whole)
    ]

(* Lead 19: the 64-cell sha256 has 19 at 60 columns, 39 at 80, 59 at 100 and
   79 at 120. *)
let test_a_measurement_heading () =
  List.iter
    (fun (cols, id_drawn) ->
      check_heading
        ~where:(Printf.sprintf "Measurement, %d columns" cols)
        ~cols
        ~lead:(lead_text (titled Masc_tui_render_prim.measurement_detail_title))
        ~id:sha256 ~after:"" ~tail:connected ~id_drawn ~after_drawn:Part_whole ())
    [ (60, Folded { head = 6; tail = 12 })
    ; (80, Folded { head = 12; tail = 26 })
    ; (100, Folded { head = 19; tail = 39 })
    ; (120, Whole)
    ]

(* Lead 14: the 37-cell Fusion id (kmsg- and 32 hex digits) has 24 at 60
   columns and 44 at 80. *)
let test_a_fusion_heading () =
  List.iter
    (fun (cols, id_drawn) ->
      check_heading
        ~where:(Printf.sprintf "Fusion, %d columns" cols)
        ~cols ~lead:(lead_text (titled Masc_tui_render_prim.fusion_title))
        ~id:fusion_id ~after:"" ~tail:connected ~id_drawn ~after_drawn:Part_whole ())
    [ (60, Folded { head = 7; tail = 16 }); (80, Whole); (100, Whole) ]

(* Lead 31: a 50-cell runtime label has 7 at 60 columns, 27 at 80, 47 at 100
   and 67 at 120. It used to make a 99-cell row in the 76 an eighty-column
   frame holds, and the badge was the part cut away. *)
let test_a_runtime_detail_heading () =
  List.iter
    (fun (cols, id_drawn) ->
      check_heading
        ~where:(Printf.sprintf "Runtime detail, %d columns" cols)
        ~cols
        ~lead:(lead_text (titled Masc_tui_render_prim.runtime_detail_title))
        ~id:runtime_label ~after:"" ~tail:connected ~id_drawn
        ~after_drawn:Part_whole ())
    [ (60, Folded { head = 2; tail = 4 })
    ; (80, Folded { head = 8; tail = 18 })
    ; (100, Folded { head = 15; tail = 31 })
    ; (120, Whole)
    ]

(* The keeper's calls: "Keepers ▸" (11), the name, the reading (34), and the
   clock with the badge (8, two of gap, 16). The name and the reading share
   what is left: 17 at 60 columns, 37 at 80, 57 at 100, 81 at 124.
   - The name takes its floor of 12 first, folded to three cells of its
     opening and eight of its tail.
   - The reading takes what is left after that, cut at its end.
   - Only past the whole reading does the name get more. *)
let test_a_keeper_calls_heading () =
  let tail = clock ^ "  " ^ connected in
  List.iter
    (fun (cols, id_drawn, after_drawn) ->
      check_heading
        ~where:(Printf.sprintf "Keeper calls, %d columns" cols)
        ~cols ~lead:Masc_tui_render_prim.keeper_calls_lead ~id:keeper_name
        ~after:calls_reading ~tail ~id_drawn ~after_drawn ())
    [ (60, Folded { head = 3; tail = 8 }, Part_cut { kept = 4 })
    ; (80, Folded { head = 3; tail = 8 }, Part_cut { kept = 24 })
    ; (100, Folded { head = 7; tail = 15 }, Part_whole)
    ; (124, Whole, Part_whole)
    ]

(* The Changes list: " MASC Changes " (14), the name, the window reading
   (25), and the clock with the badge. The name and the reading share 14 at
   60 columns, 34 at 80 and 54 at 100. *)
let test_a_changes_heading () =
  let tail = clock ^ "  " ^ connected in
  List.iter
    (fun (cols, id_drawn, after_drawn) ->
      check_heading
        ~where:(Printf.sprintf "Changes, %d columns" cols)
        ~cols
        ~lead:(Masc_tui_ansi.screen_title " MASC Changes" ^ " ")
        ~id:keeper_name ~after:changes_reading ~tail ~id_drawn ~after_drawn ())
    [ (60, Folded { head = 3; tail = 8 }, Part_cut { kept = 1 })
    ; (80, Folded { head = 3; tail = 8 }, Part_cut { kept = 21 })
    ; (100, Folded { head = 9; tail = 19 }, Part_whole)
    ]

(* A short name is under the floor and is never folded: "alpha" beside the
   calls reading at 100 columns is the scenario the keyboard suite waits on. *)
let test_a_short_name_is_whole () =
  check_heading ~where:"Keeper calls, alpha, 100 columns" ~cols:100
    ~lead:Masc_tui_render_prim.keeper_calls_lead ~id:"alpha"
    ~after:calls_reading ~tail:(clock ^ "  " ^ connected) ~id_drawn:Whole
    ~after_drawn:Part_whole ()

(* The workspace mismatch is the reading the badge exists to carry, and it
   makes the badge 37 cells. With the calls reading after the name at sixty
   columns, the name, the reading and part of the lead give way and the badge
   is whole (#39712 review). *)
let test_a_mismatch_badge_is_whole_beside_readings () =
  let tail = clock ^ "  " ^ badge ~mismatch:true () in
  (* 11 of lead, 49 of tail: the lead keeps 6 cells and the mark. *)
  check_heading ~where:"Keeper calls, workspace mismatch, 60 columns" ~cols:60
    ~lead:Masc_tui_render_prim.keeper_calls_lead ~id:keeper_name
    ~after:calls_reading ~tail ~lead_drawn:(Part_cut { kept = 6 })
    ~id_drawn:Left_out ~after_drawn:Part_dropped ();
  (* At eighty the name keeps its floor and the reading is cut. *)
  check_heading ~where:"Keeper calls, workspace mismatch, 80 columns" ~cols:80
    ~lead:Masc_tui_render_prim.keeper_calls_lead ~id:keeper_name
    ~after:calls_reading ~tail ~id_drawn:(Folded { head = 3; tail = 8 })
    ~after_drawn:(Part_cut { kept = 3 }) ()

(* When the tail and the lead cannot stand side by side the lead is cut at
   its end: sixty columns, Lane Run, workspace mismatch, the badge growing
   with the connection's word. The id's room is what the lead's 16 and the
   tail leave, and below none the lead gives up the difference. *)
let test_the_lead_gives_way_to_the_badge () =
  let lead = lead_text (titled Masc_tui_render_prim.lane_run_detail_title) in
  List.iter
    (fun (status, id_drawn, lead_drawn) ->
      let tail = badge ~status ~mismatch:true () in
      check_heading
        ~where:(Printf.sprintf "%s at 60 columns" (plain tail))
        ~cols:60 ~lead ~id:run_id ~after:"" ~tail ~lead_drawn ~id_drawn
        ~after_drawn:Part_whole ())
    Masc_tui_types.
      [ (* badge 37: one cell left, the mark alone *)
        (Connected, Folded { head = 0; tail = 0 }, Part_whole)
        (* badge 38: none left *)
      ; (Connecting, Left_out, Part_whole)
        (* badge 41, 42, 45: the lead keeps 12, 11, 8 cells and the mark *)
      ; (Reconnecting, Left_out, Part_cut { kept = 12 })
      ; (Disconnected, Left_out, Part_cut { kept = 11 })
      ; (Booting, Left_out, Part_cut { kept = 8 })
      ]

(* One verdict's heading: " MASC Planning" and its gap (16), the strip, the
   verdict mark (12), the 32-cell task id, the badge. The strip needs 18 to
   hold "▸Task Verdicts" and the mark for the two entries before it, so the
   lead's floor is 46 and the id's room 12 at 80 columns, 32 at 100. At 60
   the lead and the badge cannot stand side by side; the lead keeps the strip
   and gives up the end of the verdict mark (#39712 review). *)
let test_a_verdict_heading () =
  let st = state ~mismatch:false ~status:Masc_tui_types.Connected in
  List.iter
    (fun (cols, id_drawn) ->
      let where = Printf.sprintf "Verdict, %d columns" cols in
      let drawn =
        plain
          (Masc_tui_render_prim.harness_detail_heading st ~cols ~task_id
             ~tail:connected)
      in
      Alcotest.(check bool) (where ^ ": the row fits the frame") true
        (Masc_tui_message_layout.display_width drawn <= inner cols);
      Alcotest.(check bool) (where ^ ": the badge is whole, last") true
        (String.ends_with ~suffix:("  " ^ plain connected) drawn);
      Alcotest.(check bool) (where ^ ": the strip keeps its current entry") true
        (holds (Masc_tui_theme.Glyph.current_entry ^ "Task Verdicts") drawn);
      match id_drawn with
      | Left_out ->
          Alcotest.(check bool) (where ^ ": the id gives way to the strip")
            false (holds (first 4 task_id) drawn)
      | Whole | Folded _ ->
          Alcotest.(check bool) (where ^ ": the task id") true
            (holds (expected_id task_id id_drawn) drawn))
    [ (60, Left_out); (80, Folded { head = 3; tail = 8 }); (100, Whole) ]

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
        ; Alcotest.test_case "a changes heading" `Quick test_a_changes_heading
        ; Alcotest.test_case "a short name is whole" `Quick
            test_a_short_name_is_whole
        ; Alcotest.test_case "a mismatch badge is whole beside readings" `Quick
            test_a_mismatch_badge_is_whole_beside_readings
        ; Alcotest.test_case "the lead gives way to the badge" `Quick
            test_the_lead_gives_way_to_the_badge
        ; Alcotest.test_case "a verdict heading" `Quick test_a_verdict_heading
        ] )
    ]
