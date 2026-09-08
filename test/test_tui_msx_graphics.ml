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

let frame () =
  let w = 256 and h = 192 in
  { Types.msx_number = 1
  ; msx_width = w
  ; msx_height = h
  ; msx_rgb = String.make (w * h * 3) '\128'
  ; msx_mode = "screen2"
  ; msx_cartridge = Some "test.rom"
  }
;;

let drawn () =
  let buf = Buffer.create 65536 in
  Msx.render ~write:(Buffer.add_string buf) (Some (frame ()));
  Buffer.contents buf
;;

let mentions ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec at i = i + n <= h && (String.sub haystack i n = needle || at (i + 1)) in
  n = 0 || at 0
;;

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

let () =
  run "masc_tui_msx graphics"
    [ ( "path"
      , [ test_case "a graphics terminal gets the pixels" `Quick
            test_a_graphics_terminal_gets_the_pixels
        ; test_case "every other terminal still gets the mosaic" `Quick
            test_every_other_terminal_still_gets_the_mosaic
        ] )
    ]
;;
