(** What the strip above the composer says, and whether it takes a row at all.

    The rows here are the ones the live workspace was carrying when this was
    written: an [edgar.a.poe] check on cron ["45 8-23 * * *"], the hourly
    board sweeps behind it, and the settled rows that outnumber them 37 to 13
    in the same store.

    Two properties matter more than any one rendering. The first is that
    [rows_taken] and [strip] answer the same question -- the frame draws the
    row that the keypress bound subtracts, or neither does. The second is
    that a status nobody recognised does not reach the strip: the wire is
    strings, and a string that means nothing to us must not mean "due". *)

open Alcotest
module Agenda = Masc_tui_agenda

(* Asia/Seoul, so 02:45Z reads as the 11:45 the operator sees. *)
let seoul t = Unix.gmtime (t +. (9.0 *. 3600.0))

let at_2026_08_26_0300z = 1787713200.0

let row ?(standing = Agenda.Coming) ?(recurrence = "every 3600s") at_iso who what
  : Agenda.scheduled
  =
  { at_iso; standing; who; what; recurrence }
;;

let edgar = row "2026-08-26T02:45:00Z" "keeper:edgar.a.poe" "진행 상황 체크"
let sweep = row "2026-08-26T03:14:04Z" "keeper:quill" "hourly board sweep"

let done_earlier =
  row ~standing:Agenda.Settled "2026-08-26T01:00:00Z" "keeper:orrery" "정기 보드 스윕"
;;

(* [kta_asked_at] and [kta_timeout_sec] as the registry reports them: asked a
   minute before [now], with the five minutes a held call is given before it
   is denied -- so four remain. *)
let asked_at_1155 = 1787713140.0

let ask ?(asked_at = asked_at_1155) ?(timeout_sec = 300.0) asked_by question
  : Agenda.awaiting
  =
  { asked_by; question; asked_at; timeout_sec }
;;

let strip_of ?(now = at_2026_08_26_0300z) ?(cols = 80) t =
  Agenda.strip ~now ~localtime:seoul ~cols t
;;

let contains ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec loop i = i + n <= h && (String.sub haystack i n = needle || loop (i + 1)) in
  n = 0 || loop 0
;;

(* The property the Changes list lost its arrow keys to: a row the drawing
   adds while the bound counts rows without it. Here the two cannot disagree
   for any combination of the strip's two halves. *)
let test_rows_taken_agrees_with_what_is_drawn () =
  List.iter
    (fun (name, scheduled, awaiting) ->
       let t = Agenda.project ~scheduled ~awaiting in
       let drawn = strip_of t <> None in
       check
         bool
         (name ^ ": the row is counted exactly when it is drawn")
         drawn
         (Agenda.rows_taken t > 0))
    [ "nothing at all", [], []
    ; "a wake only", [ edgar ], []
    ; "a question only", [], [ ask "lane-smith" "Execute" ]
    ; "both", [ edgar; sweep ], [ ask "lane-smith" "Execute" ]
    ; "only settled rows", [ done_earlier ], []
    ]
;;

let test_an_empty_agenda_gives_the_row_back () =
  let t = Agenda.project ~scheduled:[ done_earlier ] ~awaiting:[] in
  check int "a store of finished rows takes no row" 0 (Agenda.rows_taken t);
  check bool "and draws nothing" true (strip_of t = None)
;;

(* [scheduled] and [due] are ahead of the operator; everything else has
   happened. A string outside the set is not a due row -- defaulting it onto
   the strip is how an unknown becomes a claim. *)
let test_wire_status_parsing () =
  let coming s = Agenda.standing_of_wire s = Agenda.Coming in
  List.iter
    (fun s -> check bool (s ^ " is still ahead") true (coming s))
    [ "scheduled"; "due" ];
  List.iter
    (fun s -> check bool (s ^ " has happened") false (coming s))
    [ "running"; "succeeded"; "failed"; "cancelled"; "expired" ];
  (match Agenda.standing_of_wire "quantum" with
   | Agenda.Unrecognised text -> check string "kept as itself" "quantum" text
   | Agenda.Coming -> fail "an unknown status reached the strip as due"
   | Agenda.Settled -> fail "an unknown status was folded into settled")
;;

let test_unrecognised_status_stays_off_the_strip () =
  let odd = row ~standing:(Agenda.Unrecognised "quantum") "2026-08-26T02:00:00Z"
              "keeper:ghost" "무엇인지 모를 것"
  in
  let t = Agenda.project ~scheduled:[ odd; edgar ] ~awaiting:[] in
  match strip_of t with
  | None -> fail "the recognised wake should still be drawn"
  | Some s ->
    check bool "the unknown row is not the next wake" false (contains ~needle:"ghost" s.clock);
    check bool "the recognised one is" true (contains ~needle:"edgar" s.clock)
;;

(* Earliest wins among the rows still coming, and a settled row that sorts
   before them all does not. *)
let test_the_earliest_coming_row_wins () =
  let t = Agenda.project ~scheduled:[ sweep; done_earlier; edgar ] ~awaiting:[] in
  match strip_of t with
  | None -> fail "there is a wake to draw"
  | Some s ->
    check bool "the 11:45 check, not the 12:14 sweep" true (contains ~needle:"11:45" s.clock);
    check bool "and not the finished 10:00 row" false (contains ~needle:"orrery" s.clock)
;;

let test_the_clock_is_local () =
  let t = Agenda.project ~scheduled:[ edgar ] ~awaiting:[] in
  match strip_of t with
  | None -> fail "there is a wake to draw"
  | Some s ->
    check bool "02:45Z is 11:45 in Seoul" true (contains ~needle:"11:45" s.clock);
    check bool "the title comes with it" true (contains ~needle:"진행 상황 체크" s.clock);
    check bool "and the kind prefix does not" false (contains ~needle:"keeper:" s.clock)
;;

(* At 23:50 a bare "08:00" reads as ten minutes away. *)
let test_a_later_day_says_so () =
  let tomorrow = row "2026-08-26T23:00:00Z" "keeper:edgar.a.poe" "아침 일정 정리" in
  let t = Agenda.project ~scheduled:[ tomorrow ] ~awaiting:[] in
  match strip_of t with
  | None -> fail "there is a wake to draw"
  | Some s ->
    check bool "08:00 the next morning" true (contains ~needle:"08:00" s.clock);
    check bool "carries its date" true (contains ~needle:"08/27" s.clock)
;;

let test_waiting_uses_the_badge_shape () =
  let t = Agenda.project ~scheduled:[] ~awaiting:[ ask "lane-smith" "Execute" ] in
  match strip_of t with
  | None -> fail "someone is blocked on the operator"
  | Some s ->
    check string "the strip's own badge shape" "Awaiting you\xc2\xb71" s.waiting;
    check string "with no wake beside it" "" s.clock
;;

(* The two halves share one line, so the clock has to leave room for the
   badge rather than run under it. *)
let test_the_halves_fit_together () =
  let t = Agenda.project ~scheduled:[ edgar ] ~awaiting:[ ask "lane-smith" "Execute" ] in
  List.iter
    (fun cols ->
       match strip_of ~cols t with
       | None -> fail "both halves have something to say"
       | Some s ->
         let width = Masc_tui_message_layout.display_width in
         check
           bool
           (Printf.sprintf "at %d cells the halves still fit" cols)
           true
           (width s.clock + width s.waiting <= cols))
    [ 20; 30; 40; 60; 80; 120 ]
;;


(* The two readers of one body budget.

   [surface_body_rows] takes the strip's row off before either renderer or key
   bound receives the budget. [finish_surface] reads the same agenda projection
   only to draw that row. Subtracting it again in [scrolled_surface] is what
   made key geometry shorter than the frame whenever the strip was present.

   [Ast_grep] rather than a substring, because this file names both
   identifiers in the paragraph above. *)
let calls ~module_path ~binding_name ~callee =
  Ast_grep.count_calls_in_value_binding ~module_path ~binding_name ~callee
;;

(* The third reader, and the one the two above did not cover.

   Each surface also works out how many rows it may draw in. When that sum
   subtracted only the composer, every surface drew one row more than the
   frame would take, and [finish_surface] cuts a too-tall surface from the
   bottom -- so the row that disappeared was the footer, with the key hints,
   the version, the base path and the port on it. It disappeared the moment a
   wake or a waiting keeper put the strip on screen, and on every surface at
   once.

   The number now has one owner. The invariant that keeps it that way is that
   the drawing never reaches for the composer's height itself: a surface that
   wants a body height has to ask [surface_body_rows], which is where the
   strip's rows come off. *)
let test_the_drawing_does_not_measure_the_body_itself () =
  check
    int
    "no render site computes a body height from the composer's rows"
    0
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui_render.ml"
       ~callee:"Composer.rows_for");
  check
    bool
    "they ask the owner instead"
    true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui_render.ml"
       ~callee:"Masc_tui_types.surface_body_rows"
     >= 40);
  check
    int
    "and the owner is the only place the strip's rows come off a height"
    1
    (calls
       ~module_path:"bin/masc_tui_types.ml"
       ~binding_name:"surface_body_rows"
       ~callee:"agenda_chrome_rows")
;;

let test_the_frame_and_the_bound_read_the_same_number () =
  check
    bool
    "the frame subtracts the strip's rows"
    true
    (calls
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"finish_surface"
       ~callee:"Masc_tui_types.agenda_chrome_rows"
     >= 1);
  check int "the surface body subtracts the strip once" 1
    (calls
       ~module_path:"bin/masc_tui_types.ml"
       ~binding_name:"surface_body_rows"
       ~callee:"agenda_chrome_rows");
  check int "the typed scroll layout does not subtract it again" 0
    (calls
       ~module_path:"bin/masc_tui_types.ml"
       ~binding_name:"scrolled_surface"
       ~callee:"agenda_chrome_rows");
  check
    int
    "and that is the same [rows_taken], not a second count"
    1
    (calls
       ~module_path:"bin/masc_tui_types.ml"
       ~binding_name:"agenda_chrome_rows"
       ~callee:"Masc_tui_agenda.rows_taken")
  ; check int "one loop snapshot refreshes terminal geometry" 1
      (calls
         ~module_path:"bin/masc_tui.ml"
         ~binding_name:"run_loop"
         ~callee:"refresh_terminal_size")
  ; check int "ordinary geometry reads share the loop snapshot" 1
      (calls
         ~module_path:"bin/masc_tui_ansi.ml"
         ~binding_name:"get_terminal_size"
         ~callee:"Masc_tui_render_schedule.Terminal_size_cache.get")
  ; check int "a polled resize invalidates the presented frame" 1
      (calls
         ~module_path:"bin/masc_tui.ml"
         ~binding_name:"run_loop"
         ~callee:"Frame_presenter.invalidate")
  ; check int "Tools End uses the exact projected maximum" 1
      (calls
         ~module_path:"bin/masc_tui.ml"
         ~binding_name:"move_surface_to_end"
         ~callee:"Masc_tui_scroll.maximum")
;;

let test_tools_scroll_counts_the_rendered_projection () =
  check int "the key bound counts the renderer's exact rows" 1
    (calls
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"tools_scrolled"
       ~callee:"Render_tools.tools_display_lines");
  check int "the main loop routes Tools to that bound" 1
    (calls
       ~module_path:"bin/masc_tui.ml"
       ~binding_name:"scrolled_surface"
       ~callee:"Masc_tui_render.tools_scrolled")
;;

let test_tools_renderer_reads_the_typed_scroll_layout () =
  check int "the renderer reads the same display projection" 1
    (calls
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"render_tools"
       ~callee:"Render_tools.tools_display_lines");
  check int "the renderer derives geometry from those same rows" 1
    (calls
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"render_tools"
       ~callee:"tools_scrolled_for_lines")
;;

let test_tools_projection_defers_inactive_panes () =
  (* The Tools projection moved to masc_tui_render_tools when the chrome
     became a library; the binding is read in the file that holds it. *)
  check int "only selected typed branches force their projection" 4
    (calls
       ~module_path:"bin/masc_tui_render_tools.ml"
       ~binding_name:"tools_display_lines"
       ~callee:"Lazy.force");
  check int "the async branch remains a direct selected projection" 1
    (calls
       ~module_path:"bin/masc_tui_render_tools.ml"
       ~binding_name:"tools_display_lines"
       ~callee:"async_request_observation_lines")
;;


(* {1 The panel behind [;]} *)

let overlay_of ?(now = at_2026_08_26_0300z) ?(cols = 78) t =
  Agenda.overlay ~now ~localtime:seoul ~cols t
;;

let texts lines = List.map (fun (l : Agenda.line) -> l.Agenda.text) lines

let joined lines = String.concat "\n" (texts lines)

let tones_of lines tone =
  List.filter (fun (l : Agenda.line) -> l.Agenda.tone = tone) lines
;;

(* The strip names one wake because it has one line. The panel was opened on
   purpose, so it answers with all of them. *)
let test_the_panel_lists_every_coming_wake () =
  let lines = overlay_of (Agenda.project ~scheduled:[ sweep; edgar ] ~awaiting:[]) in
  check int "both wakes are rows" 2 (List.length (tones_of lines Agenda.Wake));
  let text = joined lines in
  check bool "the 11:45 check" true (contains ~needle:"11:45" text);
  check bool "and the 12:14 sweep" true (contains ~needle:"12:14" text)
;;

let test_settled_rows_do_not_reach_the_panel () =
  let lines =
    overlay_of (Agenda.project ~scheduled:[ done_earlier; edgar ] ~awaiting:[])
  in
  check int "one wake, not two" 1 (List.length (tones_of lines Agenda.Wake));
  check
    bool
    "the finished row is not on it"
    false
    (contains ~needle:"orrery" (joined lines))
;;

let test_wakes_are_earliest_first () =
  let lines =
    overlay_of (Agenda.project ~scheduled:[ sweep; edgar ] ~awaiting:[])
  in
  match texts (tones_of lines Agenda.Wake) with
  | first :: _ -> check bool "the earliest leads" true (contains ~needle:"11:45" first)
  | [] -> fail "there are wakes to order"
;;

(* Where the strip draws nothing, the panel says so. The operator pressed a
   key to ask, and a blank panel reads as a failure to load rather than as an
   answer. *)
let test_empty_sections_answer_in_words () =
  let lines = overlay_of (Agenda.project ~scheduled:[] ~awaiting:[]) in
  let text = joined lines in
  check bool "the wake section answers" true (contains ~needle:"nothing is scheduled" text);
  check bool "so does the other" true (contains ~needle:"nobody is waiting" text);
  check int "both headings are still drawn" 2 (List.length (tones_of lines Agenda.Heading))
;;

let test_a_held_call_says_how_long_is_left () =
  let lines =
    overlay_of (Agenda.project ~scheduled:[] ~awaiting:[ ask "lane-smith" "Execute" ])
  in
  let text = joined lines in
  check bool "who is holding it" true (contains ~needle:"lane-smith" text);
  check bool "and what" true (contains ~needle:"Execute" text);
  check bool "and how long is left" true (contains ~needle:"4m 00s left" text)
;;

(* A call whose wait has run out is denied, so the row says that rather than
   counting past zero. *)
let test_an_expired_call_says_so () =
  let lines =
    overlay_of
      (Agenda.project
         ~scheduled:[]
         ~awaiting:[ ask ~timeout_sec:10.0 "lane-smith" "Execute" ])
  in
  check bool "expired" true (contains ~needle:"expired" (joined lines))
;;

(* The rows are laid out before [framed_line] sees them, so they have to be
   laid out against the width it will fit them to -- the right-hand column was
   cut on the way through when they were not. *)
let test_rows_fit_the_width_they_were_given () =
  let t =
    Agenda.project
      ~scheduled:
        [ row ~recurrence:"cron 45 8-23 * * * Asia/Seoul" "2026-08-26T02:45:00Z"
            "keeper:edgar.a.poe" "진행 상황 체크"
        ; row ~recurrence:"daily 20:00:00 Asia/Seoul" "2026-08-26T11:00:00Z"
            "keeper:orrery" "정기 백로그 감사, 목표 진척, agent fitness 점검"
        ]
      ~awaiting:[ ask "lane-smith" "Execute" ]
  in
  List.iter
    (fun cols ->
       List.iter
         (fun (line : Agenda.line) ->
            check
              bool
              (Printf.sprintf "at %d cells: %S" cols line.Agenda.text)
              true
              (Masc_tui_message_layout.display_width line.Agenda.text <= cols))
         (overlay_of ~cols t))
    [ 30; 46; 60; 76; 120 ]
;;

(* [short_who] is public now: the Schedules list needed the same answer, and
   before it called this it drew "keeper:~" -- the seven-cell prefix took the
   name's room and two schedules for two different keepers read alike.

   A target with no prefix, or one whose prefix is a different kind, comes
   back untouched. Stripping up to the first colon would eat the front of any
   name that happens to contain one. *)
let test_the_kind_prefix_comes_off_a_target () =
  check string "the keeper prefix comes off" "edgar.a.poe"
    (Agenda.short_who "keeper:edgar.a.poe");
  check string "a bare name is left alone" "edgar.a.poe"
    (Agenda.short_who "edgar.a.poe");
  check string "another kind is left alone" "board:sweep"
    (Agenda.short_who "board:sweep");
  check string "the prefix alone is not a name to shorten" "keeper:"
    (Agenda.short_who "keeper:")
;;

let () =
  run
    "tui agenda"
    [ ( "the row"
      , [ test_case "rows_taken agrees with what is drawn" `Quick
            test_rows_taken_agrees_with_what_is_drawn
        ; test_case "an empty agenda gives the row back" `Quick
            test_an_empty_agenda_gives_the_row_back
        ] )
    ; ( "what reaches it"
      , [ test_case "wire status parsing" `Quick test_wire_status_parsing
        ; test_case "unrecognised stays off" `Quick
            test_unrecognised_status_stays_off_the_strip
        ; test_case "the earliest coming row wins" `Quick
            test_the_earliest_coming_row_wins
        ] )
    ; ( "the frame and the bound"
      , [ test_case "read the same number" `Quick
            test_the_frame_and_the_bound_read_the_same_number
        ; test_case "the drawing does not measure the body itself" `Quick
            test_the_drawing_does_not_measure_the_body_itself
        ; test_case "Tools scroll counts the rendered projection" `Quick
            test_tools_scroll_counts_the_rendered_projection
        ; test_case "Tools renderer uses the typed scroll layout" `Quick
            test_tools_renderer_reads_the_typed_scroll_layout
        ; test_case "Tools projection defers inactive panes" `Quick
            test_tools_projection_defers_inactive_panes
        ] )
    ; ( "how it reads"
      , [ test_case "the clock is local" `Quick test_the_clock_is_local
        ; test_case "a later day says so" `Quick test_a_later_day_says_so
        ; test_case "waiting uses the badge shape" `Quick
            test_waiting_uses_the_badge_shape
        ; test_case "the halves fit together" `Quick test_the_halves_fit_together
        ] )
    ; ( "the panel"
      , [ test_case "lists every coming wake" `Quick
            test_the_panel_lists_every_coming_wake
        ; test_case "settled rows do not reach it" `Quick
            test_settled_rows_do_not_reach_the_panel
        ; test_case "wakes are earliest first" `Quick test_wakes_are_earliest_first
        ; test_case "empty sections answer in words" `Quick
            test_empty_sections_answer_in_words
        ; test_case "a held call says how long is left" `Quick
            test_a_held_call_says_how_long_is_left
        ; test_case "an expired call says so" `Quick test_an_expired_call_says_so
        ; test_case "rows fit the width they were given" `Quick
            test_rows_fit_the_width_they_were_given
        ; test_case "the kind prefix comes off a target" `Quick
            test_the_kind_prefix_comes_off_a_target
        ] )
    ]
;;
