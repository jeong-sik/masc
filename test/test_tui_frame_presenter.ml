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

let frame ?(surface_key = "overview") ?(cursor = Presenter.Hidden)
    ?(rows = 4) ?(cols = 40) lines : Presenter.frame =
  { surface_key;
    terminal_rows = rows;
    terminal_cols = cols;
    cursor;
    lines;
  }

let present ?(invalidate_before = false) presenter sink frame =
  Presenter.present presenter ~invalidate_before ~write:(write sink)
    ~flush:(flush sink) frame

let test_first_frame_and_identical_frame () =
  let presenter = Presenter.create ~synchronized_output:true () in
  let captured = sink () in
  let initial = frame [ "top"; "middle"; "bottom" ] in
  present presenter captured initial;
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
  present presenter captured initial;
  check int "identical frame writes nothing" 0 (List.length captured.writes);
  check int "identical frame does not flush" 0 captured.flushes

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
      Presenter.present presenter
        ~invalidate_before:false
        ~write:(fun _ -> failwith "injected write failure")
        ~flush:(fun () -> ()) (frame [ "after" ]);
      false
    with Failure _ -> true
  in
  check bool "write failure is propagated" true raised;
  reset_sink captured;
  present presenter captured (frame [ "after" ]);
  check bool "write failure forces a full retry" true
    (contains (output captured) "\027[2J");
  let flush_raised =
    try
      Presenter.present presenter ~invalidate_before:false ~write:(fun _ -> ())
        ~flush:(fun () -> failwith "injected flush failure")
        (frame [ "after flush" ]);
      false
    with Failure _ -> true
  in
  check bool "flush failure is propagated" true flush_raised;
  reset_sink captured;
  present presenter captured (frame [ "after flush" ]);
  check bool "flush failure also forces a full retry" true
    (contains (output captured) "\027[2J")

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

let () =
  run "tui_frame_presenter"
    [ ( "differential output"
      , [ test_case "first and identical frames" `Quick
            test_first_frame_and_identical_frame
        ; test_case "one changed row" `Quick test_only_changed_row_is_written
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
        ] )
    ]
