(** The DOS spectator screen (#38424): its title and footer, both drawing
    paths at the DOS frame's own size, and that no key is a machine key. *)

open Alcotest

module Dos = Masc_tui_dos
module View = Masc_tui_machine_view
module Types = Masc_tui_types
module Graphics = Masc_tui_graphics

let vga_width = 640
let vga_height = 480

let frame ?(w = vga_width) ?(h = vga_height) ?(program = Some "SAN3.EXE")
    ?(controller = Some "keeper-cao-cao") ?(steps = 1234) () =
  { Types.dos_incarnation = "incarnation-1"
  ; dos_steps = steps
  ; dos_program = program
  ; dos_controller = controller
  ; dos_video_mode = 0x12
  ; dos_width = w
  ; dos_height = h
  ; dos_rgb = String.make (w * h * 3) '\128'
  }
;;

let drawn ?(connection = Types.Connected) ?notice f =
  let buf = Buffer.create 65536 in
  Dos.render ~write:(Buffer.add_string buf) ~connection ?notice f;
  Buffer.contents buf
;;

let mentions ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec at i = i + n <= h && (String.sub haystack i n = needle || at (i + 1)) in
  n = 0 || at 0
;;

let with_protocol p f =
  View.set_graphics_protocol p;
  Fun.protect ~finally:(fun () -> View.set_graphics_protocol Graphics.Unsupported_protocol) f
;;

let test_the_title_names_program_controller_and_steps () =
  let title = Dos.title_of ~connection:Types.Connected (Some (frame ())) in
  check bool "program" true (mentions ~needle:"SAN3.EXE" title);
  check bool "controller holder" true (mentions ~needle:"controller: keeper-cao-cao" title);
  check bool "steps" true (mentions ~needle:"step 1234" title);
  let free = Dos.title_of ~connection:Types.Connected (Some (frame ~controller:None ())) in
  check bool "a free controller says so" true (mentions ~needle:"controller: free" free);
  let unnamed = Dos.title_of ~connection:Types.Connected (Some (frame ~program:None ())) in
  check bool "a machine with no program name says so" true
    (mentions ~needle:"(no program)" unnamed)
;;

(* A keeper name and a program name come off the wire; an escape sequence in
   either must not reach the terminal as a command. *)
let test_wire_names_are_sanitised () =
  let title =
    Dos.title_of ~connection:Types.Connected
      (Some (frame ~program:(Some "EVIL\027[2J.EXE") ~controller:(Some "k\027]0;x\007") ()))
  in
  check bool "no raw escape in the title" false (String.contains title '\027')
;;

let test_the_frame_is_drawn_with_title_and_footer () =
  let out = drawn (Some (frame ())) in
  check bool "the title is drawn" true (mentions ~needle:"DOS \xe2\x80\x94 SAN3.EXE" out);
  check bool "the footer names the way out" true (mentions ~needle:"Esc: back" out);
  check bool "the footer names the size keys" true (mentions ~needle:"+/-:" out);
  check bool "and says keys do not reach the machine" true
    (mentions ~needle:"keys never reach the machine" out)
;;

let test_no_machine_and_no_server_are_told_apart () =
  let empty = drawn ~connection:Types.Connected None in
  check bool "names the loader" true (mentions ~needle:"masc_dos_load" empty);
  check bool "the footer is still there" true (mentions ~needle:"Esc: back" empty);
  let down = drawn ~connection:Types.Disconnected None in
  check bool "blames the connection" true (mentions ~needle:"the server is disconnected" down);
  check bool "does not send the reader to the loader" false
    (mentions ~needle:"masc_dos_load" down)
;;

let test_a_notice_is_shown_beside_the_frame () =
  let out = drawn ~notice:"frame read failed: timeout" (Some (frame ())) in
  check bool "the notice is drawn" true (mentions ~needle:"frame read failed: timeout" out)
;;

let test_a_graphics_terminal_gets_the_vga_pixels () =
  with_protocol Graphics.Kitty_protocol (fun () ->
    View.invalidate ();
    let out = drawn (Some (frame ())) in
    check bool "raw pixels" true (mentions ~needle:"f=24" out);
    check bool "at the frame's own width" true (mentions ~needle:"s=640" out);
    check bool "and height" true (mentions ~needle:"v=480" out);
    check bool "and no mosaic" false (mentions ~needle:"\027[38;2;" out);
    let tall = drawn (Some (frame ~h:400 ())) in
    check bool "a 640x400 mode keeps its height" true (mentions ~needle:"v=400" tall))
;;

let test_every_other_terminal_gets_the_mosaic () =
  with_protocol Graphics.Unsupported_protocol (fun () ->
    let out = drawn (Some (frame ())) in
    check bool "the mosaic is drawn" true (mentions ~needle:"\027[38;2;" out);
    check bool "no pixels are sent" false (mentions ~needle:"f=24" out))
;;

(* A spectator only: esc closes, the size keys are the view's, and every
   other key -- a game key on the MSX screen -- only repaints. *)
let test_no_key_is_a_machine_key () =
  check bool "esc closes" true (Dos.key_action "esc" = Dos.Close);
  check bool "+ grows" true (Dos.key_action "+" = Dos.Resize 1.0);
  check bool "- shrinks" true (Dos.key_action "-" = Dos.Resize (-1.0));
  List.iter
    (fun key -> check bool (key ^ " only repaints") true (Dos.key_action key = Dos.Repaint))
    [ "enter"; "space"; " "; "a"; "up"; "f1"; "" ]
;;

let test_esc_closes_and_takes_the_image_away () =
  with_protocol Graphics.Kitty_protocol (fun () ->
    let state = Types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 () in
    state.dos_open <- true;
    state.dos_frame <- Some (frame ());
    ignore (drawn (Some (frame ())));
    let buf = Buffer.create 1024 in
    check bool "a key keeps the screen open" true
      (Dos.consume ~write:(Buffer.add_string buf) state "a");
    check bool "and is still open" true state.dos_open;
    Buffer.clear buf;
    check bool "esc says the screen closed" false
      (Dos.consume ~write:(Buffer.add_string buf) state "esc");
    check bool "the screen is closed" false state.dos_open;
    check bool "its image is removed" true (mentions ~needle:"d=I,i=32" (Buffer.contents buf)))
;;

let () =
  run "masc_tui_dos graphics"
    [ ( "title"
      , [ test_case "program, controller and steps" `Quick
            test_the_title_names_program_controller_and_steps
        ; test_case "wire names are sanitised" `Quick test_wire_names_are_sanitised
        ; test_case "title and footer are drawn" `Quick
            test_the_frame_is_drawn_with_title_and_footer
        ; test_case "no machine and no server are told apart" `Quick
            test_no_machine_and_no_server_are_told_apart
        ; test_case "a notice is shown beside the frame" `Quick
            test_a_notice_is_shown_beside_the_frame
        ] )
    ; ( "path"
      , [ test_case "a graphics terminal gets the VGA pixels" `Quick
            test_a_graphics_terminal_gets_the_vga_pixels
        ; test_case "every other terminal gets the mosaic" `Quick
            test_every_other_terminal_gets_the_mosaic
        ] )
    ; ( "keys"
      , [ test_case "no key is a machine key" `Quick test_no_key_is_a_machine_key
        ; test_case "esc closes and takes the image away" `Quick
            test_esc_closes_and_takes_the_image_away
        ] )
    ]
;;
