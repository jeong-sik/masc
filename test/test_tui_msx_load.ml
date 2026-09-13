(* The MSX screen (RFC-0439 §3.7). The machine lives in the server; this screen
   renders the frame it is handed and, before a game is loaded, lets the human
   pick one from the cartridge inventory. What is pinned here, all pure (no
   HTTP): the spectator draws an empty frame as "no machine" and a real frame as
   a body; esc closes the spectator; the load menu lists the inventory (plus a
   "watch" row when a game is loaded), moves the highlight, and names the chosen
   row so the executable can do the load. *)

open Alcotest

let a_frame ?(cartridge = Some "xspelunker") ?(disk = None) () :
    Masc_tui_types.msx_frame =
  { msx_number = 345
  ; msx_width = 256
  ; msx_height = 192
  ; msx_rgb = String.make (256 * 192 * 3) '\128'
  ; msx_mode = "GRAPHIC2"
  ; msx_cartridge = cartridge
  ; msx_disk = disk
  ; msx_players = []
  }

let a_state () =
  Masc_tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()

(* Stage 1: the picture rides the surface contract; the fixture's pixel
   fields feed it, so the drawing assertions are unchanged. *)
let a_surface (f : Masc_tui_types.msx_frame) : Masc_tui_interactive.frame =
  Masc_tui_interactive.Pixels
    { width = f.msx_width; height = f.msx_height; rgb = f.msx_rgb }

(* The annotation is the point. Without it [render] is inferred from a use
   that drops its result as a statement, so an incomplete application -- a
   render missing one of its labelled arguments -- type-checks, returns the
   function that still wants it, and is discarded. The buffer then stays empty
   and every assertion about the output reads it as absent output. That is what
   happened when render gained ~connection in #34262. *)
let captured (render : (string -> unit) -> unit) =
  let buf = Buffer.create 4096 in
  render (fun text -> Buffer.add_string buf text);
  Buffer.contents buf

let contains hay needle =
  let n = String.length needle and m = String.length hay in
  let rec at i j = j = n || (hay.[i + j] = needle.[j] && at i (j + 1)) in
  let rec go i = i + n <= m && (at i 0 || go (i + 1)) in
  n = 0 || go 0

(* The bottom row: nothing is written after it, so it is what follows the
   last newline. *)
let after_last_newline out =
  match String.rindex_opt out '\n' with
  | None -> out
  | Some i -> String.sub out (i + 1) (String.length out - i - 1)

(* --- The spectator ---------------------------------------------------- *)

let test_empty_frame () =
  let out = captured (fun write ->
        Masc_tui_msx.render ~write ~connection:Masc_tui_types.Connected None None) in
  check bool "an empty frame says no machine is loaded" true
    (contains out "no machine loaded");
  check bool "and writes something" true (String.length out > 0)

let test_real_frame () =
  let out = captured (fun write ->
      Masc_tui_msx.render ~write ~connection:Masc_tui_types.Connected
        (Some (a_frame ())) (Some (a_surface (a_frame ())))) in
  check bool "a real frame names the mode" true (contains out "GRAPHIC2");
  check bool "and the cartridge" true (contains out "xspelunker");
  check bool "and the frame number" true (contains out "345");
  check bool "and draws a body (many rows)" true (String.length out > 2000)

let test_spectator_close () =
  let state = a_state () in
  state.msx_open <- true;
  state.msx_frame <- Some (a_frame ());
  let write _ = () in
  check bool "a non-esc key keeps the spectator open" true
    (Masc_tui_msx.consume ~write state "space");
  check bool "esc closes and returns false" false
    (Masc_tui_msx.consume ~write state "esc");
  check bool "the flag is cleared" false state.msx_open

(* --- The load menu ---------------------------------------------------- *)

let is_load name = function Masc_tui_msx.Load n -> String.equal n name | _ -> false

let test_menu_lists_inventory () =
  let state = a_state () in
  state.msx_frame <- None;
  state.msx_carts <- [ "dig-dug.rom"; "pac-man.rom" ];
  let out = captured (fun write -> Masc_tui_msx.open_menu ~write state) in
  check bool "opening sets the screen flag" true state.msx_open;
  check bool "and the menu flag" true state.msx_menu_open;
  check bool "the menu names itself" true (contains out "pick a game");
  check bool "the title no longer spells the keys" false (contains out "esc back");
  check bool "the bottom row names them the footer way" true
    (contains (after_last_newline out) "j/k:move  Enter:load  Esc:back");
  check bool "and lists the first cartridge" true (contains out "dig-dug.rom");
  check bool "and the second" true (contains out "pac-man.rom")

let test_menu_watch_row_when_loaded () =
  let state = a_state () in
  state.msx_frame <- Some (a_frame ());
  state.msx_carts <- [ "dig-dug.rom" ];
  let write _ = () in
  Masc_tui_msx.open_menu ~write state;
  (* A machine is loaded, so row 0 is "watch" and enter spectates it. *)
  check bool "row 0 is watch" true
    (match Masc_tui_msx.menu_consume ~write state "\r" with
     | Masc_tui_msx.Watch -> true
     | _ -> false);
  (* Row 1 is the one cartridge. *)
  state.msx_menu_index <- 1;
  check bool "row 1 loads the cartridge" true
    (is_load "dig-dug.rom" (Masc_tui_msx.menu_consume ~write state "\r"))

let test_menu_navigation_and_select () =
  let state = a_state () in
  state.msx_frame <- None;
  state.msx_carts <- [ "a.rom"; "b.rom"; "c.rom" ];
  let write _ = () in
  Masc_tui_msx.open_menu ~write state;
  check int "selection starts at the top" 0 state.msx_menu_index;
  ignore (Masc_tui_msx.menu_consume ~write state "down");
  ignore (Masc_tui_msx.menu_consume ~write state "down");
  check int "two downs move to row 2" 2 state.msx_menu_index;
  ignore (Masc_tui_msx.menu_consume ~write state "down");
  check int "down at the bottom stays clamped" 2 state.msx_menu_index;
  ignore (Masc_tui_msx.menu_consume ~write state "up");
  check int "up moves back to row 1" 1 state.msx_menu_index;
  check bool "enter loads the highlighted cartridge" true
    (is_load "b.rom" (Masc_tui_msx.menu_consume ~write state "\r"))

let test_menu_esc_closes () =
  let state = a_state () in
  state.msx_frame <- None;
  state.msx_carts <- [ "a.rom" ];
  let write _ = () in
  Masc_tui_msx.open_menu ~write state;
  check bool "esc reports Closed" true
    (match Masc_tui_msx.menu_consume ~write state "esc" with
     | Masc_tui_msx.Closed -> true
     | _ -> false)

let test_menu_empty_inventory () =
  let state = a_state () in
  state.msx_frame <- None;
  state.msx_carts <- [];
  let out = captured (fun write -> Masc_tui_msx.open_menu ~write state) in
  check bool "an empty inventory tells the operator where to put ROMs" true
    (contains out "carts");
  check bool "and offers only the way out" true
    (contains (after_last_newline out) "Esc:back"
     && not (contains (after_last_newline out) "Enter:load"));
  let write _ = () in
  check bool "enter with nothing to pick just stays" true
    (match Masc_tui_msx.menu_consume ~write state "\r" with
     | Masc_tui_msx.Stay -> true
     | _ -> false)

let test_change_disk_menu () =
  let state = a_state () in
  state.msx_frame <- Some { (a_frame ()) with msx_cartridge = None; msx_disk = Some "A.dsk" };
  state.msx_carts <- ["cart.rom"; "A.dsk"; "B.DSK"];
  let out = captured (fun write -> Masc_tui_msx.open_menu ~write ~mode:Masc_tui_types.Change_disk state) in
  check bool "menu identifies disk replacement" true (contains out "change disk");
  check bool "and names its own keys on the bottom row" true
    (contains (after_last_newline out) "Enter:swap disk  Esc:cancel");
  check bool "cartridges excluded from replacement menu" false (contains out "cart.rom");
  check bool "uppercase disk extension accepted" true (contains out "B.DSK");
  let write _ = () in
  ignore (Masc_tui_msx.menu_consume ~write state "down" : Masc_tui_msx.menu_action);
  check bool "Kitty enter selects a swap, not reboot load" true
    (match Masc_tui_msx.menu_consume ~write state "enter" with Swap_disk "A.dsk" -> true | _ -> false);
  check bool "escape cancels replacement" true
    (Masc_tui_msx.menu_consume ~write state "esc" = Masc_tui_msx.Closed);
  ignore (captured (fun write -> Masc_tui_msx.open_menu ~write state));
  check bool "ordinary opening resets picker to game loading" true (state.msx_menu_mode = Masc_tui_types.Boot_game)

let () =
  run "MSX screen"
    [ ( "spectator"
      , [ test_case "empty frame" `Quick test_empty_frame
        ; test_case "real frame" `Quick test_real_frame
        ; test_case "close on esc" `Quick test_spectator_close
        ] )
    ; ( "load menu"
      , [ test_case "disk replacement menu" `Quick test_change_disk_menu
        ; test_case "lists the inventory" `Quick test_menu_lists_inventory
        ; test_case "watch row when loaded" `Quick test_menu_watch_row_when_loaded
        ; test_case "navigation and select" `Quick test_menu_navigation_and_select
        ; test_case "esc closes" `Quick test_menu_esc_closes
        ; test_case "empty inventory" `Quick test_menu_empty_inventory
        ] )
    ]
