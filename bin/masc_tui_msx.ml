(* The MSX spectator screen (RFC-0439 §3.7). The machine lives in the server;
   this screen draws the frame the server hands over and never owns a Z80. The
   drawing half mirrors what [open_image] does for a picture: write the whole
   screen directly, because the retained frame underneath would otherwise
   repaint rows over it. The render loop skips its own Render step while
   [msx_open] is set (the same way it does for [image_open]) and re-fetches the
   frame on a timer instead.

   The keyboard belongs to this screen while it is open, but a spectator only
   answers [esc]: a key never reaches the surface underneath, and this
   increment does not send keys to the server machine (that is the co-play
   step, RFC-0439 §3.3). *)

module Frame = Masc_tui_image_mosaic

(* Which image protocol this terminal speaks, as the boot probe found it. The
   value is owned by the executable -- the probe runs there and every other
   image surface reads it from the same place -- and set here once so the
   spectator does not need it threaded through [render], [open_screen] and
   [consume] as a parameter each. Unsupported until told otherwise, so a
   terminal that never answered draws the mosaic. *)
(* Owned only by the serialized TUI loop. Commit after a successful write;
   a failed or interrupted write must force the next frame to repaint. *)
type retained_frame = {
  geometry : int * int * int * int * (int * int) option;
  pixels : Masc_tui_interactive.frame option;
}
let retained : retained_frame option ref = ref None
let invalidate () = retained := None
let image_may_exist = ref false
let image_id = 32
let placement_id = 1
let synchronized_output = ref false
let set_synchronized_output enabled = synchronized_output := enabled
let delete_image = Masc_tui_graphics.delete_image ~image_id
let write_batch ~write payload =
  if !synchronized_output then write ("\027[?2026h" ^ payload ^ "\027[?2026l")
  else write payload

let graphics_protocol = ref Masc_tui_graphics.Unsupported_protocol

let set_graphics_protocol p =
  invalidate ();
  graphics_protocol := p

(* What the terminal said one character cell measures, or [None] where it did
   not answer. Only the image path reads it: the mosaic already works in cells
   and needs no pixels. *)
let cell_pixels = ref None
let set_cell_pixels px = cell_pixels := px

(* Rows for an image placement that keeps the frame inside the screen.

   Kitty derives the width from the row count, so a row count that fills the
   height can put the width past the right edge, where it is cut. The height
   that fits both is the smaller of the height available and the height the
   available width allows at the frame's own shape; the row count is that
   height in whole cells, rounded down so the last row is not a partial one.

   Without a cell size there is nothing to compute with, and the caller keeps
   the rows it asked for. *)
let rows_that_fit ~cols ~rows ~frame_width ~frame_height =
  match !cell_pixels with
  | Some (cell_width, cell_height)
    when cell_width > 0 && cell_height > 0 && frame_width > 0 && frame_height > 0 ->
      let available_width = cols * cell_width in
      let available_height = rows * cell_height in
      let height_the_width_allows = available_width * frame_height / frame_width in
      let height = min available_height height_the_width_allows in
      max 1 (min rows (height / cell_height))
  | Some _ | None -> rows

let fit_line width s = String.sub s 0 (min (String.length s) (max width 1))

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

(* How much of the terminal the picture takes: 1.0 fills the screen, and
   the size keys step it in eighths between a quarter and full. A local
   view choice -- the machine and its frame are the server's; this only
   says how big this terminal draws them. *)
let screen_fraction = ref 1.0

let step_fraction d =
  let eighths = Float.round (!screen_fraction *. 8.0) +. d in
  screen_fraction := Float.min 8.0 (Float.max 2.0 eighths) /. 8.0

(* One step by the size keys: [+1.0] grows, [-1.0] shrinks, an eighth of the
   screen each way. Called by the key loop, which owns every key the spectator
   sees -- this module's [consume] answers [esc] only, the rest go to the
   machine (RFC-0439 3.3), and the size keys are intercepted before that. *)
let adjust_size d = step_fraction d

let footer () =
  Printf.sprintf " Esc: back  +/-: %d%%  F6: save quick  F7: restore quick  F8: disk"
    (int_of_float (!screen_fraction *. 100.0))

(* RFC-msx-surface-focus-mode stage 1: the pixels this view draws arrive as a
   surface frame ([Masc_tui_interactive.frame]) — the renderer knows the
   contract, not [Masc_tui_types.msx_frame]'s pixel fields. The meta frame
   (mode, media, who pressed) still rides the old type; only the picture went
   through the contract. *)
let render ~(write : string -> unit)
    ~(connection : Masc_tui_types.connection_status) ?notice
    (frame : Masc_tui_types.msx_frame option)
    (surface : Masc_tui_interactive.frame option) =
  let dims =
    match surface with
    | Some (Pixels { width; height; rgb }) -> Some (width, height, rgb)
    | None -> None
  in
  let rows, cols = Masc_tui_ansi.get_terminal_size () in
  let header_rows = if Option.is_some notice then 2 else 1 in
  let screen_rows = max 4 (rows - header_rows - 1) in
  let picture_rows =
    max 2 ((screen_rows * int_of_float (Float.round (!screen_fraction *. 8.0))) / 8)
  in
  let geometry = (rows, cols, header_rows, picture_rows, !cell_pixels) in
  let kitty = match dims, !graphics_protocol with
    | Some (width, height, rgb), Masc_tui_graphics.Kitty_protocol ->
        width > 0 && height > 0 && String.length rgb = width * height * 3
    | _ -> false
  in
  let previous = !retained in
  (* Invalidate before output so even a partially written batch cannot be
     mistaken for an accepted frame on the next call. *)
  invalidate ();
  let same_layout = match previous, dims with
    | Some old, Some (width, height, _) when kitty ->
        old.geometry = geometry
        && (match old.pixels with
            | Some (Pixels p) -> p.width = width && p.height = height
            | _ -> false)
    | _ -> false
  in
  let same_pixels = match previous, dims with
    | Some old, Some (_, _, rgb) when same_layout ->
        (match old.pixels with
         | Some (Pixels p) -> String.equal p.rgb rgb
         | _ -> false)
    | _ -> false
  in
  let buf = Buffer.create 1024 in
  if same_layout then Buffer.add_string buf "\027[H"
  else begin
    if kitty || !image_may_exist then Buffer.add_string buf delete_image;
    Buffer.add_string buf "\027[2J\027[H"
  end;
  Buffer.add_string buf (fit_line cols (title_of ~connection frame));
  Buffer.add_string buf "\027[0K\r\n";
  Option.iter (fun message -> Buffer.add_string buf (fit_line cols (" " ^ message)); Buffer.add_string buf "\027[0K\r\n") notice;
  let blank_row () = Buffer.add_string buf "\027[0K\r\n" in
  (match dims with
   | Some (width, height, rgb) when kitty ->
       (* Keep full RGB detail. Stable image and placement IDs replace the
          previous picture; unchanged pixels need no encoding or transfer. *)
       let drawn_rows =
         rows_that_fit ~cols ~rows:picture_rows ~frame_width:width
           ~frame_height:height
       in
       (* The image is drawn where the cursor sits, so a smaller picture
          starts mid-screen: park the cursor on its first row, centred, and
          the footer still lands on the screen's last row. *)
       Buffer.add_string buf
         (Printf.sprintf "\027[%d;1H" (header_rows + 1 + ((screen_rows - drawn_rows) / 2)));
       let escape =
         if same_pixels then "" else
         Masc_tui_graphics.replace_rgb ~image_id ~placement_id ~data:rgb ~pixel_width:width
           ~pixel_height:height ~rows:drawn_rows
       in
       Buffer.add_string buf escape;
       Buffer.add_string buf (Printf.sprintf "\027[%d;1H" (header_rows + screen_rows + 1))
   | Some (width, height, rgb)
     when width > 0 && height > 0 && String.length rgb >= width * height * 3 ->
       (* The machine's frame has a shape of its own -- 256x192 from the
          server's screen -- and the terminal has another. Fitting the grid to
          the terminal alone drew that shape stretched to whatever the window
          happened to be. The grid keeps the frame's ratio and the leftover
          rows and columns stay blank, so the picture is the picture. *)
       let pcols, prows =
         Frame.fit_grid ~src_w:width ~src_h:height ~max_cols:cols
           ~max_rows:(2 * picture_rows)
       in
       let lines =
         Frame.render ~cols:pcols ~rows:prows
           (Frame.downscale ~src_w:width ~src_h:height ~cols:pcols
              ~rows:prows rgb)
       in
       let drawn = List.length lines in
       let above = (screen_rows - drawn) / 2 in
       let left = String.make ((cols - pcols) / 2) ' ' in
       for _ = 1 to above do blank_row () done;
       List.iter
         (fun line ->
           Buffer.add_string buf left;
           Buffer.add_string buf line;
           blank_row ())
         lines;
       for _ = 1 to screen_rows - drawn - above do blank_row () done
   | Some _ | None ->
       (* Nothing to draw: clear the body so a stale frame does not linger. *)
       for _ = 1 to screen_rows do blank_row () done);
  Buffer.add_string buf (fit_line cols (footer ()));
  Buffer.add_string buf "\027[0K";
  image_may_exist := !image_may_exist || kitty;
  write_batch ~write (Buffer.contents buf);
  image_may_exist := kitty;
  (* Always retained, not just Kitty: [consume]'s repaint redraws the last
     surface frame, and the mosaic path needs it too. *)
  Option.iter (fun _frame -> retained := Some { geometry; pixels = surface }) frame
;;

(* The last surface a render drew — consume's repaint redraws it. *)
let last_surface () =
  match !retained with Some r -> r.pixels | None -> None
;;

let consume ~(write : string -> unit) (state : Masc_tui_types.state) key =
  if String.equal key "esc" then begin
    invalidate ();
    if !image_may_exist then write_batch ~write delete_image;
    image_may_exist := false;
    state.msx_open <- false;
    false
  end
  else begin
    (* Any other key just repaints the latest frame the poll cached: a
       spectator does not drive the machine. *)
    render ~write ?notice:state.msx_notice ~connection:state.Masc_tui_types.connection_status
      state.msx_frame (last_surface ());
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
  invalidate ();
  clamp_index state;
  let rows, cols = Masc_tui_ansi.get_terminal_size () in
  let entries = menu_entries state in
  let buf = Buffer.create 1024 in
  if !image_may_exist then Buffer.add_string buf delete_image;
  Buffer.add_string buf "\027[2J\027[H";
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
  done;
  write_batch ~write (Buffer.contents buf);
  image_may_exist := false

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
