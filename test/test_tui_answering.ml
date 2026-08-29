open Masc

(* The [@] Answering overlay is the footer badge's "+N" unfolded. These pin
   the projection: who leads, what an error adds, what quiet looks like, how
   a finished turn keeps its ✓ row for a while, and which rows Enter can act
   on — so the overlay's promises hold without a terminal. *)

let row name state : Tui_decode.keeper_turn_row =
  { Tui_decode.ktr_keeper_name = name; ktr_state = state }
;;

let running ?preview ~lane ~started name =
  row name
    (Tui_decode.Keeper_turn_running
       { lane; started_at_unix = started; preview })
;;

let texts lines =
  List.map (fun (line : Masc_tui_answering.line) -> line.Masc_tui_answering.text) lines
;;

let test_running_rows_lead_with_the_chat_target () =
  let lines =
    Masc_tui_answering.overlay ~now:1000.
      ~chat_target:(Some "analyst") ~error:None ~finishes:[]
      [ running ~lane:Tui_decode.Turn_lane_autonomous ~started:866. "echo"
      ; row "delta" Tui_decode.Keeper_turn_idle
      ; running ~lane:Tui_decode.Turn_lane_chat_operation ~started:990.
          "analyst"
      ]
  in
  match texts lines with
  | [ first; second; idle ] ->
      Alcotest.(check bool) "the chat target leads" true
        (String.length first > 0
        && Astring.String.is_infix ~affix:"analyst" first);
      Alcotest.(check bool) "its lane rides the row" true
        (Astring.String.is_infix ~affix:"chat_operation" first);
      Alcotest.(check bool) "elapsed reads in seconds" true
        (Astring.String.is_infix ~affix:"10s" first);
      Alcotest.(check bool) "the other runner follows" true
        (Astring.String.is_infix ~affix:"echo" second);
      Alcotest.(check bool) "minutes carry their seconds" true
        (Astring.String.is_infix ~affix:"2m14s" second);
      Alcotest.(check string) "idle keepers fold into one count" "1 idle" idle
  | other -> Alcotest.failf "expected three lines, got %d" (List.length other)
;;

let test_quiet_fleet_says_so () =
  let lines =
    Masc_tui_answering.overlay ~now:1000. ~chat_target:None ~error:None
      ~finishes:[]
      [ row "echo" Tui_decode.Keeper_turn_idle
      ; row "analyst" Tui_decode.Keeper_turn_idle
      ]
  in
  match texts lines with
  | [ quiet; idle ] ->
      Alcotest.(check string) "an idle fleet is named, not blank"
        "nobody is answering right now" quiet;
      Alcotest.(check string) "the count still rides" "2 idle" idle
  | other -> Alcotest.failf "expected two lines, got %d" (List.length other)
;;

let test_error_keeps_the_last_rows_and_says_why () =
  let lines =
    Masc_tui_answering.overlay ~now:1000. ~chat_target:None
      ~error:(Some "connection refused") ~finishes:[]
      [ running ~lane:Tui_decode.Turn_lane_maintenance ~started:999. "polisher" ]
  in
  match texts lines with
  | [ failed; kept; runner ] ->
      Alcotest.(check bool) "the poll failure is named" true
        (Astring.String.is_infix ~affix:"connection refused" failed);
      Alcotest.(check bool) "and marked as stale, not fresh" true
        (Astring.String.is_infix ~affix:"last rows" kept);
      Alcotest.(check bool) "the last known runner still shows" true
        (Astring.String.is_infix ~affix:"polisher" runner)
  | other -> Alcotest.failf "expected three lines, got %d" (List.length other)
;;

let test_unavailable_reads_as_unknown_not_idle () =
  let lines =
    Masc_tui_answering.overlay ~now:1000. ~chat_target:None ~error:None
      ~finishes:[]
      [ row "delta" (Tui_decode.Keeper_turn_unavailable "owner_not_found") ]
  in
  match lines with
  | [ quiet; unknown ] ->
      Alcotest.(check bool) "no runner still says nobody" true
        (Astring.String.is_infix ~affix:"nobody"
           quiet.Masc_tui_answering.text);
      Alcotest.(check bool) "the lookup failure is spelled out" true
        (Astring.String.is_infix ~affix:"owner_not_found"
           unknown.Masc_tui_answering.text);
      Alcotest.(check bool) "and toned apart from idle" true
        (unknown.Masc_tui_answering.tone = Masc_tui_answering.Unknown)
  | other -> Alcotest.failf "expected two lines, got %d" (List.length other)
;;

let test_finished_turns_glow_then_expire () =
  let finishes = [ ("echo", 990.) ] in
  let fresh =
    Masc_tui_answering.overlay ~now:1000. ~chat_target:None ~error:None
      ~finishes
      [ row "echo" Tui_decode.Keeper_turn_idle ]
  in
  (match fresh with
   | [ done_line; idle ] ->
       Alcotest.(check bool) "a finish inside the TTL keeps a ✓ row" true
         (Astring.String.is_infix ~affix:"echo"
            done_line.Masc_tui_answering.text
         && Astring.String.is_infix ~affix:"answered 10s ago"
              done_line.Masc_tui_answering.text);
       Alcotest.(check bool) "toned as done" true
         (done_line.Masc_tui_answering.tone = Masc_tui_answering.Done);
       Alcotest.(check bool) "and Enter can open it" true
         (done_line.Masc_tui_answering.target = Some "echo");
       Alcotest.(check bool)
         "a fleet with a fresh finish does not read as nobody" true
         (Astring.String.is_infix ~affix:"idle"
            idle.Masc_tui_answering.text)
   | other -> Alcotest.failf "expected two lines, got %d" (List.length other));
  let expired =
    Masc_tui_answering.overlay
      ~now:(990. +. Masc_tui_answering.finish_glow_ttl_seconds +. 1.)
      ~chat_target:None ~error:None ~finishes
      [ row "echo" Tui_decode.Keeper_turn_idle ]
  in
  match texts expired with
  | [ quiet; _idle ] ->
      Alcotest.(check string) "past the TTL the glow is gone"
        "nobody is answering right now" quiet
  | other -> Alcotest.failf "expected two lines, got %d" (List.length other)
;;

let test_advance_finishes_tracks_the_transition () =
  let previous =
    [ running ~lane:Tui_decode.Turn_lane_autonomous ~started:900. "echo"
    ; running ~lane:Tui_decode.Turn_lane_chat_operation ~started:950. "analyst"
    ; row "delta" (Tui_decode.Keeper_turn_unavailable "owner_not_found")
    ]
  in
  let current =
    [ row "echo" Tui_decode.Keeper_turn_idle
    ; running ~lane:Tui_decode.Turn_lane_chat_operation ~started:950. "analyst"
    ; row "delta" Tui_decode.Keeper_turn_idle
    ]
  in
  let finishes =
    Masc_tui_answering.advance_finishes ~now:1000. ~previous_rows:previous
      ~current_rows:current []
  in
  Alcotest.(check (list (pair string (float 0.001))))
    "running→idle is a finish; unavailable→idle is not"
    [ ("echo", 1000.) ] finishes;
  (* A keeper that starts running again drops its glow: the badge takes
     over, and one keeper must not read as both answering and answered. *)
  let running_again =
    Masc_tui_answering.advance_finishes ~now:1010.
      ~previous_rows:current
      ~current_rows:
        [ running ~lane:Tui_decode.Turn_lane_autonomous ~started:1005.
            "echo"
        ]
      finishes
  in
  Alcotest.(check (list (pair string (float 0.001))))
    "restarting clears the finish glow" [] running_again
;;

let test_target_indexes_skip_prose () =
  let lines =
    Masc_tui_answering.overlay ~now:1000. ~chat_target:None
      ~error:(Some "boom") ~finishes:[ ("analyst", 995.) ]
      [ running ~lane:Tui_decode.Turn_lane_autonomous ~started:990. "echo"
      ; row "delta" Tui_decode.Keeper_turn_idle
      ]
  in
  (* error(2 lines) → running(1) → finished(1) → idle(1) *)
  Alcotest.(check (list int)) "only actionable rows carry an index" [ 2; 3 ]
    (Masc_tui_answering.target_indexes lines)
;;

(* The mark a running turn wears. Motion is a claim -- "this is changing
   while you look at it" -- so these pin both halves of it: that it does
   move, and that it stops when there is nothing to say. *)
let test_the_running_mark_moves () =
  let frames =
    List.map (fun frame -> Masc_tui_answering.running_glyph ~frame) [ 0; 1; 2; 3 ]
  in
  Alcotest.(check int)
    "four frames, none repeated" 4
    (List.length (List.sort_uniq String.compare frames));
  Alcotest.(check string)
    "it comes back around" (List.nth frames 0)
    (Masc_tui_answering.running_glyph ~frame:4)
;;

(* [-1] is "not animating", which a surface that repaints on the poll has to
   be able to ask for. Freezing on an arbitrary quarter would read as a turn
   stuck at that quarter; the still mark says "running" without claiming to
   be moving. *)
let test_not_animating_falls_back_to_the_still_mark () =
  let still = Masc_tui_answering.running_glyph ~frame:(-1) in
  Alcotest.(check bool)
    "the still mark is not one of the moving frames" false
    (List.exists
       (fun frame -> String.equal still (Masc_tui_answering.running_glyph ~frame))
       [ 0; 1; 2; 3 ])
;;

(* Every mark is one cell wide.

   The Keepers table concatenates the mark ahead of the cells it fits, so the
   mark is the one thing in that row nothing measures. A two-cell frame would
   push every column to its right on one frame in four: a table that jitters
   as it animates.

   Cells, not bytes. Counting bytes looks like the same check and is not --
   U+4E00 is three bytes and two cells, so a byte count would wave through
   exactly the frame this exists to catch. *)
let test_every_frame_is_one_cell () =
  List.iter
    (fun frame ->
      let glyph = Masc_tui_answering.running_glyph ~frame in
      Alcotest.(check int)
        (Printf.sprintf "frame %d occupies one cell" frame)
        1
        (Masc_tui_message_layout.display_width glyph))
    [ -1; 0; 1; 2; 3 ];
  (* The check has teeth: a three-byte two-cell glyph fails it. *)
  Alcotest.(check int)
    "a wide three-byte glyph would not pass" 2
    (Masc_tui_message_layout.display_width "\xe4\xb8\x80")
;;

(* The overlay draws the same mark as the table, so one running turn does not
   wear two different marks depending on which key the reader pressed. *)
let test_the_overlay_wears_the_same_mark () =
  let lines =
    Masc_tui_answering.overlay ~frame:2 ~now:100. ~chat_target:None ~error:None
      ~finishes:[]
      [ running ~lane:Tui_decode.Turn_lane_chat_operation ~started:40. "echo" ]
  in
  let running_line =
    List.find (fun (line : Masc_tui_answering.line) -> line.tone = Masc_tui_answering.Running) lines
  in
  Alcotest.(check bool)
    "the overlay row starts with frame 2's mark" true
    (String.starts_with
       ~prefix:(Masc_tui_answering.running_glyph ~frame:2)
       running_line.text)
;;

(* The span a surface hands over already measured. A Gate row drew
   "41989s waiting" -- five figures of seconds where the code comment beside
   it said the operator weighs the number. These pin the reading an operator
   can weigh, and pin it here so the two callers cannot drift into two
   spellings of the same span. *)
let test_a_long_wait_reads_in_hours () =
  Alcotest.(check string)
    "41989 seconds is eleven hours and thirty-nine minutes" "11h39m"
    (Masc_tui_answering.duration_text 41989.);
  Alcotest.(check string)
    "under a minute stays in seconds" "42s"
    (Masc_tui_answering.duration_text 42.);
  Alcotest.(check string)
    "minutes carry their seconds" "2m14s"
    (Masc_tui_answering.duration_text 134.)
;;

(* Clock skew between the server and this terminal can hand over a negative
   span. Counting up from the future would read as a wait that has not
   started; zero reads as one that just did. *)
let test_a_negative_span_clamps () =
  Alcotest.(check string)
    "a span from the future reads as none" "0s"
    (Masc_tui_answering.duration_text (-5.))
;;

(* [elapsed_text] is the same answer for a caller that knows the start rather
   than the span. One spelling, two ways in. *)
let test_elapsed_and_duration_agree () =
  Alcotest.(check string)
    "start-plus-now and the span read the same"
    (Masc_tui_answering.duration_text 41989.)
    (Masc_tui_answering.elapsed_text ~now:41989. 0.)
;;

let () =
  Alcotest.run "tui_answering"
    [ ( "duration"
      , [ Alcotest.test_case "a long wait reads in hours" `Quick
            test_a_long_wait_reads_in_hours
        ; Alcotest.test_case "a negative span clamps" `Quick
            test_a_negative_span_clamps
        ; Alcotest.test_case "elapsed and duration agree" `Quick
            test_elapsed_and_duration_agree
        ] )
    ; ( "running mark"
      , [ Alcotest.test_case "the mark moves" `Quick
            test_the_running_mark_moves
        ; Alcotest.test_case "not animating falls back to the still mark"
            `Quick test_not_animating_falls_back_to_the_still_mark
        ; Alcotest.test_case "every frame is one cell" `Quick
            test_every_frame_is_one_cell
        ; Alcotest.test_case "the overlay wears the same mark" `Quick
            test_the_overlay_wears_the_same_mark
        ] )
    ; ( "tui-answering"
      , [ Alcotest.test_case "running rows lead with the chat target" `Quick
            test_running_rows_lead_with_the_chat_target
        ; Alcotest.test_case "a quiet fleet says so" `Quick
            test_quiet_fleet_says_so
        ; Alcotest.test_case "an error keeps the last rows and says why"
            `Quick test_error_keeps_the_last_rows_and_says_why
        ; Alcotest.test_case "unavailable reads as unknown, not idle" `Quick
            test_unavailable_reads_as_unknown_not_idle
        ; Alcotest.test_case "finished turns glow then expire" `Quick
            test_finished_turns_glow_then_expire
        ; Alcotest.test_case "advance_finishes tracks the transition" `Quick
            test_advance_finishes_tracks_the_transition
        ; Alcotest.test_case "target indexes skip prose" `Quick
            test_target_indexes_skip_prose
        ] )
    ]
;;
