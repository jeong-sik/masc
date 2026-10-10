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

let drawn ?(f = frame ()) ?(surface = surface_of ()) ?notice ?interaction () =
  let buf = Buffer.create 65536 in
  Msx.render ~live:Masc_tui_machine_live.Unread
    ~write:(Buffer.add_string buf)
    ~connection:Masc_tui_types.Connected
    ?notice ?interaction
    (Some f)
    (Some surface);
  Buffer.contents buf
;;

let drawn_empty ~live ~connection =
  let buf = Buffer.create 4096 in
  Msx.render ~live ~write:(Buffer.add_string buf) ~connection None None;
  Buffer.contents buf
;;

let mentions ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec at i = i + n <= h && (String.sub haystack i n = needle || at (i + 1)) in
  n = 0 || at 0
;;

let with_protocol p f =
  Msx.set_graphics_protocol p;
  Msx.set_cell_pixels (Some (8, 16));
  Fun.protect ~finally:(fun () ->
    Msx.set_cell_pixels None;
    Msx.set_graphics_protocol Graphics.Unsupported_protocol) f
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
    let empty = drawn_empty ~live:Masc_tui_machine_live.Unread
        ~connection:Types.Connected in
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
    check bool "reopen sends pixels" true (mentions ~needle:"f=24" (drawn ()));
    state.msx_open <- true;
    Buffer.clear buf;
    Msx.close ~write:(Buffer.add_string buf) state;
    Types.withdraw_machine_control state;
    check bool "workspace withdrawal deletes the image" true
      (mentions ~needle:"d=I,i=32" (Buffer.contents buf));
    check bool "workspace withdrawal releases screen ownership" false state.msx_open;
    check bool "new workspace sends its pixels" true (mentions ~needle:"f=24" (drawn ())))

let test_synchronized_batch () =
  with_protocol Graphics.Kitty_protocol (fun () ->
    Msx.set_synchronized_output true;
    Fun.protect ~finally:(fun () -> Msx.set_synchronized_output false) (fun () ->
      let out = drawn () in
      check bool "batch begins synchronized" true (String.starts_with ~prefix:"\027[?2026h" out);
      check bool "batch ends synchronized" true (String.ends_with ~suffix:"\027[?2026l" out));
    check bool "existing opt out respected" false (mentions ~needle:"?2026" (drawn ())))

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
      Masc.Machine_lane.Dos (Masc_tui_machine_live.Showing (live_picture ()));
    Buffer.contents buf)

let test_activity_entries_are_sanitized () =
  let out =
    drawn_live
      ~activity:[ { Masc_tui_machine_live.at = 0.; who = "\x1b[31mred\x1b[0m"; action = "x" } ]
      ()
  in
  check bool "the raw escape does not reach the terminal" false
    (mentions ~needle:"\x1b[31mred" out)

(* Restore the cell size for the same reason [with_protocol] restores the
   protocol: it is module state and a case must not leak it. *)
let with_cell_pixels px f =
  Msx.set_cell_pixels px;
  Fun.protect ~finally:(fun () -> Msx.set_cell_pixels None) f
;;

(* Without a measured cell size, row-only graphics have no width bound. The
   cell mosaic still preserves the entire frame inside its column budget. *)
let test_no_cell_size_uses_bounded_mosaic () =
  with_protocol Graphics.Kitty_protocol (fun () ->
    with_cell_pixels None (fun () ->
      let out = drawn () in
      check bool "no unbounded pixel placement" false (mentions ~needle:"f=24" out);
      check bool "the frame remains visible" true (mentions ~needle:"\027[38;2;" out)))
;;

let test_unicode_title_fits_cells () =
  let _, cols = Masc_tui_ansi.get_terminal_size () in
  let f = frame ~mode:(String.concat "" (List.init cols (fun _ -> "한글"))) () in
  let out = drawn ~f () in
  check bool "no split UTF-8 scalar" true (String.is_valid_utf_8 out);
  let title = List.hd (String.split_on_char '\n' out) in
  (* Drop cursor/erase escapes; keep the actual title cells. *)
  let start = String.index title ' ' in
  let stop = match String.index_from_opt title start '\r' with
    | Some stop -> stop
    | None -> String.index_from title start '\027' in
  let title = String.sub title start (stop - start) in
  check string "title already fits terminal columns" title
    (Masc_tui_ansi.fit_width title cols)

let test_failed_menu_output_cannot_authorize_a_choice () =
  List.iter (fun mode ->
    let state = Types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 () in
    state.msx_carts <- ["game.rom"; "disk.dsk"];
    Msx.open_menu ~write:ignore ~mode state;
    (try Msx.render_menu ~write:(fun _ -> raise Exit) state with Exit -> ());
    check bool "an unsuccessful menu frame cannot load or swap a hidden choice" true
      (Msx.menu_consume ~write:ignore state "enter" = Msx.Stay);
    check bool "the successful repaint restores the visible choice" true
      (match mode, Msx.menu_consume ~write:ignore state "enter" with
       | Types.Boot_game, Msx.Load "game.rom"
       | Types.Change_disk, Msx.Swap_disk "disk.dsk" -> true
       | _ -> false))
    [Types.Boot_game; Types.Change_disk]

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
        ;] )
    ; ( "fit"
      , [ test_case "no cell size uses bounded mosaic" `Quick
            test_no_cell_size_uses_bounded_mosaic
                ; test_case "Unicode title fits cells" `Quick test_unicode_title_fits_cells
        ] )
    ; ( "menu"
      , [ test_case "failed output cannot authorize a hidden choice" `Quick
            test_failed_menu_output_cannot_authorize_a_choice
        ] )
    ; ( "empty"
      , [] )
    ; ( "activity sidebar"
      , [ test_case "activity entries are sanitized" `Quick
            test_activity_entries_are_sanitized
        ] )
    ]
;;
