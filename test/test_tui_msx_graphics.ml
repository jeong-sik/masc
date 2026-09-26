(** Which way the spectator draws, and that the fallback is still there.

    A character cell carries two colours, so the block mosaic can only ever
    show a fraction of a frame: at 150 columns the whole 256x192 screen
    arrives as about 8,500 of its 49,152 pixels, and no finer block character
    changes that -- more subdivisions per cell do not add colours to the cell.
    Handing the pixels to a terminal that draws images is the only step that
    does, so which path runs is worth pinning. *)

open Alcotest

module Msx = Masc_tui_msx
module Types = Masc_tui_types
module Graphics = Masc_tui_graphics

let frame ?(w = 256) ?(h = 192) ?(mode = "screen2") () =
  { Types.msx_number = 1
  ; msx_width = w
  ; msx_height = h
  ; msx_rgb = String.make (w * h * 3) '\128'
  ; msx_meta =
      Some { Types.msx_mode = mode; msx_cartridge = Some "test.rom"; msx_disk = None;
             msx_players = [] }
  }
;;

(* Stage 1: the picture arrives as a surface frame. The pixels match what
   [frame] used to carry in msx_rgb, so the drawing assertions below are
   unchanged — they now prove the renderer reads them through the contract. *)
let surface_of ?(w = 256) ?(h = 192) () =
  Masc_tui_interactive.Pixels { width = w; height = h; rgb = String.make (w * h * 3) '\128' }
;;

let drawn ?(f = frame ()) ?(surface = surface_of ()) ?notice () =
  let buf = Buffer.create 65536 in
  Msx.render ~live:Masc_tui_machine_live.Unread
    ~write:(Buffer.add_string buf)
    ~connection:Masc_tui_types.Connected
    ?notice
    (Some f)
    (Some surface);
  Buffer.contents buf
;;

let drawn_empty ~connection =
  let buf = Buffer.create 4096 in
  Msx.render ~live:Masc_tui_machine_live.Unread ~write:(Buffer.add_string buf) ~connection None None;
  Buffer.contents buf
;;

let mentions ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec at i = i + n <= h && (String.sub haystack i n = needle || at (i + 1)) in
  n = 0 || at 0
;;

(* An empty cache reads the same whether the server said no machine is loaded
   or could not be reached to say anything: Masc_tui_http maps a transport
   failure onto the [None] a loaded:false answer gives. What is on screen has
   to separate them, or an operator whose server is down is told to load a
   machine. *)
let test_a_connected_server_with_no_machine_says_so () =
  let text = drawn_empty ~connection:Masc_tui_types.Connected in
  check bool "names the loader" true (mentions ~needle:"masc_msx_load" text);
  check bool "does not blame the connection" false
    (mentions ~needle:"the server is" text)

let test_an_unreachable_server_is_not_a_missing_machine () =
  List.iter
    (fun (connection, label) ->
      let text = drawn_empty ~connection in
      check bool
        (label ^ ": says the server could not be asked")
        true
        (mentions ~needle:("the server is " ^ label) text);
      check bool
        (label ^ ": does not send the reader to the loader")
        false
        (mentions ~needle:"masc_msx_load" text))
    [ Masc_tui_types.Disconnected, "disconnected"
    ; Masc_tui_types.Reconnecting, "reconnecting..."
    ; Masc_tui_types.Booting, "server booting..."
    ; Masc_tui_types.Connecting, "connecting..."
    ]

(* Restore whatever the protocol was, so a case cannot leak its choice into
   the next one. The setter is the only way in, so there is nothing to read
   back -- the default is what a terminal that never answered leaves. *)
let with_protocol p f =
  Msx.set_graphics_protocol p;
  Fun.protect ~finally:(fun () -> Msx.set_graphics_protocol Graphics.Unsupported_protocol) f
;;

let test_a_graphics_terminal_gets_the_pixels () =
  with_protocol Graphics.Kitty_protocol (fun () ->
    let out = drawn () in
    check bool "the frame went out as raw pixels" true (mentions ~needle:"f=24" out);
    check bool "with the machine's own width" true (mentions ~needle:"s=256" out);
    check bool "and height" true (mentions ~needle:"v=192" out);
    (* The mosaic writes a truecolour pair per cell; the graphics path writes
       none, so this separates the two rather than merely observing output. *)
    check bool "and no mosaic was drawn" false (mentions ~needle:"\027[38;2;" out))
;;

let test_every_other_terminal_still_gets_the_mosaic () =
  List.iter
    (fun (name, p) ->
      with_protocol p (fun () ->
        let out = drawn () in
        check bool
          (Printf.sprintf "%s draws the mosaic" name)
          true
          (mentions ~needle:"\027[38;2;" out);
        check bool
          (Printf.sprintf "%s sends no pixels" name)
          false
          (mentions ~needle:"f=24" out)))
    [ "iterm2", Graphics.ITerm2_protocol
    ; "a terminal that does not draw images", Graphics.Unsupported_protocol
    ]
;;

(* SCREEN6/7 frames arrive 512 wide on the wire (ocaml-msx #15 keeps the
   native pixels instead of squeezing them into 256). The spectator must
   carry the frame's own width through both drawing paths rather than
   assume 256 -- a squeezed assumption is exactly how a map's fine text
   doubles over and reads as broken. *)
let test_a_512_wide_frame_keeps_its_width () =
  let wide = frame ~w:512 ~mode:"GRAPHIC6" () in
  with_protocol Graphics.Kitty_protocol (fun () ->
    let out = drawn ~f:wide ~surface:(surface_of ~w:512 ()) () in
    check bool "the raw pixels went out at the frame's width" true
      (mentions ~needle:"s=512" out);
    check bool "and height" true (mentions ~needle:"v=192" out);
    check bool "and no mosaic was drawn" false (mentions ~needle:"\027[38;2;" out))
;;

let test_the_mosaic_takes_a_512_wide_frame () =
  let wide = frame ~w:512 ~mode:"GRAPHIC6" () in
  with_protocol Graphics.Unsupported_protocol (fun () ->
    let out = drawn ~f:wide ~surface:(surface_of ~w:512 ()) () in
    check bool "the mosaic drew from the wide frame" true
      (mentions ~needle:"\027[38;2;" out);
    check bool "no pixel protocol leaked" false (mentions ~needle:"f=24" out))
;;

(* Stage 1 contract: the picture is the surface frame. The meta's pixel
   fields are not read — changing them alone must not transmit pixels. *)
let test_meta_pixels_do_not_draw () =
  with_protocol Graphics.Kitty_protocol (fun () ->
    ignore (drawn ());
    let f = frame () in
    let meta_changed = { f with Types.msx_rgb = String.make (256 * 192 * 3) '\001' } in
    let buf = Buffer.create 1024 in
    Msx.render ~live:Masc_tui_machine_live.Unread
      ~write:(Buffer.add_string buf)
      ~connection:Types.Connected
      (Some meta_changed)
      (Some (surface_of ()));
    check bool "a changed meta rgb with the same surface sends no pixels"
      false
      (mentions ~needle:"f=24" (Buffer.contents buf)))
;;

let test_checkpoint_bindings_and_result_are_visible () =
  with_protocol Graphics.Kitty_protocol (fun () ->
    let out = drawn () in
    check bool "footer names quick save" true (mentions ~needle:"F6: save quick" out);
    check bool "footer names quick restore" true (mentions ~needle:"F7: restore quick" out);
    List.iter (fun notice ->
      let out = drawn ~notice () in
      check bool "checkpoint outcome remains visible beside the frame" true
        (mentions ~needle:notice out);
      (* In Kitty the explicit placement cursor used to jump back onto the
         notice row; merely finding the notice bytes missed the overlap. *)
      check bool "image begins below the notice" true
        (mentions ~needle:"\027[3;1H" out);
      check bool "image does not cover the notice row" false
        (mentions ~needle:"\027[2;1H" out);
      let rows, _ = Masc_tui_ansi.get_terminal_size () in
      check bool "footer remains on the final terminal row" true
        (mentions ~needle:(Printf.sprintf "\027[%d;1H" rows) out);
      check bool "notice keeps save control visible" true (mentions ~needle:"F6: save quick" out);
      check bool "notice keeps restore control visible" true (mentions ~needle:"F7: restore quick" out))
      [ "Saved quick checkpoint"; "Restored quick checkpoint"; "Restore failed: no checkpoint" ])
;;

(* Restore the cell size for the same reason [with_protocol] restores the
   protocol: it is module state and a case must not leak it. *)
let with_cell_pixels px f =
  Msx.set_cell_pixels px;
  Fun.protect ~finally:(fun () -> Msx.set_cell_pixels None) f
;;

(* The row count out of the placement escape: "...,r=N,...". Kitty derives the
   width from it, so it is the only number that decides how wide the image is
   drawn, and reading it back is how the fit is measured. *)
let rows_of out =
  let needle = ",r=" in
  let n = String.length needle and h = String.length out in
  let rec at i =
    if i + n > h then None
    else if String.sub out i n = needle then begin
      let start = i + n in
      let rec digits j = if j < h && out.[j] >= '0' && out.[j] <= '9' then digits (j + 1) else j in
      let stop = digits start in
      if stop > start then int_of_string_opt (String.sub out start (stop - start)) else None
    end
    else at (i + 1)
  in
  at 0
;;

(* A 256x192 frame is 4:3 and a terminal grid is not. Kitty takes the row
   count and derives the width from the frame's shape, so a row count that
   fills the height puts the width past the right edge on any grid that is
   wider than 4:3 in pixels -- and the terminal cuts it there. Only the cell
   size says where that edge is.

   The cell size is derived from the grid rather than written down: the width
   binds only when the grid is wide relative to the frame, and a pair of
   numbers that binds at 80x24 stops binding at another size. Picking half the
   break-even width keeps the width the tighter of the two wherever this runs,
   and the case checks that premise before it checks the fit. *)
let test_the_image_is_kept_inside_the_screen () =
  let rows, cols = Masc_tui_ansi.get_terminal_size () in
  let screen_rows = max 4 (rows - 2) in
  let cell_height = 20 in
  let break_even_width = screen_rows * cell_height * 256 / (192 * cols) in
  let cell_width = max 1 (break_even_width / 2) in
  let available_width = cols * cell_width in
  let available_height = screen_rows * cell_height in
  let height_the_width_allows = available_width * 192 / 256 in
  check bool "the width is the binding constraint here" true
    (height_the_width_allows < available_height);
  with_protocol Graphics.Kitty_protocol (fun () ->
    with_cell_pixels (Some (cell_width, cell_height)) (fun () ->
      match rows_of (drawn ()) with
      | None -> failf "the placement carried no row count"
      | Some drawn_rows ->
        (* Filling the height would have overflowed the width, so the row count
           has to come down. Without this the case passes on a placement that
           ignores the cell size entirely. *)
        check bool "the rows came down from the screen's" true
          (drawn_rows < screen_rows);
        check bool "and it still drew something" true (drawn_rows >= 1);
        let drawn_width = drawn_rows * cell_height * 256 / 192 in
        check bool "and its width fits the terminal" true
          (drawn_width <= available_width)))
;;

(* Without an answer there is nothing to compute with, and guessing a cell size
   would size every placement against a number no terminal gave. *)
let test_no_cell_size_leaves_the_rows_alone () =
  let rows, _ = Masc_tui_ansi.get_terminal_size () in
  let screen_rows = max 4 (rows - 2) in
  with_protocol Graphics.Kitty_protocol (fun () ->
    with_cell_pixels None (fun () ->
      check (option int) "the screen's rows, unchanged" (Some screen_rows)
        (rows_of (drawn ()))))
;;

let draw_frame f =
  let buf = Buffer.create 1024 in
  Msx.render ~live:Masc_tui_machine_live.Unread ~write:(Buffer.add_string buf) ~connection:Types.Connected (Some f)
    (Some (Masc_tui_interactive.Pixels
             { width = f.Types.msx_width; height = f.Types.msx_height; rgb = f.Types.msx_rgb }));
  Buffer.contents buf

let test_retained_pixels () =
  with_protocol Graphics.Kitty_protocol (fun () ->
    let f = frame () in
    let first = draw_frame f in
    let next = draw_frame { f with msx_number = 2 } in
    check bool "initial pixels" true (mentions ~needle:"f=24" first);
    check bool "counter updates" true (mentions ~needle:"frame 2" next);
    check bool "no erase display" false (mentions ~needle:"\027[2J" next);
    check bool "no duplicate pixels" false (mentions ~needle:"f=24" next);
    check bool "counter update is small" true (String.length next < 512);
    Printf.printf "MSX retained wire: first=%d counter_only=%d bytes\n%!"
      (String.length first) (String.length next);
    let changed = draw_frame { f with msx_rgb = String.make (String.length f.msx_rgb) '\127' } in
    check bool "changed pixels transmitted" true (mentions ~needle:"f=24" changed);
    check bool "stable image and placement" true (mentions ~needle:"i=32,p=1,C=1" changed);
    check bool "changed pixels do not clear" false (mentions ~needle:"\027[2J" changed))

let test_failed_write_and_layout () =
  with_protocol Graphics.Kitty_protocol (fun () ->
    ignore (drawn ());
    let failed =
      try
        Msx.render ~live:Masc_tui_machine_live.Unread ~write:(fun _ -> raise Exit) ~connection:Types.Connected
          (Some (frame ())) (Some (surface_of ()));
        false
      with Exit -> true
    in
    check bool "write failure propagated" true failed;
    let retry = drawn () in
    check bool "retry sends pixels" true (mentions ~needle:"f=24" retry);
    check bool "retry clears uncertain placement" true (mentions ~needle:"d=I,i=32" retry);
    Msx.adjust_size (-1.0);
    Fun.protect ~finally:(fun () -> Msx.adjust_size 1.0) (fun () ->
      let resized = drawn () in
      check bool "size change retires old placement" true (mentions ~needle:"d=I,i=32" resized);
      check bool "size change transmits" true (mentions ~needle:"f=24" resized));
    let empty = drawn_empty ~connection:Types.Connected in
    check bool "empty frame removes old image" true (mentions ~needle:"d=I,i=32" empty))

let test_surface_lifecycle () =
  with_protocol Graphics.Kitty_protocol (fun () ->
    let state = Types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 () in
    ignore (drawn ());
    let buf = Buffer.create 1024 in
    Msx.render_menu ~write:(Buffer.add_string buf) state;
    check bool "menu removes image" true (mentions ~needle:"d=I,i=32" (Buffer.contents buf));
    check bool "return from menu sends pixels" true (mentions ~needle:"f=24" (drawn ()));
    Buffer.clear buf;
    ignore (Msx.consume ~write:(Buffer.add_string buf) state "esc");
    check bool "exit removes image" true (mentions ~needle:"d=I,i=32" (Buffer.contents buf));
    check bool "reopen sends pixels" true (mentions ~needle:"f=24" (drawn ())))

let test_synchronized_batch () =
  with_protocol Graphics.Kitty_protocol (fun () ->
    Msx.set_synchronized_output true;
    Fun.protect ~finally:(fun () -> Msx.set_synchronized_output false) (fun () ->
      let out = drawn () in
      check bool "batch begins synchronized" true (String.starts_with ~prefix:"\027[?2026h" out);
      check bool "batch ends synchronized" true (String.ends_with ~suffix:"\027[?2026l" out));
    check bool "existing opt out respected" false (mentions ~needle:"?2026" (drawn ())))


(* The menu clears the rest of the screen so a shorter list leaves no ghost rows.
   A newline written on the bottom row scrolls the terminal by one, and the row
   that scrolls off is the first -- the title, which is the only place this
   screen says [esc] goes back. Measured at 150x44 with no cartridges: the screen
   held the sentence about the empty directory and a blank, and nothing said how
   to leave.

   The written bytes are what can be asserted here; the scroll is the terminal's
   doing. So this counts the line breaks: one fewer than the rows, which is what
   leaves the cursor on the last row instead of past it. *)
let test_the_menu_does_not_scroll_its_title_off () =
  let rows, _ = Masc_tui_ansi.get_terminal_size () in
  let written = Buffer.create 4096 in
  let state = Masc_tui_types.create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  Masc_tui_msx.render_menu ~write:(Buffer.add_string written) state;
  let text = Buffer.contents written in
  let breaks =
    let n = ref 0 in
    String.iteri
      (fun i ch ->
        if Char.equal ch '\n' && i > 0 && Char.equal text.[i - 1] '\r' then incr n)
      text;
    !n
  in
  Alcotest.(check int) "one line break fewer than the rows it fills"
    (max 4 rows - 1) breaks;
  Alcotest.(check bool) "and the title is in the bytes" true
    (let needle = "pick a game" in
     let nl = String.length needle in
     let rec seek i =
       i + nl <= String.length text
       && (String.equal (String.sub text i nl) needle || seek (i + 1))
     in
     seek 0)

(* ---------- activity sidebar ---------- *)

let live_picture ?(w = 256) ?(h = 192) () : Masc_tui_machine_live.picture =
  { width = w; height = h; rgb = String.make (w * h * 3) '\128';
    mark = { count = 1; incarnation = "inc-1" }; time = Masc_tui_machine_live.Untimed }

(* The mosaic path, not Kitty's: its picture rows are plain text the sidebar
   assertions below can search for a substring in, same as every other case
   in this file that does not explicitly ask for Kitty. *)
let drawn_live ?(activity = []) () =
  with_protocol Graphics.Unsupported_protocol (fun () ->
    let buf = Buffer.create 65536 in
    Msx.render_live ~write:(Buffer.add_string buf) ~connection:Types.Connected ~activity
      Masc_tui_machine_live.Dos (Masc_tui_machine_live.Showing (live_picture ()));
    Buffer.contents buf)

(* The two numbers {!Msx.shows_sidebar} weighs are exact, so this is checked
   as a pure function of them rather than through any real or assumed
   terminal width. *)
let test_shows_sidebar_weighs_width_against_the_two_reserved_amounts () =
  check bool "nothing to show, however wide" false
    (Msx.shows_sidebar ~cols:1000 ~has_activity:false);
  check int "and the picture keeps the whole width" 1000
    (Msx.picture_cols ~cols:1000 ~has_activity:false);
  check bool "enough room for both" true (Msx.shows_sidebar ~cols:100 ~has_activity:true);
  check int "the picture gives up the sidebar and its gap"
    (100 - Msx.sidebar_cols - 1) (Msx.picture_cols ~cols:100 ~has_activity:true);
  check bool "just short of the picture's minimum" false
    (Msx.shows_sidebar ~cols:(Msx.sidebar_cols + 1 + Msx.min_picture_cols - 1)
       ~has_activity:true);
  check bool "exactly at the picture's minimum" true
    (Msx.shows_sidebar ~cols:(Msx.sidebar_cols + 1 + Msx.min_picture_cols) ~has_activity:true)

(* Through the real renderer, at whatever width this actually runs: the
   [shows_sidebar] question asked of the real terminal decides which of the
   two the output must match, the way [test_the_image_is_kept_inside_the_screen]
   derives its own expectation from the same real size rather than a fake
   one. *)
let test_activity_draws_exactly_when_shows_sidebar_says_to () =
  let _, cols = Masc_tui_ansi.get_terminal_size () in
  let out =
    drawn_live
      ~activity:[ { Masc_tui_machine_live.at = 0.; who = "liu-bei"; action = "step 1,000" } ]
      ()
  in
  if Msx.shows_sidebar ~cols ~has_activity:true then begin
    check bool "the actor is on screen" true (mentions ~needle:"liu-bei" out);
    check bool "and what they did" true (mentions ~needle:"step 1,000" out)
  end
  else begin
    check bool "too narrow for a sidebar: no actor leaks into the picture" false
      (mentions ~needle:"liu-bei" out);
    check bool "no action either" false (mentions ~needle:"step 1,000" out)
  end

(* With nothing to show, [draw]'s sidebar block never runs at all -- not
   even to write blank rows -- so the mosaic path (the default protocol
   here) never emits the explicit footer reposition only that block adds;
   the sequential ["\r\n"]s already leave the cursor there on their own. *)
let test_no_activity_draws_no_sidebar () =
  let rows, _ = Masc_tui_ansi.get_terminal_size () in
  let header_rows = 1 in
  let screen_rows = max 4 (rows - header_rows - 1) in
  let out = drawn_live ~activity:[] () in
  check bool "no explicit footer reposition" false
    (mentions ~needle:(Printf.sprintf "\027[%d;1H" (header_rows + screen_rows + 1)) out)

(* [who]/[action] ride in from a Keeper's own tool call arguments -- an
   escape byte there must not reach the terminal raw, sidebar or not. *)
let test_activity_entries_are_sanitized () =
  let out =
    drawn_live
      ~activity:[ { Masc_tui_machine_live.at = 0.; who = "\x1b[31mred\x1b[0m"; action = "x" } ]
      ()
  in
  check bool "the raw escape does not reach the terminal" false
    (mentions ~needle:"\x1b[31mred" out)

let () =
  run "masc_tui_msx graphics"
    [ ( "retained"
      , [ test_case "unchanged and changed pixels" `Quick test_retained_pixels
        ; test_case "failure and layout invalidate" `Quick test_failed_write_and_layout
        ; test_case "surface lifecycle" `Quick test_surface_lifecycle
        ; test_case "synchronized batch" `Quick test_synchronized_batch
        ] )
    ; ( "path"
      , [ test_case "a graphics terminal gets the pixels" `Quick
            test_a_graphics_terminal_gets_the_pixels
        ; test_case "every other terminal still gets the mosaic" `Quick
            test_every_other_terminal_still_gets_the_mosaic
        ; test_case "a 512-wide frame keeps its width" `Quick
            test_a_512_wide_frame_keeps_its_width
        ; test_case "the mosaic takes a 512-wide frame" `Quick
            test_the_mosaic_takes_a_512_wide_frame
        ; test_case "meta pixels do not draw" `Quick
            test_meta_pixels_do_not_draw
        ; test_case "checkpoint bindings and outcome" `Quick
            test_checkpoint_bindings_and_result_are_visible
        ] )
    ; ( "fit"
      , [ test_case "the image is kept inside the screen" `Quick
            test_the_image_is_kept_inside_the_screen
        ; test_case "no cell size leaves the rows alone" `Quick
            test_no_cell_size_leaves_the_rows_alone
        ] )
    ; ( "menu"
      , [ test_case "the menu does not scroll its title off" `Quick
            test_the_menu_does_not_scroll_its_title_off
        ] )
    ; ( "empty"
      , [ test_case "a connected server with no machine says so" `Quick
            test_a_connected_server_with_no_machine_says_so
        ; test_case "an unreachable server is not a missing machine" `Quick
            test_an_unreachable_server_is_not_a_missing_machine
        ] )
    ; ( "activity sidebar"
      , [ test_case "shows_sidebar weighs width against the two reserved amounts" `Quick
            test_shows_sidebar_weighs_width_against_the_two_reserved_amounts
        ; test_case "activity draws exactly when shows_sidebar says to" `Quick
            test_activity_draws_exactly_when_shows_sidebar_says_to
        ; test_case "no activity draws no sidebar" `Quick
            test_no_activity_draws_no_sidebar
        ; test_case "activity entries are sanitized" `Quick
            test_activity_entries_are_sanitized
        ] )
    ]
;;
