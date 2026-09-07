(* The MSX spectator screen (RFC-0439 §3.7). The machine lives in the server;
   this screen only renders the frame it is handed. What is pinned here: an
   empty frame draws a "no machine" line and never a machine, a real frame
   draws a body, opening writes and sets the flag, and esc is the one key that
   closes. *)

open Alcotest

let a_frame ?(cartridge = Some "xspelunker") () : Masc_tui_types.msx_frame =
  { msx_number = 345
  ; msx_width = 256
  ; msx_height = 192
  ; msx_rgb = String.make (256 * 192 * 3) '\128'
  ; msx_mode = "GRAPHIC2"
  ; msx_cartridge = cartridge
  }

let captured render =
  let buf = Buffer.create 4096 in
  render (fun text -> Buffer.add_string buf text);
  Buffer.contents buf

let contains hay needle =
  let n = String.length needle and m = String.length hay in
  let rec at i j = j = n || (hay.[i + j] = needle.[j] && at i (j + 1)) in
  let rec go i = i + n <= m && (at i 0 || go (i + 1)) in
  n = 0 || go 0

let test_empty_frame () =
  let out = captured (fun write -> Masc_tui_msx.render ~write None) in
  check bool "an empty frame says no machine is loaded" true
    (contains out "no machine loaded");
  check bool "and writes something" true (String.length out > 0)

let test_real_frame () =
  let out = captured (fun write -> Masc_tui_msx.render ~write (Some (a_frame ()))) in
  check bool "a real frame names the mode" true (contains out "GRAPHIC2");
  check bool "and the cartridge" true (contains out "xspelunker");
  check bool "and the frame number" true (contains out "345");
  check bool "and draws a body (many rows)" true (String.length out > 2000)

let test_open_and_close () =
  let state =
    Masc_tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  state.msx_frame <- Some (a_frame ());
  let frames = ref [] in
  let write text = frames := text :: !frames in
  Masc_tui_msx.open_screen ~write state;
  check bool "opening sets the flag" true state.msx_open;
  check bool "opening draws" true (!frames <> []);
  check bool "a non-esc key keeps the screen open" true
    (Masc_tui_msx.consume ~write state "space");
  check bool "esc closes and returns false" false
    (Masc_tui_msx.consume ~write state "esc");
  check bool "the flag is cleared" false state.msx_open

let () =
  run "MSX spectator"
    [ ( "render"
      , [ test_case "empty frame" `Quick test_empty_frame
        ; test_case "real frame" `Quick test_real_frame
        ; test_case "open and close" `Quick test_open_and_close
        ] )
    ]
