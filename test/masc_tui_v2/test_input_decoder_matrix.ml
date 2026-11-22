open Masc_tui_term
open Masc_tui_keymap

let mk ?(ctrl = false) ?(alt = false) ?(shift = false) key :
    Input_decoder.key_event =
  { key; mods = { ctrl; alt; shift } }

let equal_reply a b =
  match a, b with
  | Input_decoder.Palette_reply x, Input_decoder.Palette_reply y ->
      x.slot = y.slot && Option.equal Palette.equal_rgb x.color y.color
  | Input_decoder.Cell_pixels_reply x, Input_decoder.Cell_pixels_reply y ->
      Int.equal x.width y.width && Int.equal x.height y.height
  | Input_decoder.Graphics_reply x, Input_decoder.Graphics_reply y ->
      String.equal x y
  | Input_decoder.Palette_reply _, (Input_decoder.Cell_pixels_reply _ | Input_decoder.Graphics_reply _)
  | Input_decoder.Cell_pixels_reply _, (Input_decoder.Palette_reply _ | Input_decoder.Graphics_reply _)
  | Input_decoder.Graphics_reply _, (Input_decoder.Palette_reply _ | Input_decoder.Cell_pixels_reply _) ->
      false

let equal_event a b =
  match a, b with
  | Input_decoder.Key x, Input_decoder.Key y -> Input_decoder.equal_key_event x y
  | Input_decoder.Paste x, Input_decoder.Paste y ->
      Input_decoder.equal_paste_event x y
  | Input_decoder.Mouse x, Input_decoder.Mouse y ->
      Input_decoder.equal_mouse_event x y
  | Input_decoder.Reply x, Input_decoder.Reply y -> equal_reply x y
  | Input_decoder.Unknown_escape, Input_decoder.Unknown_escape
  | Input_decoder.Invalid_utf8, Input_decoder.Invalid_utf8 ->
      true
  | ( Input_decoder.Key _,
      ( Input_decoder.Paste _ | Input_decoder.Mouse _ | Input_decoder.Reply _
      | Input_decoder.Unknown_escape | Input_decoder.Invalid_utf8 ) )
  | ( Input_decoder.Paste _,
      ( Input_decoder.Key _ | Input_decoder.Mouse _ | Input_decoder.Reply _
      | Input_decoder.Unknown_escape | Input_decoder.Invalid_utf8 ) )
  | ( Input_decoder.Mouse _,
      ( Input_decoder.Key _ | Input_decoder.Paste _ | Input_decoder.Reply _
      | Input_decoder.Unknown_escape | Input_decoder.Invalid_utf8 ) )
  | ( Input_decoder.Reply _,
      ( Input_decoder.Key _ | Input_decoder.Paste _ | Input_decoder.Mouse _
      | Input_decoder.Unknown_escape | Input_decoder.Invalid_utf8 ) )
  | ( Input_decoder.Unknown_escape,
      ( Input_decoder.Key _ | Input_decoder.Paste _ | Input_decoder.Mouse _
      | Input_decoder.Reply _ | Input_decoder.Invalid_utf8 ) )
  | ( Input_decoder.Invalid_utf8,
      ( Input_decoder.Key _ | Input_decoder.Paste _ | Input_decoder.Mouse _
      | Input_decoder.Reply _ | Input_decoder.Unknown_escape ) ) ->
      false

let equal_event_list xs ys =
  Int.equal (List.length xs) (List.length ys) && List.for_all2 equal_event xs ys

let pp_mods fmt (m : Input_decoder.modifiers) =
  Format.fprintf fmt "{c=%b;a=%b;s=%b}" m.ctrl m.alt m.shift

let pp_key fmt = function
  | Input_decoder.Char s -> Format.fprintf fmt "Char %S" s
  | Input_decoder.Enter -> Format.fprintf fmt "Enter"
  | Input_decoder.Tab -> Format.fprintf fmt "Tab"
  | Input_decoder.Backspace -> Format.fprintf fmt "Backspace"
  | Input_decoder.Escape -> Format.fprintf fmt "Escape"
  | Input_decoder.Delete -> Format.fprintf fmt "Delete"
  | Input_decoder.Insert -> Format.fprintf fmt "Insert"
  | Input_decoder.Up -> Format.fprintf fmt "Up"
  | Input_decoder.Down -> Format.fprintf fmt "Down"
  | Input_decoder.Left -> Format.fprintf fmt "Left"
  | Input_decoder.Right -> Format.fprintf fmt "Right"
  | Input_decoder.Home -> Format.fprintf fmt "Home"
  | Input_decoder.End -> Format.fprintf fmt "End"
  | Input_decoder.Page_up -> Format.fprintf fmt "Page_up"
  | Input_decoder.Page_down -> Format.fprintf fmt "Page_down"
  | Input_decoder.Function n -> Format.fprintf fmt "Function %d" n

let pp_event fmt = function
  | Input_decoder.Key { key; mods } ->
      Format.fprintf fmt "Key(%a, %a)" pp_key key pp_mods mods
  | Input_decoder.Paste { text; dropped_bytes } ->
      Format.fprintf fmt "Paste(%S, dropped=%d)" text dropped_bytes
  | Input_decoder.Mouse (Input_decoder.Wheel { dir; col; row }) ->
      let d =
        match dir with
        | Input_decoder.Wheel_up -> "up"
        | Input_decoder.Wheel_down -> "down"
      in
      Format.fprintf fmt "Mouse(Wheel %s %d,%d)" d col row
  | Input_decoder.Mouse (Input_decoder.Left_press { col; row }) ->
      Format.fprintf fmt "Mouse(Press %d,%d)" col row
  | Input_decoder.Mouse (Input_decoder.Left_drag { col; row }) ->
      Format.fprintf fmt "Mouse(Drag %d,%d)" col row
  | Input_decoder.Mouse (Input_decoder.Left_release { col; row }) ->
      Format.fprintf fmt "Mouse(Release %d,%d)" col row
  | Input_decoder.Reply (Input_decoder.Cell_pixels_reply { width; height }) ->
      Format.fprintf fmt "Reply(Cell %dx%d)" width height
  | Input_decoder.Reply (Input_decoder.Graphics_reply s) ->
      Format.fprintf fmt "Reply(Gfx %S)" s
  | Input_decoder.Reply (Input_decoder.Palette_reply _) ->
      Format.fprintf fmt "Reply(Palette)"
  | Input_decoder.Unknown_escape -> Format.fprintf fmt "Unknown_escape"
  | Input_decoder.Invalid_utf8 -> Format.fprintf fmt "Invalid_utf8"

let event_list_testable =
  Alcotest.testable
    (Format.pp_print_list ~pp_sep:(fun f () -> Format.fprintf f "; ") pp_event)
    equal_event_list

let feed_one_by_one dec seq =
  let acc = ref [] in
  String.iter
    (fun ch -> acc := List.rev_append (Input_decoder.feed dec ch) !acc)
    seq;
  List.rev !acc

let check_matrix_case ~expect_pending_after (label, seq, expected) =
  (* 1. Whole-buffer feed *)
  let dec_whole = Input_decoder.create () in
  let got_whole = Input_decoder.feed_string dec_whole seq in
  Alcotest.(check event_list_testable) (label ^ " [whole]") expected got_whole;
  Alcotest.(check bool)
    (label ^ " [whole pending]")
    expect_pending_after
    (Input_decoder.has_pending dec_whole);

  (* 2. Every 1-byte split-chunk boundary *)
  let dec_split = Input_decoder.create () in
  let got_split = feed_one_by_one dec_split seq in
  Alcotest.(check event_list_testable) (label ^ " [1-byte]") expected got_split;
  Alcotest.(check bool)
    (label ^ " [1-byte pending]")
    expect_pending_after
    (Input_decoder.has_pending dec_split)

let total_matrix_cases = ref 0

let run_matrix ?(expect_pending_after = false) cases =
  List.iter
    (fun c ->
      incr total_matrix_cases;
      check_matrix_case ~expect_pending_after c)
    cases

(* -------------------------------------------------------------------------- *)
(* 1. Raw ASCII, Control Bytes & Legacy Alt/Meta Chords                       *)
(* -------------------------------------------------------------------------- *)

let ascii_and_ctrl_cases : (string * string * Input_decoder.event list) list =
  let open Input_decoder in
  [
    ("ASCII a", "a", [ Key (mk (Char "a")) ]);
    ("ASCII Z", "Z", [ Key (mk (Char "Z")) ]);
    ("ASCII 0", "0", [ Key (mk (Char "0")) ]);
    ("ASCII space", " ", [ Key (mk (Char " ")) ]);
    ("ASCII slash", "/", [ Key (mk (Char "/")) ]);
    ("ASCII question", "?", [ Key (mk (Char "?")) ]);
    ("ASCII colon", ":", [ Key (mk (Char ":")) ]);
    ("ASCII tilde", "~", [ Key (mk (Char "~")) ]);
    ("ASCII lbracket", "[", [ Key (mk (Char "[")) ]);
    ("ASCII rbracket", "]", [ Key (mk (Char "]")) ]);
    ("Ctrl+Space NUL", "\x00", [ Key (mk ~ctrl:true (Char " ")) ]);
    ("Ctrl+A", "\x01", [ Key (mk ~ctrl:true (Char "a")) ]);
    ("Ctrl+B", "\x02", [ Key (mk ~ctrl:true (Char "b")) ]);
    ("Ctrl+C", "\x03", [ Key (mk ~ctrl:true (Char "c")) ]);
    ("Ctrl+D", "\x04", [ Key (mk ~ctrl:true (Char "d")) ]);
    ("Ctrl+E", "\x05", [ Key (mk ~ctrl:true (Char "e")) ]);
    ("Ctrl+F", "\x06", [ Key (mk ~ctrl:true (Char "f")) ]);
    ("Ctrl+G", "\x07", [ Key (mk ~ctrl:true (Char "g")) ]);
    ("BS 0x08", "\x08", [ Key (mk Backspace) ]);
    ("Tab 0x09", "\x09", [ Key (mk Tab) ]);
    ("Ctrl+J LF", "\x0a", [ Key (mk ~ctrl:true (Char "j")) ]);
    ("Ctrl+K", "\x0b", [ Key (mk ~ctrl:true (Char "k")) ]);
    ("Ctrl+L", "\x0c", [ Key (mk ~ctrl:true (Char "l")) ]);
    ("Enter CR", "\x0d", [ Key (mk Enter) ]);
    ("Ctrl+N", "\x0e", [ Key (mk ~ctrl:true (Char "n")) ]);
    ("Ctrl+O", "\x0f", [ Key (mk ~ctrl:true (Char "o")) ]);
    ("Ctrl+P", "\x10", [ Key (mk ~ctrl:true (Char "p")) ]);
    ("Ctrl+Q", "\x11", [ Key (mk ~ctrl:true (Char "q")) ]);
    ("Ctrl+R", "\x12", [ Key (mk ~ctrl:true (Char "r")) ]);
    ("Ctrl+S", "\x13", [ Key (mk ~ctrl:true (Char "s")) ]);
    ("Ctrl+T", "\x14", [ Key (mk ~ctrl:true (Char "t")) ]);
    ("Ctrl+U", "\x15", [ Key (mk ~ctrl:true (Char "u")) ]);
    ("Ctrl+V", "\x16", [ Key (mk ~ctrl:true (Char "v")) ]);
    ("Ctrl+W", "\x17", [ Key (mk ~ctrl:true (Char "w")) ]);
    ("Ctrl+X", "\x18", [ Key (mk ~ctrl:true (Char "x")) ]);
    ("Ctrl+Y", "\x19", [ Key (mk ~ctrl:true (Char "y")) ]);
    ("Ctrl+Z (VSUSP reclaimed)", "\x1a", [ Key (mk ~ctrl:true (Char "z")) ]);
    ("Ctrl+backslash", "\x1c", [ Key (mk ~ctrl:true (Char "\\")) ]);
    ("Ctrl+rbracket", "\x1d", [ Key (mk ~ctrl:true (Char "]")) ]);
    ("Ctrl+caret", "\x1e", [ Key (mk ~ctrl:true (Char "^")) ]);
    ("Ctrl+underscore", "\x1f", [ Key (mk ~ctrl:true (Char "_")) ]);
    ("DEL 0x7F Backspace", "\x7f", [ Key (mk Backspace) ]);
  ]

(* -------------------------------------------------------------------------- *)
(* 2. CSI Navigation, Function Keys, Tilde Keys & Modifiers                   *)
(* -------------------------------------------------------------------------- *)

let csi_cases : (string * string * Input_decoder.event list) list =
  let open Input_decoder in
  [
    ("CSI Up", "\x1b[A", [ Key (mk Up) ]);
    ("CSI Down", "\x1b[B", [ Key (mk Down) ]);
    ("CSI Right", "\x1b[C", [ Key (mk Right) ]);
    ("CSI Left", "\x1b[D", [ Key (mk Left) ]);
    ("CSI Home", "\x1b[H", [ Key (mk Home) ]);
    ("CSI End", "\x1b[F", [ Key (mk End) ]);
    ("CSI F1", "\x1b[P", [ Key (mk (Function 1)) ]);
    ("CSI F2", "\x1b[Q", [ Key (mk (Function 2)) ]);
    ("CSI F3", "\x1b[R", [ Key (mk (Function 3)) ]);
    ("CSI F4", "\x1b[S", [ Key (mk (Function 4)) ]);
    ("CSI Shift+Tab Z", "\x1b[Z", [ Key (mk ~shift:true Tab) ]);
    ("CSI Shift+Up", "\x1b[1;2A", [ Key (mk ~shift:true Up) ]);
    ("CSI Alt+Down", "\x1b[1;3B", [ Key (mk ~alt:true Down) ]);
    ("CSI Alt+Shift+Right", "\x1b[1;4C", [ Key (mk ~alt:true ~shift:true Right) ]);
    ("CSI Ctrl+Left", "\x1b[1;5D", [ Key (mk ~ctrl:true Left) ]);
    ("CSI Ctrl+Shift+Up", "\x1b[1;6A", [ Key (mk ~ctrl:true ~shift:true Up) ]);
    ("CSI Ctrl+Alt+Down", "\x1b[1;7B", [ Key (mk ~ctrl:true ~alt:true Down) ]);
    ( "CSI Ctrl+Alt+Shift+Right",
      "\x1b[1;8C",
      [ Key (mk ~ctrl:true ~alt:true ~shift:true Right) ] );
    ("CSI Shift+Home", "\x1b[1;2H", [ Key (mk ~shift:true Home) ]);
    ("CSI Ctrl+End", "\x1b[1;5F", [ Key (mk ~ctrl:true End) ]);
    ("CSI Shift+F1", "\x1b[1;2P", [ Key (mk ~shift:true (Function 1)) ]);
    ("CSI Alt+F2", "\x1b[1;3Q", [ Key (mk ~alt:true (Function 2)) ]);
    ("CSI Ctrl+F3", "\x1b[1;5R", [ Key (mk ~ctrl:true (Function 3)) ]);
    ("CSI Ctrl+Shift+F4", "\x1b[1;6S", [ Key (mk ~ctrl:true ~shift:true (Function 4)) ]);
    ("CSI tilde Home 1~", "\x1b[1~", [ Key (mk Home) ]);
    ("CSI tilde Insert 2~", "\x1b[2~", [ Key (mk Insert) ]);
    ("CSI tilde Delete 3~", "\x1b[3~", [ Key (mk Delete) ]);
    ("CSI tilde End 4~", "\x1b[4~", [ Key (mk End) ]);
    ("CSI tilde PageUp 5~", "\x1b[5~", [ Key (mk Page_up) ]);
    ("CSI tilde PageDown 6~", "\x1b[6~", [ Key (mk Page_down) ]);
    ("CSI tilde Home 7~", "\x1b[7~", [ Key (mk Home) ]);
    ("CSI tilde End 8~", "\x1b[8~", [ Key (mk End) ]);
    ("CSI tilde F1 11~", "\x1b[11~", [ Key (mk (Function 1)) ]);
    ("CSI tilde F2 12~", "\x1b[12~", [ Key (mk (Function 2)) ]);
    ("CSI tilde F3 13~", "\x1b[13~", [ Key (mk (Function 3)) ]);
    ("CSI tilde F4 14~", "\x1b[14~", [ Key (mk (Function 4)) ]);
    ("CSI tilde F5 15~", "\x1b[15~", [ Key (mk (Function 5)) ]);
    ("CSI tilde F6 17~", "\x1b[17~", [ Key (mk (Function 6)) ]);
    ("CSI tilde F7 18~", "\x1b[18~", [ Key (mk (Function 7)) ]);
    ("CSI tilde F8 19~", "\x1b[19~", [ Key (mk (Function 8)) ]);
    ("CSI tilde F9 20~", "\x1b[20~", [ Key (mk (Function 9)) ]);
    ("CSI tilde F10 21~", "\x1b[21~", [ Key (mk (Function 10)) ]);
    ("CSI tilde F11 23~", "\x1b[23~", [ Key (mk (Function 11)) ]);
    ("CSI tilde F12 24~", "\x1b[24~", [ Key (mk (Function 12)) ]);
    ("CSI Ctrl+Delete", "\x1b[3;5~", [ Key (mk ~ctrl:true Delete) ]);
    ("CSI Shift+PageUp", "\x1b[5;2~", [ Key (mk ~shift:true Page_up) ]);
    ("CSI Shift+F5", "\x1b[15;2~", [ Key (mk ~shift:true (Function 5)) ]);
    ("CSI Ctrl+F12", "\x1b[24;5~", [ Key (mk ~ctrl:true (Function 12)) ]);
    ("CSI repeat event", "\x1b[1;2:2A", [ Key (mk ~shift:true Up) ]);
    ("CSI release ignored", "\x1b[1;2:3A", []);
    ("CSI tilde release ignored", "\x1b[3;5:3~", []);
    ("CSI CPR rejected", "\x1b[24;1R", [ Unknown_escape ]);
    ("CSI CPR 12;5R rejected", "\x1b[12;5R", [ Unknown_escape ]);
    ("CSI mod=0 rejected", "\x1b[1;0A", [ Unknown_escape ]);
    ("CSI unsupported super mod rejected", "\x1b[1;9A", [ Unknown_escape ]);
    ("CSI invalid event type rejected", "\x1b[1;2:9A", [ Unknown_escape ]);
    ("CSI mid-ESC recovers next seq", "\x1b[1;2\x1b[B", [ Unknown_escape; Key (mk Down) ]);
    ("CSI param overflow", "\x1b[" ^ String.make 65 '1' ^ "A", [ Unknown_escape; Key (mk (Char "A")) ]);
    ("CSI cell pixels reply", "\x1b[6;18;9t", [ Reply (Cell_pixels_reply { width = 9; height = 18 }) ]);
  ]

(* -------------------------------------------------------------------------- *)
(* 3. SS3 Plain, Modified (ESC O <mod> <final>) & rxvt (ESC O a..d)           *)
(* -------------------------------------------------------------------------- *)

let ss3_cases : (string * string * Input_decoder.event list) list =
  let open Input_decoder in
  [
    ("SS3 Up", "\x1bOA", [ Key (mk Up) ]);
    ("SS3 Down", "\x1bOB", [ Key (mk Down) ]);
    ("SS3 Right", "\x1bOC", [ Key (mk Right) ]);
    ("SS3 Left", "\x1bOD", [ Key (mk Left) ]);
    ("SS3 Home", "\x1bOH", [ Key (mk Home) ]);
    ("SS3 End", "\x1bOF", [ Key (mk End) ]);
    ("SS3 F1", "\x1bOP", [ Key (mk (Function 1)) ]);
    ("SS3 F2", "\x1bOQ", [ Key (mk (Function 2)) ]);
    ("SS3 F3", "\x1bOR", [ Key (mk (Function 3)) ]);
    ("SS3 F4", "\x1bOS", [ Key (mk (Function 4)) ]);
    ("SS3 Keypad Enter", "\x1bOM", [ Key (mk Enter) ]);
    ("SS3 Shift+F1 (ESC O 2 P)", "\x1bO2P", [ Key (mk ~shift:true (Function 1)) ]);
    ("SS3 Shift+F2 (ESC O 2 Q)", "\x1bO2Q", [ Key (mk ~shift:true (Function 2)) ]);
    ("SS3 Shift+F3 (ESC O 2 R)", "\x1bO2R", [ Key (mk ~shift:true (Function 3)) ]);
    ("SS3 Shift+F4 (ESC O 2 S)", "\x1bO2S", [ Key (mk ~shift:true (Function 4)) ]);
    ("SS3 Alt+F1 (ESC O 3 P)", "\x1bO3P", [ Key (mk ~alt:true (Function 1)) ]);
    ("SS3 Alt+Shift+F2 (ESC O 4 Q)", "\x1bO4Q", [ Key (mk ~alt:true ~shift:true (Function 2)) ]);
    ("SS3 Ctrl+F1 (ESC O 5 P)", "\x1bO5P", [ Key (mk ~ctrl:true (Function 1)) ]);
    ("SS3 Ctrl+Shift+F1 (ESC O 6 P)", "\x1bO6P", [ Key (mk ~ctrl:true ~shift:true (Function 1)) ]);
    ("SS3 Ctrl+Alt+F3 (ESC O 7 R)", "\x1bO7R", [ Key (mk ~ctrl:true ~alt:true (Function 3)) ]);
    ( "SS3 Ctrl+Alt+Shift+F4 (ESC O 8 S)",
      "\x1bO8S",
      [ Key (mk ~ctrl:true ~alt:true ~shift:true (Function 4)) ] );
    ("SS3 Shift+Up (ESC O 2 A)", "\x1bO2A", [ Key (mk ~shift:true Up) ]);
    ("SS3 Shift+Down (ESC O 2 B)", "\x1bO2B", [ Key (mk ~shift:true Down) ]);
    ("SS3 Shift+Right (ESC O 2 C)", "\x1bO2C", [ Key (mk ~shift:true Right) ]);
    ("SS3 Shift+Left (ESC O 2 D)", "\x1bO2D", [ Key (mk ~shift:true Left) ]);
    ("SS3 Ctrl+Up (ESC O 5 A)", "\x1bO5A", [ Key (mk ~ctrl:true Up) ]);
    ("SS3 Ctrl+Down (ESC O 5 B)", "\x1bO5B", [ Key (mk ~ctrl:true Down) ]);
    ("SS3 Shift+Home (ESC O 2 H)", "\x1bO2H", [ Key (mk ~shift:true Home) ]);
    ("SS3 Shift+End (ESC O 2 F)", "\x1bO2F", [ Key (mk ~shift:true End) ]);
    ("SS3 Shift+KP_Enter (ESC O 2 M)", "\x1bO2M", [ Key (mk ~shift:true Enter) ]);
    ("SS3 1;2P extended", "\x1bO1;2P", [ Key (mk ~shift:true (Function 1)) ]);
    ("SS3 1;5Q extended", "\x1bO1;5Q", [ Key (mk ~ctrl:true (Function 2)) ]);
    ("SS3 repeat event 2:2P", "\x1bO2:2P", [ Key (mk ~shift:true (Function 1)) ]);
    ("SS3 release event 2:3P ignored", "\x1bO2:3P", []);
    ("rxvt SS3 Ctrl+Up (ESC O a)", "\x1bOa", [ Key (mk ~ctrl:true Up) ]);
    ("rxvt SS3 Ctrl+Down (ESC O b)", "\x1bOb", [ Key (mk ~ctrl:true Down) ]);
    ("rxvt SS3 Ctrl+Right (ESC O c)", "\x1bOc", [ Key (mk ~ctrl:true Right) ]);
    ("rxvt SS3 Ctrl+Left (ESC O d)", "\x1bOd", [ Key (mk ~ctrl:true Left) ]);
    ("SS3 2P + next char zero leak", "\x1bO2Px", [ Key (mk ~shift:true (Function 1)); Key (mk (Char "x")) ]);
    ("rxvt SS3 a + next char zero leak", "\x1bOax", [ Key (mk ~ctrl:true Up); Key (mk (Char "x")) ]);
    ("SS3 2Z unknown final zero leak", "\x1bO2Zx", [ Unknown_escape; Key (mk (Char "x")) ]);
    ("SS3 99P invalid mod zero leak", "\x1bO99Px", [ Unknown_escape; Key (mk (Char "x")) ]);
    ("SS3 param overflow >16 bytes", "\x1bO" ^ String.make 17 '9' ^ "P", [ Unknown_escape; Key (mk (Char "P")) ]);
    ("SS3 mid-ESC recovers CSI", "\x1bO2\x1b[A", [ Unknown_escape; Key (mk Up) ]);
  ]

(* -------------------------------------------------------------------------- *)
(* 4. Kitty CSI u (Shifted Subparams, Base Layout, Mod Preservation, PUA)     *)
(* -------------------------------------------------------------------------- *)

let kitty_csi_u_cases : (string * string * Input_decoder.event list) list =
  let open Input_decoder in
  [
    (* Shifted punctuation subparams: shift=true, ctrl=false, alt=false -> shifted char, shift=false *)
    ("Kitty ? (47:63;2u)", "\x1b[47:63;2u", [ Key (mk (Char "?")) ]);
    ("Kitty : (59:58;2u)", "\x1b[59:58;2u", [ Key (mk (Char ":")) ]);
    ("Kitty < (44:60;2u)", "\x1b[44:60;2u", [ Key (mk (Char "<")) ]);
    ("Kitty > (46:62;2u)", "\x1b[46:62;2u", [ Key (mk (Char ">")) ]);
    ("Kitty { (91:123;2u)", "\x1b[91:123;2u", [ Key (mk (Char "{")) ]);
    ("Kitty } (93:125;2u)", "\x1b[93:125;2u", [ Key (mk (Char "}")) ]);
    ("Kitty ! (49:33;2u)", "\x1b[49:33;2u", [ Key (mk (Char "!")) ]);
    ("Kitty @ (50:64;2u)", "\x1b[50:64;2u", [ Key (mk (Char "@")) ]);
    ("Kitty # (51:35;2u)", "\x1b[51:35;2u", [ Key (mk (Char "#")) ]);
    ("Kitty $ (52:36;2u)", "\x1b[52:36;2u", [ Key (mk (Char "$")) ]);
    ("Kitty % (53:37;2u)", "\x1b[53:37;2u", [ Key (mk (Char "%")) ]);
    ("Kitty ^ (54:94;2u)", "\x1b[54:94;2u", [ Key (mk (Char "^")) ]);
    ("Kitty & (55:38;2u)", "\x1b[55:38;2u", [ Key (mk (Char "&")) ]);
    ("Kitty * (56:42;2u)", "\x1b[56:42;2u", [ Key (mk (Char "*")) ]);
    ("Kitty ( (57:40;2u)", "\x1b[57:40;2u", [ Key (mk (Char "(")) ]);
    ("Kitty ) (48:41;2u)", "\x1b[48:41;2u", [ Key (mk (Char ")")) ]);
    ("Kitty _ (45:95;2u)", "\x1b[45:95;2u", [ Key (mk (Char "_")) ]);
    ("Kitty + (61:43;2u)", "\x1b[61:43;2u", [ Key (mk (Char "+")) ]);
    ("Kitty | (92:124;2u)", "\x1b[92:124;2u", [ Key (mk (Char "|")) ]);
    ("Kitty \" (39:34;2u)", "\x1b[39:34;2u", [ Key (mk (Char "\"")) ]);
    ("Kitty ~ (96:126;2u)", "\x1b[96:126;2u", [ Key (mk (Char "~")) ]);
    (* Shifted letters & Unicode via shifted subparam *)
    ("Kitty A (97:65;2u)", "\x1b[97:65;2u", [ Key (mk (Char "A")) ]);
    ("Kitty Z (122:90;2u)", "\x1b[122:90;2u", [ Key (mk (Char "Z")) ]);
    ("Kitty UTF-8 Ö (246:214;2u)", "\x1b[246:214;2u", [ Key (mk (Char "Ö")) ]);
    ("Kitty Korean ㄲ (12593:12594;2u)", "\x1b[12593:12594;2u", [ Key (mk (Char "ㄲ")) ]);
    (* Base-layout subparam, associated text param, CapsLock+Shift, repeat/release *)
    ("Kitty ? with base layout (47:63:47;2u)", "\x1b[47:63:47;2u", [ Key (mk (Char "?")) ]);
    ("Kitty ? with text field (47:63;2;63u)", "\x1b[47:63;2;63u", [ Key (mk (Char "?")) ]);
    ("Kitty ? CapsLock+Shift (47:63;66u)", "\x1b[47:63;66u", [ Key (mk (Char "?")) ]);
    ("Kitty ? NumLock+Shift (47:63;130u)", "\x1b[47:63;130u", [ Key (mk (Char "?")) ]);
    ("Kitty ? explicit press (47:63;2:1u)", "\x1b[47:63;2:1u", [ Key (mk (Char "?")) ]);
    ("Kitty ? repeat (47:63;2:2u)", "\x1b[47:63;2:2u", [ Key (mk (Char "?")) ]);
    ("Kitty ? release ignored (47:63;2:3u)", "\x1b[47:63;2:3u", []);
    ("Kitty unshifted subparam keeps base / (47:63;1u)", "\x1b[47:63;1u", [ Key (mk (Char "/")) ]);
    ("Kitty empty shifted subparam (47::47;2u)", "\x1b[47::47;2u", [ Key (mk ~shift:true (Char "/")) ]);
    (* Preserve shift=true when ctrl=true or alt=true *)
    ("Kitty Ctrl+Shift+Q (113;6u)", "\x1b[113;6u", [ Key (mk ~ctrl:true ~shift:true (Char "q")) ]);
    ("Kitty Ctrl+Shift+Q with subparam (113:81;6u)", "\x1b[113:81;6u", [ Key (mk ~ctrl:true ~shift:true (Char "q")) ]);
    ("Kitty Ctrl+Shift+/ keeps shift (47:63;6u)", "\x1b[47:63;6u", [ Key (mk ~ctrl:true ~shift:true (Char "/")) ]);
    ("Kitty Alt+Shift+/ keeps shift (47:63;4u)", "\x1b[47:63;4u", [ Key (mk ~alt:true ~shift:true (Char "/")) ]);
    ("Kitty Ctrl+Alt+Shift+Q (113;8u)", "\x1b[113;8u", [ Key (mk ~ctrl:true ~alt:true ~shift:true (Char "q")) ]);
    ("Kitty Ctrl+C (99;5u)", "\x1b[99;5u", [ Key (mk ~ctrl:true (Char "c")) ]);
    ("Kitty Ctrl+Shift+C (99;6u)", "\x1b[99;6u", [ Key (mk ~ctrl:true ~shift:true (Char "c")) ]);
    ("Kitty Ctrl+Z (122;5u)", "\x1b[122;5u", [ Key (mk ~ctrl:true (Char "z")) ]);
    (* Core functional keys *)
    ("Kitty Enter (13u)", "\x1b[13u", [ Key (mk Enter) ]);
    ("Kitty Shift+Enter (13;2u)", "\x1b[13;2u", [ Key (mk ~shift:true Enter) ]);
    ("Kitty Alt+Enter (13;3u)", "\x1b[13;3u", [ Key (mk ~alt:true Enter) ]);
    ("Kitty Ctrl+Enter (13;5u)", "\x1b[13;5u", [ Key (mk ~ctrl:true Enter) ]);
    ("Kitty Shift+Enter functional subparam keeps shift (13:13;2u)", "\x1b[13:13;2u", [ Key (mk ~shift:true Enter) ]);
    ("Kitty Tab (9u)", "\x1b[9u", [ Key (mk Tab) ]);
    ("Kitty Shift+Tab (9;2u)", "\x1b[9;2u", [ Key (mk ~shift:true Tab) ]);
    ("Kitty Ctrl+Tab (9;5u)", "\x1b[9;5u", [ Key (mk ~ctrl:true Tab) ]);
    ("Kitty Escape (27u)", "\x1b[27u", [ Key (mk Escape) ]);
    ("Kitty Backspace (127u)", "\x1b[127u", [ Key (mk Backspace) ]);
    ("Kitty Alt+Backspace (127;3u)", "\x1b[127;3u", [ Key (mk ~alt:true Backspace) ]);
    ("Kitty Ctrl+Backspace (8;5u)", "\x1b[8;5u", [ Key (mk ~ctrl:true Backspace) ]);
    ("Kitty KP_Enter (57414u)", "\x1b[57414u", [ Key (mk Enter) ]);
    ("Kitty Shift+KP_Enter (57414;2u)", "\x1b[57414;2u", [ Key (mk ~shift:true Enter) ]);
    ("Kitty F1 (57364u)", "\x1b[57364u", [ Key (mk (Function 1)) ]);
    ("Kitty Ctrl+F1 (57364;5u)", "\x1b[57364;5u", [ Key (mk ~ctrl:true (Function 1)) ]);
    ("Kitty F12 (57375u)", "\x1b[57375u", [ Key (mk (Function 12)) ]);
    (* Invalid / PUA rejection *)
    ("Kitty CapsLock PUA rejected", "\x1b[57358u", [ Unknown_escape ]);
    ("Kitty F13 PUA rejected", "\x1b[57376u", [ Unknown_escape ]);
    ("Kitty LShift PUA rejected", "\x1b[57441u", [ Unknown_escape ]);
    ("Kitty malformed shifted subparam", "\x1b[47:?;2u", [ Unknown_escape ]);
    ("Kitty >3 subparams rejected", "\x1b[47:63:47:99;2u", [ Unknown_escape ]);
    ("Kitty surrogate codepoint rejected", "\x1b[55296;1u", [ Unknown_escape ]);
    ("Kitty surrogate shifted rejected", "\x1b[47:55296;2u", [ Unknown_escape ]);
  ]

(* -------------------------------------------------------------------------- *)
(* 5. xterm modifyOtherKeys (CSI 27 ; mod ; cp ~)                             *)
(* -------------------------------------------------------------------------- *)

let modify_other_keys_cases : (string * string * Input_decoder.event list) list =
  let open Input_decoder in
  [
    ("modifyOtherKeys Shift+Enter", "\x1b[27;2;13~", [ Key (mk ~shift:true Enter) ]);
    ("modifyOtherKeys Alt+Enter", "\x1b[27;3;13~", [ Key (mk ~alt:true Enter) ]);
    ("modifyOtherKeys Ctrl+Enter", "\x1b[27;5;13~", [ Key (mk ~ctrl:true Enter) ]);
    ("modifyOtherKeys Shift+Tab", "\x1b[27;2;9~", [ Key (mk ~shift:true Tab) ]);
    ("modifyOtherKeys Ctrl+Tab", "\x1b[27;5;9~", [ Key (mk ~ctrl:true Tab) ]);
    ("modifyOtherKeys Ctrl+C", "\x1b[27;5;99~", [ Key (mk ~ctrl:true (Char "c")) ]);
    ("modifyOtherKeys Ctrl+Shift+Q", "\x1b[27;6;113~", [ Key (mk ~ctrl:true ~shift:true (Char "q")) ]);
    ("modifyOtherKeys Ctrl+comma", "\x1b[27;5;44~", [ Key (mk ~ctrl:true (Char ",")) ]);
    ("modifyOtherKeys Shift+?", "\x1b[27;2;63~", [ Key (mk ~shift:true (Char "?")) ]);
    ("modifyOtherKeys Alt+[", "\x1b[27;3;91~", [ Key (mk ~alt:true (Char "[")) ]);
    ("modifyOtherKeys Alt+]", "\x1b[27;3;93~", [ Key (mk ~alt:true (Char "]")) ]);
    ("modifyOtherKeys Ctrl+Backspace", "\x1b[27;5;127~", [ Key (mk ~ctrl:true Backspace) ]);
    ("modifyOtherKeys Alt+Backspace", "\x1b[27;3;127~", [ Key (mk ~alt:true Backspace) ]);
    ("modifyOtherKeys Ctrl+Escape", "\x1b[27;5;27~", [ Key (mk ~ctrl:true Escape) ]);
    ("modifyOtherKeys release ignored", "\x1b[27;2:3;13~", []);
    ("modifyOtherKeys invalid mod", "\x1b[27;99;13~", [ Unknown_escape ]);
  ]

(* -------------------------------------------------------------------------- *)
(* 6. macOS Option (Meta-ESC, Kitty CSI u Option, and Default Option UTF-8)   *)
(* -------------------------------------------------------------------------- *)

let macos_option_cases : (string * string * Input_decoder.event list) list =
  let open Input_decoder in
  [
    (* Option-as-Meta ESC *)
    ("Meta-ESC Alt+1", "\x1b1", [ Key (mk ~alt:true (Char "1")) ]);
    ("Meta-ESC Alt+6", "\x1b6", [ Key (mk ~alt:true (Char "6")) ]);
    ("Meta-ESC Alt+t", "\x1bt", [ Key (mk ~alt:true (Char "t")) ]);
    ("Meta-ESC Alt+Shift+T", "\x1bT", [ Key (mk ~alt:true ~shift:true (Char "t")) ]);
    ("Meta-ESC Alt+y", "\x1by", [ Key (mk ~alt:true (Char "y")) ]);
    ("Meta-ESC Alt+n", "\x1bn", [ Key (mk ~alt:true (Char "n")) ]);
    ("Meta-ESC Alt+Enter CR", "\x1b\r", [ Key (mk ~alt:true Enter) ]);
    ("Meta-ESC Alt+Enter LF", "\x1b\n", [ Key (mk ~alt:true Enter) ]);
    ("Meta-ESC Alt+Backspace DEL", "\x1b\x7f", [ Key (mk ~alt:true Backspace) ]);
    ("Meta-ESC Alt+Backspace BS", "\x1b\x08", [ Key (mk ~alt:true Backspace) ]);
    ("Meta-ESC Alt+Tab", "\x1b\t", [ Key (mk ~alt:true Tab) ]);
    ("Meta-ESC Ctrl+Alt+a", "\x1b\x01", [ Key (mk ~ctrl:true ~alt:true (Char "a")) ]);
    ("Meta-ESC Ctrl+Alt+z", "\x1b\x1a", [ Key (mk ~ctrl:true ~alt:true (Char "z")) ]);
    ("Meta-ESC Alt+?", "\x1b?", [ Key (mk ~alt:true (Char "?")) ]);
    ("Double ESC + CSI Up", "\x1b\x1b[A", [ Key (mk Escape); Key (mk Up) ]);
    ("ESC + UTF-8 Korean", "\x1b한", [ Key (mk Escape); Key (mk (Char "한")) ]);
    (* Kitty CSI u Option chords *)
    ("Kitty Alt+[ (91;3u)", "\x1b[91;3u", [ Key (mk ~alt:true (Char "[")) ]);
    ("Kitty Alt+] (93;3u)", "\x1b[93;3u", [ Key (mk ~alt:true (Char "]")) ]);
    ("Kitty Alt+t (116;3u)", "\x1b[116;3u", [ Key (mk ~alt:true (Char "t")) ]);
    (* Default macOS Option UTF-8 characters (no Option-as-Meta) *)
    ("macOS Opt+1 ¡", "¡", [ Key (mk (Char "¡")) ]);
    ("macOS Opt+2 ™", "™", [ Key (mk (Char "™")) ]);
    ("macOS Opt+3 £", "£", [ Key (mk (Char "£")) ]);
    ("macOS Opt+4 ¢", "¢", [ Key (mk (Char "¢")) ]);
    ("macOS Opt+5 ∞", "∞", [ Key (mk (Char "∞")) ]);
    ("macOS Opt+6 §", "§", [ Key (mk (Char "§")) ]);
    ("macOS Opt+t †", "†", [ Key (mk (Char "†")) ]);
    ("macOS Opt+y ¥", "¥", [ Key (mk (Char "¥")) ]);
    ("macOS Opt+n ˜", "˜", [ Key (mk (Char "˜")) ]);
    ("macOS Opt+j ∆", "∆", [ Key (mk (Char "∆")) ]);
    ("macOS Opt+v √", "√", [ Key (mk (Char "√")) ]);
    ("macOS Opt+i ˆ", "ˆ", [ Key (mk (Char "ˆ")) ]);
    ("macOS Opt+[ “", "“", [ Key (mk (Char "“")) ]);
    ("macOS Opt+] ‘", "‘", [ Key (mk (Char "‘")) ]);
  ]

(* -------------------------------------------------------------------------- *)
(* 7. UTF-8 2–4 Byte Hangul, CJK, Emoji & Invalid Sequences                   *)
(* -------------------------------------------------------------------------- *)

let utf8_cases : (string * string * Input_decoder.event list) list =
  let open Input_decoder in
  [
    (* 2-byte UTF-8 *)
    ("UTF-8 2B é", "é", [ Key (mk (Char "é")) ]);
    ("UTF-8 2B ö", "ö", [ Key (mk (Char "ö")) ]);
    ("UTF-8 2B ñ", "ñ", [ Key (mk (Char "ñ")) ]);
    ("UTF-8 2B ß", "ß", [ Key (mk (Char "ß")) ]);
    ("UTF-8 2B Ω", "Ω", [ Key (mk (Char "Ω")) ]);
    ("UTF-8 2B Ж", "Ж", [ Key (mk (Char "Ж")) ]);
    (* 3-byte UTF-8 Hangul jamo & syllables + CJK + UI glyphs *)
    ("UTF-8 3B Hangul ㄱ", "ㄱ", [ Key (mk (Char "ㄱ")) ]);
    ("UTF-8 3B Hangul ㄲ", "ㄲ", [ Key (mk (Char "ㄲ")) ]);
    ("UTF-8 3B Hangul ㅡ (m IME)", "ㅡ", [ Key (mk (Char "ㅡ")) ]);
    ("UTF-8 3B Hangul NFD U+1173", "\xe1\x85\xb3", [ Key (mk (Char "\xe1\x85\xb3")) ]);
    ("UTF-8 3B Hangul 한", "한", [ Key (mk (Char "한")) ]);
    ("UTF-8 3B Hangul 글", "글", [ Key (mk (Char "글")) ]);
    ("UTF-8 3B Hangul 가", "가", [ Key (mk (Char "가")) ]);
    ("UTF-8 3B Hangul 힣", "힣", [ Key (mk (Char "힣")) ]);
    ("UTF-8 3B CJK 中", "中", [ Key (mk (Char "中")) ]);
    ("UTF-8 3B CJK 日", "日", [ Key (mk (Char "日")) ]);
    ("UTF-8 3B ellipsis …", "…", [ Key (mk (Char "…")) ]);
    ("UTF-8 3B spark ✦", "✦", [ Key (mk (Char "✦")) ]);
    (* 4-byte UTF-8 Emoji & SMP *)
    ("UTF-8 4B emoji 😀", "😀", [ Key (mk (Char "😀")) ]);
    ("UTF-8 4B emoji 🚀", "🚀", [ Key (mk (Char "🚀")) ]);
    ("UTF-8 4B emoji 🔥", "🔥", [ Key (mk (Char "🔥")) ]);
    ("UTF-8 4B emoji 🧪", "🧪", [ Key (mk (Char "🧪")) ]);
    ("UTF-8 4B Deseret 𐐷", "𐐷", [ Key (mk (Char "𐐷")) ]);
    (* Mixed stream *)
    ( "UTF-8 mixed Hangul+ASCII+Emoji",
      "한a🚀",
      [ Key (mk (Char "한")); Key (mk (Char "a")); Key (mk (Char "🚀")) ] );
    (* Invalid UTF-8 byte sequences *)
    ("Invalid UTF-8 lone continuation 0x80", "\x80", [ Invalid_utf8 ]);
    ("Invalid UTF-8 lone continuation 0xBF", "\xbf", [ Invalid_utf8 ]);
    ("Invalid UTF-8 overlong 0xC0 0xAF", "\xc0\xaf", [ Invalid_utf8; Invalid_utf8 ]);
    ("Invalid UTF-8 surrogate 0xED 0xA0 0x80", "\xed\xa0\x80", [ Invalid_utf8 ]);
    ("Invalid UTF-8 lead 0xF8", "\xf8", [ Invalid_utf8 ]);
    ("Invalid UTF-8 lead 0xFF", "\xff", [ Invalid_utf8 ]);
    ("Truncated 3B UTF-8 interrupted by ASCII", "\xec\x95a", [ Invalid_utf8; Key (mk (Char "a")) ]);
    ("Truncated 4B UTF-8 interrupted by CSI", "\xf0\x9f\x1b[A", [ Invalid_utf8; Key (mk Up) ]);
  ]

(* -------------------------------------------------------------------------- *)
(* 8. Bracketed Paste, SGR/X10 Mouse & Terminal Replies                       *)
(* -------------------------------------------------------------------------- *)

let paste_mouse_reply_cases : (string * string * Input_decoder.event list) list =
  let open Input_decoder in
  [
    ("Paste plain", "\x1b[200~hello\x1b[201~", [ Paste { text = "hello"; dropped_bytes = 0 } ]);
    ("Paste empty", "\x1b[200~\x1b[201~", [ Paste { text = ""; dropped_bytes = 0 } ]);
    ("Paste CRLF + CR normalization", "\x1b[200~a\r\nb\rc\x1b[201~", [ Paste { text = "a\nb\nc"; dropped_bytes = 0 } ]);
    ("Paste Hangul + emoji", "\x1b[200~한국어 🚀\x1b[201~", [ Paste { text = "한국어 🚀"; dropped_bytes = 0 } ]);
    ( "Paste partial end-marker preserved",
      "\x1b[200~hi\x1b[20x\x1b[201~",
      [ Paste { text = "hi\x1b[20x"; dropped_bytes = 0 } ] );
    ( "Paste followed immediately by key",
      "\x1b[200~abc\x1b[201~z",
      [ Paste { text = "abc"; dropped_bytes = 0 }; Key (mk (Char "z")) ] );
    ("SGR wheel up", "\x1b[<64;10;5M", [ Mouse (Wheel { dir = Wheel_up; col = 10; row = 5 }) ]);
    ("SGR wheel down", "\x1b[<65;10;5M", [ Mouse (Wheel { dir = Wheel_down; col = 10; row = 5 }) ]);
    ("SGR left press", "\x1b[<0;1;2M", [ Mouse (Left_press { col = 1; row = 2 }) ]);
    ("SGR left drag", "\x1b[<32;3;4M", [ Mouse (Left_drag { col = 3; row = 4 }) ]);
    ("SGR left release", "\x1b[<0;3;4m", [ Mouse (Left_release { col = 3; row = 4 }) ]);
    ("SGR invalid coords", "\x1b[<0;0;0M", [ Unknown_escape ]);
    ("X10 wheel up", "\x1b[M`!!", [ Mouse (Wheel { dir = Wheel_up; col = 1; row = 1 }) ]);
    ("X10 wheel down", "\x1b[Ma\"#", [ Mouse (Wheel { dir = Wheel_down; col = 2; row = 3 }) ]);
    ( "X10 left press + release",
      "\x1b[M !!\x1b[M#!!",
      [ Mouse (Left_press { col = 1; row = 1 }); Mouse (Left_release { col = 1; row = 1 }) ] );
    ("X10 left drag", "\x1b[M@%&", [ Mouse (Left_drag { col = 5; row = 6 }) ]);
    ("X10 invalid coords", "\x1b[M   ", [ Unknown_escape ]);
    ( "OSC 10 palette reply ST",
      "\x1b]10;rgb:ffff/0000/8080\x1b\\",
      [
        Reply
          (Palette_reply
             {
               slot = Palette.Foreground;
               color = Some (Palette.make_rgb ~red:255 ~green:0 ~blue:128);
             });
      ] );
    ( "OSC 11 palette reply BEL",
      "\x1b]11;rgb:0000/1010/2020\x07",
      [
        Reply
          (Palette_reply
             {
               slot = Palette.Background;
               color = Some (Palette.make_rgb ~red:0 ~green:16 ~blue:32);
             });
      ] );
    ("APC Kitty graphics reply", "\x1b_Gi=31;OK\x1b\\", [ Reply (Graphics_reply "i=31;OK") ]);
  ]

(* -------------------------------------------------------------------------- *)
(* 9. Stalled Decoder Timeout Recovery (has_pending -> false!)                *)
(* -------------------------------------------------------------------------- *)

let test_stall_timeout_recovery () =
  let open Input_decoder in
  (* Verify timeout durations are positive and properly stratified *)
  Alcotest.(check (float 0.0001)) "Prefix timeout 25ms" 0.025 (idle_timeout_s Prefix);
  Alcotest.(check (float 0.0001)) "Sequence timeout 100ms" 0.100 (idle_timeout_s Sequence);
  Alcotest.(check (float 0.0001)) "Character timeout 100ms" 0.100 (idle_timeout_s Character);
  Alcotest.(check (float 0.0001)) "Pasting timeout 5s" 5.0 (idle_timeout_s Pasting);
  Alcotest.(check (float 0.0001)) "Draining timeout 200ms" 0.200 (idle_timeout_s Draining);

  let check_recovery ~label ~seq ~expected_pending ~expected_idle =
    incr total_matrix_cases;
    let dec = create () in
    let initial_evs = feed_string dec seq in
    Alcotest.(check event_list_testable) (label ^ " initial empty") [] initial_evs;
    Alcotest.(check bool) (label ^ " pending before idle") true (has_pending dec);
    Alcotest.(check bool) (label ^ " exact pending kind") true
      (pending dec = Some expected_pending);
    let recovered = idle dec in
    Alcotest.(check event_list_testable) (label ^ " idle events") expected_idle recovered;
    Alcotest.(check bool) (label ^ " has_pending becomes false") false (has_pending dec);
    Alcotest.(check bool) (label ^ " pending becomes None") true (pending dec = None);
    (* Subsequent idle is a 0-event no-op *)
    Alcotest.(check event_list_testable) (label ^ " second idle empty") [] (idle dec);
    (* Normal keystrokes decode cleanly immediately after recovery *)
    Alcotest.(check event_list_testable)
      (label ^ " post-recovery keystroke")
      [ Key (mk (Char "x")) ]
      (feed_string dec "x");
    Alcotest.(check bool) (label ^ " stays non-pending") false (has_pending dec)
  in
  List.iter
    (fun (label, seq, expected_pending, expected_idle) ->
      check_recovery ~label ~seq ~expected_pending ~expected_idle)
    [
      ("Bare ESC prefix", "\x1b", Prefix, [ Key (mk Escape) ]);
      ("Bare SS3 prefix", "\x1bO", Prefix, [ Key (mk Escape) ]);
      ("Bare APC prefix", "\x1b_", Prefix, [ Key (mk Escape) ]);
      ("Modified SS3 truncated ESC O 2", "\x1bO2", Sequence, [ Unknown_escape ]);
      ("Modified SS3 truncated ESC O 1;", "\x1bO1;", Sequence, [ Unknown_escape ]);
      ("Modified SS3 truncated ESC O 1;5", "\x1bO1;5", Sequence, [ Unknown_escape ]);
      ("Truncated CSI ESC [", "\x1b[", Sequence, [ Unknown_escape ]);
      ("Truncated CSI ESC [ 1 ;", "\x1b[1;", Sequence, [ Unknown_escape ]);
      ("Truncated CSI Kitty ESC [ 47:63;", "\x1b[47:63;", Sequence, [ Unknown_escape ]);
      ("Truncated CSI SGR mouse", "\x1b[<64;12;", Sequence, [ Unknown_escape ]);
      ("Truncated CSI modifyOtherKeys", "\x1b[27;2;", Sequence, [ Unknown_escape ]);
      ("Truncated UTF-8 2-byte lead", "\xc3", Character, [ Invalid_utf8 ]);
      ("Truncated UTF-8 3-byte 1/3", "\xec", Character, [ Invalid_utf8 ]);
      ("Truncated UTF-8 3-byte 2/3", "\xec\x95", Character, [ Invalid_utf8 ]);
      ("Truncated UTF-8 4-byte 1/4", "\xf0", Character, [ Invalid_utf8 ]);
      ("Truncated UTF-8 4-byte 2/4", "\xf0\x9f", Character, [ Invalid_utf8 ]);
      ("Truncated UTF-8 4-byte 3/4", "\xf0\x9f\x9a", Character, [ Invalid_utf8 ]);
      ("Truncated X10 mouse 0/3", "\x1b[M", Prefix, [ Unknown_escape ]);
      ("Truncated X10 mouse 1/3", "\x1b[M ", Prefix, [ Unknown_escape ]);
      ("Truncated X10 mouse 2/3", "\x1b[M !", Prefix, [ Unknown_escape ]);
      ("Empty OSC prefix", "\x1b]", Prefix, [ Key (mk Escape) ]);
      ("Empty APC body", "\x1b_G", Prefix, [ Key (mk Escape) ]);
      ("Truncated OSC body", "\x1b]10;rgb:ffff", Sequence, []);
      ("Truncated APC body", "\x1b_Gi=1", Sequence, []);
      ( "Unterminated paste non-empty",
        "\x1b[200~hello\r\nworld",
        Pasting,
        [ Paste { text = "hello\nworld"; dropped_bytes = 0 } ] );
      ( "Unterminated paste with partial end-marker",
        "\x1b[200~hello\x1b[201",
        Pasting,
        [ Paste { text = "hello"; dropped_bytes = 0 } ] );
      ("Unterminated paste empty", "\x1b[200~", Pasting, []);
    ];

  (* Draining_paste recovers to Ground on idle *)
  incr total_matrix_cases;
  let dec_drain = create () in
  Alcotest.(check event_list_testable) "enter paste" []
    (feed_string dec_drain "\x1b[200~partial");
  (match recover_paste dec_drain with
  | Some p ->
      Alcotest.(check bool) "recovered paste text" true
        (equal_paste_event { text = "partial"; dropped_bytes = 0 } p)
  | None -> Alcotest.fail "expected Some paste from recover_paste");
  Alcotest.(check bool) "pending is Draining" true
    (pending dec_drain = Some Draining);
  Alcotest.(check event_list_testable) "idle abandons draining" [] (idle dec_drain);
  Alcotest.(check bool) "has_pending becomes false after draining idle" false
    (has_pending dec_drain);

  (* Late stray paste end marker \x1b[201~ after paste recovery does NOT leak text *)
  incr total_matrix_cases;
  let dec_late = create () in
  ignore (feed_string dec_late "\x1b[200~saved" : event list);
  ignore (idle dec_late : event list);
  Alcotest.(check event_list_testable)
    "late end marker produces Unknown_escape, never literal chars"
    [ Unknown_escape; Key (mk (Char "k")) ]
    (feed_string dec_late "\x1b[201~k");

  (* cancel_pending clears Csi, modified Ss3, and Utf8 *)
  List.iter
    (fun (label, seq) ->
      incr total_matrix_cases;
      let d = create () in
      ignore (feed_string d seq : event list);
      Alcotest.(check bool) (label ^ " pending before cancel") true (has_pending d);
      cancel_pending d;
      Alcotest.(check bool) (label ^ " cleared by cancel_pending") false (has_pending d))
    [
      ("cancel CSI", "\x1b[1;");
      ("cancel modified SS3", "\x1bO2");
      ("cancel UTF-8", "\xec\x95");
    ]

(* -------------------------------------------------------------------------- *)
(* 10. Kitty Shifted-Punctuation -> Keymap Integration & Termios Suspend Slot *)
(* -------------------------------------------------------------------------- *)

let test_keymap_and_termios_safety () =
  (* Kitty CSI u shifted '?' (47:63;2u) dispatches Open_help, NOT Focus_filter *)
  let dec = Input_decoder.create () in
  (match Input_decoder.feed_string dec "\x1b[47:63;2u" with
  | [ Input_decoder.Key kev ] -> (
      match Keymap.dispatch ~scope_chain:[ Keymap.Unfocused_nav; Keymap.Global ] kev with
      | Some Keymap.Open_help -> ()
      | Some _ | None ->
          Alcotest.fail "expected CSI 47:63;2u to dispatch Open_help, not Focus_filter")
  | _ -> Alcotest.fail "expected single Key event for CSI 47:63;2u");
  (* Plain '/' (47u) still dispatches Focus_filter *)
  (match Input_decoder.feed_string dec "\x1b[47u" with
  | [ Input_decoder.Key kev ] -> (
      match Keymap.dispatch ~scope_chain:[ Keymap.Unfocused_nav; Keymap.Global ] kev with
      | Some Keymap.Focus_filter -> ()
      | Some _ | None ->
          Alcotest.fail "expected CSI 47u to dispatch Focus_filter")
  | _ -> Alcotest.fail "expected single Key event for CSI 47u");

  (* Korean 2-bulsik IME helpers *)
  Alcotest.(check (option string)) "ㅡ -> m" (Some "m")
    (Input_decoder.Ime.single_latin_key "ㅡ");
  Alcotest.(check (option string)) "NFD U+1173 -> m" (Some "m")
    (Input_decoder.Ime.single_latin_key "\xe1\x85\xb3");
  Alcotest.(check (option string)) "composed syllable 므 -> None" None
    (Input_decoder.Ime.single_latin_key "므");

  (* Termios reclaimed keys include Suspend (VSUSP) and fail safely on non-TTY pipe *)
  let rd, wr = Unix.pipe () in
  Fun.protect
    ~finally:(fun () ->
      (match Unix.close rd with () -> () | exception Unix.Unix_error _ -> ());
      match Unix.close wr with () -> () | exception Unix.Unix_error _ -> ())
    (fun () ->
      List.iter
        (fun key ->
          Alcotest.(check int) "non-TTY key_char is -1" (-1)
            (Termios.key_char rd key);
          Alcotest.(check bool) "non-TTY disable_key is false" false
            (Termios.disable_key rd key))
        [
          Termios.Literal_next;
          Termios.Discard_output;
          Termios.Delayed_suspend;
          Termios.Suspend;
          Termios.Quit;
        ])

let test_matrix_case_floor () =
  Alcotest.(check bool)
    (Printf.sprintf "matrix exercised >= 220 cases (got %d)" !total_matrix_cases)
    true (!total_matrix_cases >= 220)

let () =
  Alcotest.run "masc_tui_v2_input_decoder_matrix"
    [
      ( "byte_matrix",
        [
          Alcotest.test_case "raw ASCII & control bytes (whole + 1-byte split)"
            `Quick (fun () -> run_matrix ascii_and_ctrl_cases);
          Alcotest.test_case "CSI arrows, tilde, modifiers & errors (whole + 1-byte split)"
            `Quick (fun () -> run_matrix csi_cases);
          Alcotest.test_case "SS3 plain, modified ESC O <mod> <final> & rxvt ESC O a..d"
            `Quick (fun () -> run_matrix ss3_cases);
          Alcotest.test_case "Kitty CSI u shifted-subparam, base layout & Ctrl/Alt shift preservation"
            `Quick (fun () -> run_matrix kitty_csi_u_cases);
          Alcotest.test_case "xterm modifyOtherKeys (whole + 1-byte split)"
            `Quick (fun () -> run_matrix modify_other_keys_cases);
          Alcotest.test_case "macOS Option (Meta-ESC, Kitty CSI u, default UTF-8)"
            `Quick (fun () -> run_matrix macos_option_cases);
          Alcotest.test_case "UTF-8 2-4 byte Hangul, CJK, emoji & invalid sequences"
            `Quick (fun () -> run_matrix utf8_cases);
          Alcotest.test_case "bracketed paste, SGR/X10 mouse & terminal replies"
            `Quick (fun () -> run_matrix paste_mouse_reply_cases);
        ] );
      ( "stall_recovery",
        [
          Alcotest.test_case "truncated CSI, SS3, UTF-8, X10, OSC, APC & unterminated paste -> has_pending=false"
            `Quick test_stall_timeout_recovery;
        ] );
      ( "integration_and_coverage",
        [
          Alcotest.test_case "Kitty shifted '?' -> Keymap.Open_help & Termios Suspend slot"
            `Quick test_keymap_and_termios_safety;
          Alcotest.test_case "matrix cardinality >= 220 byte-level cases"
            `Quick test_matrix_case_floor;
        ] );
    ]
