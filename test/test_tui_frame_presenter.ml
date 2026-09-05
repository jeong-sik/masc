open Alcotest

module Presenter = Masc_tui_frame_presenter

type sink = {
  mutable writes : string list;
  mutable flushes : int;
}

let sink () = { writes = []; flushes = 0 }
let reset_sink sink = sink.writes <- []; sink.flushes <- 0
let write sink output = sink.writes <- output :: sink.writes
let flush sink () = sink.flushes <- sink.flushes + 1

let output sink =
  match List.rev sink.writes with
  | [ output ] -> output
  | outputs -> String.concat "" outputs

let contains text needle =
  let text_length = String.length text in
  let needle_length = String.length needle in
  let rec loop offset =
    if offset + needle_length > text_length then false
    else if String.sub text offset needle_length = needle then true
    else loop (offset + 1)
  in
  needle_length = 0 || loop 0

let frame ?(surface_key = "overview") ?(compact_frame = false)
    ?(cursor = Presenter.Hidden)
    ?(rows = 4) ?(cols = 40) lines : Presenter.frame =
  { surface_key;
    compact_frame;
    terminal_rows = rows;
    terminal_cols = cols;
    cursor;
    lines;
  }

let present_result ?(invalidate_before = false) presenter sink frame =
  Presenter.present presenter ~invalidate_before ~write:(write sink)
    ~flush:(flush sink) frame

let present ?(invalidate_before = false) presenter sink frame =
  ignore
    (present_result ~invalidate_before presenter sink frame
      : Presenter.present_result)

let test_first_frame_and_identical_frame () =
  let presenter = Presenter.create ~synchronized_output:true () in
  let captured = sink () in
  let initial = frame [ "top"; "middle"; "bottom" ] in
  (match present_result presenter captured initial with
   | Presenter.Presented -> ()
   | Presenter.Unchanged -> fail "first frame was reported unchanged");
  check int "first frame writes once" 1 (List.length captured.writes);
  check int "first frame flushes once" 1 captured.flushes;
  let full = output captured in
  check bool "full redraw clears the screen" true (contains full "\027[2J");
  check bool "full redraw starts synchronized output" true
    (contains full "\027[?2026h");
  check bool "full redraw ends synchronized output" true
    (contains full "\027[?2026l");
  check bool "full redraw writes the padded viewport" true
    (contains full "\027[4;1H");
  reset_sink captured;
  (match present_result presenter captured initial with
   | Presenter.Unchanged -> ()
   | Presenter.Presented -> fail "identical frame was reported presented");
  check int "identical frame writes nothing" 0 (List.length captured.writes);
  check int "identical frame does not flush" 0 captured.flushes

let test_input_gate_follows_the_last_presented_frame () =
  let presenter = Presenter.create ~synchronized_output:false () in
  let captured = sink () in
  let same_frame = frame [ "same bytes" ] in
  check bool "input waits for the first frame" true
    (Presenter.last_frame_is_compact presenter);
  present presenter captured same_frame;
  check bool "normal frame exposes its surface" false
    (Presenter.last_frame_is_compact presenter);
  reset_sink captured;
  present presenter captured { same_frame with compact_frame = true };
  check bool "metadata-only compact transition redraws" true
    (contains (output captured) "\027[2J");
  check bool "compact frame hides its surface" true
    (Presenter.last_frame_is_compact presenter);
  reset_sink captured;
  present presenter captured same_frame;
  check bool "metadata-only normal transition redraws" true
    (contains (output captured) "\027[2J");
  check bool "a new normal frame restores surface input" false
    (Presenter.last_frame_is_compact presenter);
  Presenter.invalidate presenter;
  check bool "an invalidated frame is not trusted for input" true
    (Presenter.last_frame_is_compact presenter)

let test_only_changed_row_is_written () =
  let presenter = Presenter.create ~synchronized_output:true () in
  let captured = sink () in
  let stable_rows =
    List.init 12 (fun row -> Printf.sprintf "stable row %02d padding padding" row)
  in
  present presenter captured (frame ~rows:12 stable_rows);
  let full_bytes = String.length (output captured) in
  reset_sink captured;
  let changed =
    List.mapi
      (fun row line -> if row = 6 then "changed row" else line)
      stable_rows
  in
  present presenter captured (frame ~rows:12 changed);
  let diff = output captured in
  check int "changed frame writes once" 1 (List.length captured.writes);
  check int "changed frame flushes once" 1 captured.flushes;
  check bool "changed row uses absolute addressing" true
    (contains diff "\027[7;1H");
  check bool "unchanged row content is omitted" false
    (contains diff "stable row 00");
  check bool "incremental frame does not clear the screen" false
    (contains diff "\027[2J");
  check bool "one-row update writes under one third of a full frame" true
    (String.length diff * 3 < full_bytes)

let test_shorter_content_clears_stale_rows () =
  let presenter = Presenter.create ~synchronized_output:true () in
  let captured = sink () in
  present presenter captured
    (frame [ "header"; "a much longer previous row"; "stale tail" ]);
  reset_sink captured;
  present presenter captured (frame [ "header"; "x" ]);
  let diff = output captured in
  check bool "shortened row is erased before rewrite" true
    (contains diff "\027[2;1H\027[0m\027[2Kx");
  check bool "removed tail row is explicitly cleared" true
    (contains diff "\027[3;1H\027[0m\027[2K\027[0m");
  check bool "old long content is not replayed" false
    (contains diff "much longer")

let test_style_only_change_repaints_the_row () =
  let presenter = Presenter.create ~synchronized_output:true () in
  let captured = sink () in
  present presenter captured (frame [ "\027[31mstatus\027[0m" ]);
  reset_sink captured;
  present presenter captured (frame [ "\027[32mstatus\027[0m" ]);
  check int "style-only change writes once" 1 (List.length captured.writes);
  check bool "new style bytes are painted" true
    (contains (output captured) "\027[32mstatus")

let test_geometry_surface_and_invalidation_force_full_redraw () =
  let presenter = Presenter.create ~synchronized_output:true () in
  let captured = sink () in
  present presenter captured (frame [ "same" ]);
  reset_sink captured;
  present presenter captured (frame ~surface_key:"keepers" [ "same" ]);
  check bool "surface change redraws fully" true
    (contains (output captured) "\027[2J");
  reset_sink captured;
  present presenter captured (frame ~surface_key:"keepers" ~rows:5 [ "same" ]);
  check bool "resize redraws fully" true (contains (output captured) "\027[2J");
  reset_sink captured;
  Presenter.invalidate presenter;
  present presenter captured (frame ~surface_key:"keepers" ~rows:5 [ "same" ]);
  check bool "explicit invalidation redraws fully" true
    (contains (output captured) "\027[2J");
  reset_sink captured;
  present ~invalidate_before:true presenter captured
    (frame ~surface_key:"keepers" ~rows:5 [ "same" ]);
  check bool "out-of-band invalidation redraws an identical frame" true
    (contains (output captured) "\027[2J");
  reset_sink captured;
  present presenter captured (frame ~surface_key:"keepers" ~rows:5 [ "same" ]);
  check int "successful forced redraw restores a trusted snapshot" 0
    (List.length captured.writes);
  check int "trusted snapshot suppresses the redundant flush" 0 captured.flushes

let test_write_failure_keeps_snapshot_untrusted () =
  let presenter = Presenter.create ~synchronized_output:true () in
  let captured = sink () in
  present presenter captured (frame [ "before" ]);
  let raised =
    try
      ignore
        (Presenter.present presenter
           ~invalidate_before:false
           ~write:(fun _ -> failwith "injected write failure")
           ~flush:(fun () -> ()) (frame [ "after" ])
          : Presenter.present_result);
      false
    with Failure _ -> true
  in
  check bool "write failure is propagated" true raised;
  check bool "write failure blocks input until a retry" true
    (Presenter.last_frame_is_compact presenter);
  reset_sink captured;
  present presenter captured (frame [ "after" ]);
  check bool "write failure forces a full retry" true
    (contains (output captured) "\027[2J");
  check bool "successful write retry restores input" false
    (Presenter.last_frame_is_compact presenter);
  let flush_raised =
    try
      ignore
        (Presenter.present presenter ~invalidate_before:false
           ~write:(fun _ -> ())
           ~flush:(fun () -> failwith "injected flush failure")
           (frame [ "after flush" ])
          : Presenter.present_result);
      false
    with Failure _ -> true
  in
  check bool "flush failure is propagated" true flush_raised;
  check bool "flush failure blocks input until a retry" true
    (Presenter.last_frame_is_compact presenter);
  reset_sink captured;
  present presenter captured (frame [ "after flush" ]);
  check bool "flush failure also forces a full retry" true
    (contains (output captured) "\027[2J");
  check bool "successful flush retry restores input" false
    (Presenter.last_frame_is_compact presenter)

let test_sync_fallback_and_visible_cursor_are_explicit () =
  let presenter = Presenter.create ~synchronized_output:false () in
  let captured = sink () in
  let visible =
    frame ~cursor:(Presenter.Visible_at { row = 2; column = 6 })
      [ "message"; "input" ]
  in
  present presenter captured visible;
  let first = output captured in
  check bool "fallback omits synchronized output" false
    (contains first "\027[?2026");
  check bool "frame disables autowrap while painting" true
    (contains first "\027[?7l");
  check bool "frame restores autowrap" true (contains first "\027[?7h");
  check bool "visible frame positions and shows the cursor last" true
    (contains first "\027[2;6H\027[?25h");
  reset_sink captured;
  present presenter captured visible;
  check int "identical visible frame writes nothing" 0
    (List.length captured.writes);
  let moved =
    frame ~cursor:(Presenter.Visible_at { row = 2; column = 7 })
      [ "message"; "input" ]
  in
  present presenter captured moved;
  check int "cursor-only move writes once" 1 (List.length captured.writes);
  check bool "cursor-only move stays differential" false
    (contains (output captured) "\027[2J");
  check bool "cursor-only move reaches the new column" true
    (contains (output captured) "\027[2;7H\027[?25h");
  reset_sink captured;
  Presenter.cleanup presenter ~write:(write captured) ~flush:(flush captured);
  check int "cleanup writes once" 1 (List.length captured.writes);
  check int "cleanup flushes once" 1 captured.flushes;
  let cleanup = output captured in
  check bool "sync-disabled cleanup omits 2026 bytes" false
    (contains cleanup "\027[?2026");
  check bool "cleanup restores cursor and autowrap" true
    (contains cleanup "\027[?25h\027[?7h");
  let synchronized = Presenter.create ~synchronized_output:true () in
  reset_sink captured;
  Presenter.cleanup synchronized ~write:(write captured) ~flush:(flush captured);
  check bool "sync-enabled cleanup emits the end marker" true
    (contains (output captured) "\027[?2026l")

let test_viewport_discards_offscreen_rows () =
  let presenter = Presenter.create ~synchronized_output:true () in
  let captured = sink () in
  present presenter captured
    (frame ~rows:2 [ "visible one"; "visible two"; "offscreen" ]);
  let painted = output captured in
  check bool "last visible row is painted" true (contains painted "visible two");
  check bool "offscreen row is not emitted" false (contains painted "offscreen")

(* A scheme changes the ink it names; without this it does not change the two
   colours it does not name. masc draws most of its text without naming a
   colour, so that text is the terminal's default foreground. *)
let solarized_dark =
  { Presenter.foreground =
      Masc_tui_terminal_palette.make_rgb ~red:0x93 ~green:0xa1 ~blue:0xa1
  ; background =
      Masc_tui_terminal_palette.make_rgb ~red:0x00 ~green:0x2b ~blue:0x36
  }
;;

let test_a_scheme_repaints_the_terminals_own_background () =
  let captured = sink () in
  Presenter.sync_page ~write:(write captured) ~flush:(flush captured)
    (Some solarized_dark);
  let sent = output captured in
  check bool "OSC 11 carries the scheme's own background" true
    (contains sent "\027]11;rgb:00/2b/36\027\\")

(* The half that was missing. Between #31196 and its fix masc painted the page
   and left the text: pick a light scheme on a dark terminal and the page went
   near-white under the reader's near-white default text. Measured on a pty --
   nine OSC 11 went out walking the catalogue and no OSC 10 at all. *)
let test_a_scheme_also_repaints_the_terminals_own_text () =
  let captured = sink () in
  Presenter.sync_page ~write:(write captured) ~flush:(flush captured)
    (Some solarized_dark);
  check bool "OSC 10 carries the scheme's own foreground" true
    (contains (output captured) "\027]10;rgb:93/a1/a1\027\\")

let test_withdrawing_a_scheme_puts_the_background_back () =
  (* [None] is "follow the terminal", which is a reset rather than a colour:
     masc has no opinion to send once the reader has withdrawn theirs. Both
     halves come back, for the same reason both go out. *)
  let captured = sink () in
  Presenter.sync_page ~write:(write captured) ~flush:(flush captured) None;
  let sent = output captured in
  check bool "OSC 111 restores the terminal's own page" true
    (contains sent "\027]111\027\\");
  check bool "OSC 110 restores the terminal's own text" true
    (contains sent "\027]110\027\\")

let test_cleanup_returns_the_background_before_the_screen () =
  (* The failure this exists for: quit with a scheme in force and the reader's
     shell keeps masc's colours until they close the window. Order matters --
     the reset has to land while the alternate screen is still up, so the
     screen that comes back is already wearing its own. *)
  let presenter = Presenter.create ~synchronized_output:false () in
  let captured = sink () in
  Presenter.cleanup presenter ~write:(write captured) ~flush:(flush captured);
  let left = output captured in
  check bool "cleanup returns the background" true
    (contains left "\027]111\027\\");
  check bool "cleanup returns the text colour too" true
    (contains left "\027]110\027\\");
  let reset_at = Str.search_forward (Str.regexp_string "\027]110") left 0 in
  let leave_at = Str.search_forward (Str.regexp_string "\027[?1049l") left 0 in
  check bool "before leaving the alternate screen" true (reset_at < leave_at)

let test_alternate_screen_is_taken_and_given_back () =
  let presenter = Presenter.create ~synchronized_output:false () in
  let captured = sink () in
  Presenter.setup presenter ~write:(write captured) ~flush:(flush captured);
  let entered = output captured in
  check bool "setup takes the alternate screen" true
    (contains entered "\027[?1049h");
  reset_sink captured;
  Presenter.cleanup presenter ~write:(write captured) ~flush:(flush captured);
  let left = output captured in
  check bool "cleanup gives the alternate screen back" true
    (contains left "\027[?1049l");
  (* Leaving restores what the shell had. Clearing would take it away, which
     is the whole reason the frame borrowed a screen of its own. *)
  check bool "cleanup does not clear the screen it hands back" false
    (contains left "\027[2J");
  (* A screen taken fresh has nothing to diff against. *)
  reset_sink captured;
  present presenter captured (frame ~rows:2 [ "after resume" ]);
  check bool "the frame after setup is a full redraw" true
    (contains (output captured) "\027[2J")
;;

let test_repeated_identical_frames_retain_zero_alloc_unchanged () =
  let presenter = Presenter.create ~synchronized_output:true () in
  let captured = sink () in
  let f = frame ~rows:300 [ "row 1"; "row 2"; "row 3" ] in
  (match present_result presenter captured f with
   | Presenter.Presented -> ()
   | Presenter.Unchanged -> fail "first frame must be presented");
  check int "first frame writes once" 1 (List.length captured.writes);
  for _ = 1 to 10 do
    reset_sink captured;
    (match present_result presenter captured f with
     | Presenter.Unchanged -> ()
     | Presenter.Presented -> fail "identical frame must return Unchanged");
    check int "repeated frame writes 0" 0 (List.length captured.writes);
    check int "repeated frame flushes 0" 0 captured.flushes
  done;
  (* Change row 280 (exceeding row_prefix_cache_size 256) to test fallback *)
  let changed_rows =
    List.init 285 (fun r -> if r = 280 then "row 280 changed" else Printf.sprintf "row %d" (r + 1))
  in
  reset_sink captured;
  let f_large = frame ~rows:300 changed_rows in
  (match present_result presenter captured f_large with
   | Presenter.Presented -> ()
   | Presenter.Unchanged -> fail "changed large frame must be presented");
  let out = output captured in
  check bool "large row index uses absolute addressing" true
    (contains out "\027[281;1H")
;;

let () =
  run "tui_frame_presenter"
    [ ( "differential output"
      , [ test_case "first and identical frames" `Quick
            test_first_frame_and_identical_frame
        ; test_case "repeated identical frames zero-alloc" `Quick
            test_repeated_identical_frames_retain_zero_alloc_unchanged
        ; test_case "one changed row" `Quick test_only_changed_row_is_written
        ; test_case "input follows the presented frame" `Quick
            test_input_gate_follows_the_last_presented_frame
        ; test_case "shorter and removed rows" `Quick
            test_shorter_content_clears_stale_rows
        ; test_case "style-only row change" `Quick
            test_style_only_change_repaints_the_row
        ; test_case "full redraw boundaries" `Quick
            test_geometry_surface_and_invalidation_force_full_redraw
        ; test_case "write failure retry" `Quick
            test_write_failure_keeps_snapshot_untrusted
        ; test_case "sync fallback and visible cursor" `Quick
            test_sync_fallback_and_visible_cursor_are_explicit
        ; test_case "viewport clipping" `Quick
            test_viewport_discards_offscreen_rows
        ; test_case "alternate screen" `Quick
            test_alternate_screen_is_taken_and_given_back
        ; test_case "a scheme repaints the terminal's background" `Quick
            test_a_scheme_repaints_the_terminals_own_background
        ; test_case "a scheme repaints the terminal's text too" `Quick
            test_a_scheme_also_repaints_the_terminals_own_text
        ; test_case "withdrawing puts the background back" `Quick
            test_withdrawing_a_scheme_puts_the_background_back
        ; test_case "cleanup returns the background first" `Quick
            test_cleanup_returns_the_background_before_the_screen
        ] )
    ]
