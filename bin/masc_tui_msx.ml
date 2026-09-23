(* The MSX spectator screen (RFC-0439 §3.7). The machine lives in the server;
   this screen draws the frame the server hands over and never owns a Z80. The
   drawing is [Masc_tui_machine_view]'s, shared with the DOS spectator; this
   module names the MSX title, footer and load menu. The render loop skips its
   own Render step while [msx_open] is set (the same way it does for
   [image_open]) and re-fetches the frame on a timer instead.

   The keyboard belongs to this screen while it is open, but a spectator only
   answers [esc]: a key never reaches the surface underneath, and this
   increment does not send keys to the server machine (that is the co-play
   step, RFC-0439 §3.3). *)

module View = Masc_tui_machine_view

let fit_line = View.fit_line

(* An empty cache has two causes and they are not the same news. The server
   answered and said no machine is loaded, or it was not reachable to be asked
   -- Masc_tui_http maps a transport failure to the same [None] a loaded:false
   answer gives. Telling an operator "no machine loaded" while the server is
   down sends them to load one, which is not the thing that is wrong.

   The connection the refresh loop already keeps is what separates them; this
   reads it rather than keeping a second account of the same fact. *)
let title_of ~(connection : Masc_tui_types.connection_status)
    (frame : Masc_tui_types.msx_frame option) =
  match frame with
  | None -> (
    match connection with
    | Masc_tui_types.Connected | Masc_tui_types.Degraded ->
      " MSX — no machine loaded. A keeper loads one with masc_msx_load."
    | (Masc_tui_types.Disconnected | Masc_tui_types.Connecting
      | Masc_tui_types.Booting | Masc_tui_types.Reconnecting) as status ->
      Printf.sprintf
        " MSX — no frame: the server is %s, so nothing could be asked for."
        (Masc_tui_types.connection_status_label status))
  | Some f ->
      let media =
        match (f.msx_cartridge, f.msx_disk) with
        | Some c, _ | None, Some c -> " · " ^ c
        | None, None -> ""
      in
      let playing =
        match f.msx_players with
        | [] -> ""
        | who -> "   조작: " ^ String.concat ", " who
      in
      Printf.sprintf " MSX — %s%s   frame %d%s   (spectating the server)" f.msx_mode
        media f.msx_number playing

let footer () =
  Printf.sprintf " Esc: back  +/-: %d%%  F6: save quick  F7: restore quick  F8: disk"
    (View.size_percent ())

(* RFC-msx-surface-focus-mode stage 1: the pixels this view draws arrive as a
   surface frame ([Masc_tui_interactive.frame]) — the renderer knows the
   contract, not [Masc_tui_types.msx_frame]'s pixel fields. The meta frame
   (mode, media, who pressed) still rides the old type; only the picture went
   through the contract. *)
let render ~(write : string -> unit)
    ~(connection : Masc_tui_types.connection_status) ?notice
    (frame : Masc_tui_types.msx_frame option)
    (surface : Masc_tui_interactive.frame option) =
  View.draw ~write ~title:(title_of ~connection frame) ?notice ~footer:(footer ())
    ~retain:(Option.is_some frame) surface
;;

let consume ~(write : string -> unit) (state : Masc_tui_types.state) key =
  if String.equal key "esc" then begin
    View.release ~write;
    state.msx_open <- false;
    false
  end
  else begin
    (* Any other key just repaints the latest frame the poll cached: a
       spectator does not drive the machine. *)
    render ~write ?notice:state.msx_notice ~connection:state.Masc_tui_types.connection_status
      state.msx_frame (View.last_surface ());
    true
  end

(* --- The load menu (RFC-0439 §3.7) ------------------------------------- *)

(* What a chosen row does. The keyboard I/O it implies -- fetching the
   inventory, POSTing the load -- is the executable layer's, the only one that
   can reach [Masc_tui_http]. This module draws the picker and names the
   choice; it never flips [msx_menu_open]/[msx_open] itself, so the lifecycle
   stays in one place. *)
type menu_action =
  | Stay              (* navigated or repainted; the menu is still up *)
  | Closed            (* esc: leave the menu *)
  | Watch             (* spectate the machine already loaded *)
  | Swap_disk of string
  | Load of string    (* plug this cartridge in *)

(* The rows in order: a "watch current" row first when a machine is loaded,
   then one row per cartridge. [msx_menu_index] indexes this list. *)
let menu_entries (state : Masc_tui_types.state) : menu_action list =
  let watch = if Option.is_some state.msx_frame then [ Watch ] else [] in
  let media = match state.msx_menu_mode with
    | Masc_tui_types.Boot_game -> List.map (fun c -> Load c) state.msx_carts
    | Change_disk -> state.msx_carts
        |> List.filter (fun c -> String.ends_with ~suffix:".dsk" (String.lowercase_ascii c))
        |> List.map (fun c -> Swap_disk c) in
  watch @ media

let clamp_index (state : Masc_tui_types.state) =
  let n = List.length (menu_entries state) in
  state.msx_menu_index <- (if n = 0 then 0 else max 0 (min (n - 1) state.msx_menu_index))

let menu_title = " MSX \xe2\x80\x94 pick a game"

(* The menu's keys, on its bottom row, in the [key:action] form every other
   screen's footer uses. They were a sentence inside the title instead, spelled
   two ways for one screen -- "(up/down move, enter load, esc back)" on the game
   menu and "Enter selects, Esc cancels" on the disk menu -- and neither said
   that [j] and [k] move as well. A menu with nothing in it names only the way
   out: moving and choosing do nothing there. *)
let menu_hints (mode : Masc_tui_types.msx_menu_mode) ~has_entries =
  let choose, leave = match mode with
    | Boot_game -> "Enter:load", "Esc:back"
    | Change_disk -> "Enter:swap disk", "Esc:cancel"
  in
  if has_entries then String.concat "  " [ "j/k:move"; choose; leave ] else leave

let entry_label (state : Masc_tui_types.state) = function
  | Watch ->
      let cart =
        match state.msx_frame with
        | Some { msx_cartridge = Some c; _ } -> c
        | Some { msx_disk = Some d; _ } -> d
        | _ -> "current machine"
      in
      "> watch " ^ cart
  | Load c | Swap_disk c -> "  " ^ c
  | Stay | Closed -> ""

let render_menu ~(write : string -> unit) ?status (state : Masc_tui_types.state) =
  clamp_index state;
  let rows, cols = Masc_tui_ansi.get_terminal_size () in
  let entries = menu_entries state in
  View.draw_text_screen ~write @@ fun buf ->
  Buffer.add_string buf (fit_line cols (match state.msx_menu_mode with
    | Masc_tui_types.Boot_game -> menu_title
    | Change_disk -> " MSX — change disk (no reboot)"));
  Buffer.add_string buf "\027[0K\r\n";
  let status_rows =
    match status with
    | Some s ->
        Buffer.add_string buf (fit_line cols (" " ^ s));
        Buffer.add_string buf "\027[0K\r\n";
        1
    | None -> 0
  in
  (match entries with
   | [] ->
       Buffer.add_string buf
         (fit_line cols
            " no cartridges yet \xe2\x80\x94 an operator fills .masc/msx/carts/ with ROM or .dsk images");
       Buffer.add_string buf "\027[0K\r\n"
   | _ ->
       List.iteri
         (fun i entry ->
           let label = entry_label state entry in
           let line =
             if i = state.msx_menu_index then
               "\027[7m" ^ fit_line (max 1 (cols - 1)) (" " ^ label) ^ "\027[0m"
             else fit_line cols (" " ^ label)
           in
           Buffer.add_string buf line;
           Buffer.add_string buf "\027[0K\r\n")
         entries);
  (* Pad the body so a previously longer list leaves no ghost rows behind, put
     the keys on the bottom row, and write no newline there. A newline written
     on the last row scrolls the screen by one, and the row that scrolls off is
     the first -- the title. Measured at 150x44 with no cartridges: the screen
     held two lines, the sentence about the empty directory and a blank, and
     nothing said how to leave. *)
  let drawn = 1 + status_rows + max 1 (List.length entries) in
  let last_row = max 4 (rows - 1) in
  for row = drawn to last_row do
    if row = last_row then
      Buffer.add_string buf
        ("\027[2m"
         ^ fit_line cols
             (" " ^ menu_hints state.msx_menu_mode ~has_entries:(entries <> []))
         ^ "\027[0m");
    Buffer.add_string buf "\027[0K";
    if row < last_row then Buffer.add_string buf "\r\n"
  done

let open_menu ~(write : string -> unit) ?(mode = Masc_tui_types.Boot_game) (state : Masc_tui_types.state) =
  state.msx_menu_mode <- mode;
  state.msx_open <- true;
  state.msx_menu_open <- true;
  state.msx_menu_index <- 0;
  render_menu ~write state

let menu_consume ~(write : string -> unit) (state : Masc_tui_types.state) key :
    menu_action =
  match key with
  | "esc" -> Closed
  | "up" | "k" ->
      state.msx_menu_index <- state.msx_menu_index - 1;
      render_menu ~write state;
      Stay
  | "down" | "j" ->
      state.msx_menu_index <- state.msx_menu_index + 1;
      render_menu ~write state;
      Stay
  | "\r" | "\n" | "enter" | "return" | " " | "space" -> (
      match List.nth_opt (menu_entries state) state.msx_menu_index with
      | Some ((Watch | Load _ | Swap_disk _) as a) -> a
      | Some (Stay | Closed) | None ->
          render_menu ~write state;
          Stay)
  | _ ->
      render_menu ~write state;
      Stay
