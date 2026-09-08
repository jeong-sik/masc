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
let graphics_protocol = ref Masc_tui_graphics.Unsupported_protocol

let set_graphics_protocol p = graphics_protocol := p

let fit_line width s = String.sub s 0 (min (String.length s) (max width 1))

let title_of (frame : Masc_tui_types.msx_frame option) =
  match frame with
  | None -> " MSX — no machine loaded. A keeper loads one with masc_msx_load."
  | Some f ->
      let cart = match f.msx_cartridge with Some c -> " · " ^ c | None -> "" in
      Printf.sprintf " MSX — %s%s   frame %d   (spectating the server)" f.msx_mode cart
        f.msx_number

let footer = " esc: back   (keeper plays; this is a live view)"

let render ~(write : string -> unit) (frame : Masc_tui_types.msx_frame option) =
  let rows, cols = Masc_tui_ansi.get_terminal_size () in
  let screen_rows = max 4 (rows - 2) in
  let buf = Buffer.create (cols * 24 * screen_rows) in
  Buffer.add_string buf "\027[2J\027[H";
  Buffer.add_string buf (fit_line cols (title_of frame));
  Buffer.add_string buf "\027[0K\r\n";
  let blank_row () = Buffer.add_string buf "\027[0K\r\n" in
  (match frame with
   | Some f
     when String.length f.msx_rgb = f.msx_width * f.msx_height * 3
          && (match !graphics_protocol with
              | Masc_tui_graphics.Kitty_protocol -> true
              | Masc_tui_graphics.ITerm2_protocol
              | Masc_tui_graphics.Unsupported_protocol -> false) ->
       (* A terminal that draws images gets the frame's own pixels. The mosaic
          below is a good picture of a frame and still throws most of it away:
          a character cell can carry two colours, so at 150 columns the whole
          256x192 screen arrives as about 8,500 of its 49,152 pixels, and no
          finer block character raises that -- more subdivisions per cell do
          not add colours to the cell. Handing the pixels over is the only
          step that does.

          Raw RGB rather than PNG: the frame is already three bytes per pixel
          in exactly the layout [place_rgb] wants, and masc has no PNG
          encoder. The length test above is [=] rather than [>=] because
          [place_rgb] refuses a frame that disagrees with its dimensions, and
          a refusal here would clear the screen and draw nothing.

          iTerm2 is left on the mosaic: its protocol carries a file, not a
          pixel buffer, so it needs the encoder this path avoids. *)
       let box =
         { Masc_tui_graphics.columns = max 1 cols; rows = max 1 screen_rows }
       in
       let escape =
         Masc_tui_graphics.place_rgb ~data:f.msx_rgb ~pixel_width:f.msx_width
           ~pixel_height:f.msx_height box
       in
       if String.equal escape "" then for _ = 1 to screen_rows do blank_row () done
       else begin
         Buffer.add_string buf escape;
         (* The image is drawn at the cursor and the terminal does not move it,
            so the footer needs the rows stepped over by hand. *)
         Buffer.add_string buf (Printf.sprintf "\027[%d;1H" (screen_rows + 2))
       end
   | Some f when String.length f.msx_rgb >= f.msx_width * f.msx_height * 3 ->
       (* The machine's frame has a shape of its own -- 256x192 from the
          server's screen -- and the terminal has another. Fitting the grid to
          the terminal alone drew that shape stretched to whatever the window
          happened to be. The grid keeps the frame's ratio and the leftover
          rows and columns stay blank, so the picture is the picture. *)
       let pcols, prows =
         Frame.fit_grid ~src_w:f.msx_width ~src_h:f.msx_height ~max_cols:cols
           ~max_rows:(2 * screen_rows)
       in
       let lines =
         Frame.render ~cols:pcols ~rows:prows
           (Frame.downscale ~src_w:f.msx_width ~src_h:f.msx_height ~cols:pcols
              ~rows:prows f.msx_rgb)
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
  Buffer.add_string buf (fit_line cols footer);
  Buffer.add_string buf "\027[0K";
  write (Buffer.contents buf)

let consume ~(write : string -> unit) (state : Masc_tui_types.state) key =
  if String.equal key "esc" then begin
    state.msx_open <- false;
    false
  end
  else begin
    (* Any other key just repaints the latest frame the poll cached: a
       spectator does not drive the machine. *)
    render ~write state.msx_frame;
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
  | Load of string    (* plug this cartridge in *)

(* The rows in order: a "watch current" row first when a machine is loaded,
   then one row per cartridge. [msx_menu_index] indexes this list. *)
let menu_entries (state : Masc_tui_types.state) : menu_action list =
  let watch = if Option.is_some state.msx_frame then [ Watch ] else [] in
  watch @ List.map (fun c -> Load c) state.msx_carts

let clamp_index (state : Masc_tui_types.state) =
  let n = List.length (menu_entries state) in
  state.msx_menu_index <- (if n = 0 then 0 else max 0 (min (n - 1) state.msx_menu_index))

let menu_title = " MSX \xe2\x80\x94 pick a game   (up/down move, enter load, esc back)"

let entry_label (state : Masc_tui_types.state) = function
  | Watch ->
      let cart =
        match state.msx_frame with
        | Some { msx_cartridge = Some c; _ } -> c
        | _ -> "current machine"
      in
      "> watch " ^ cart
  | Load c -> "  " ^ c
  | Stay | Closed -> ""

let render_menu ~(write : string -> unit) ?status (state : Masc_tui_types.state) =
  clamp_index state;
  let rows, cols = Masc_tui_ansi.get_terminal_size () in
  let entries = menu_entries state in
  let buf = Buffer.create 1024 in
  Buffer.add_string buf "\027[2J\027[H";
  Buffer.add_string buf (fit_line cols menu_title);
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
            " no cartridges yet \xe2\x80\x94 an operator fills .masc/msx/carts/ with ROM images");
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
  (* Pad the body so a previously longer list leaves no ghost rows behind. *)
  let drawn = 1 + status_rows + max 1 (List.length entries) in
  for _ = drawn to max 4 (rows - 1) do
    Buffer.add_string buf "\027[0K\r\n"
  done;
  write (Buffer.contents buf)

let open_menu ~(write : string -> unit) (state : Masc_tui_types.state) =
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
  | "\r" | "\n" | " " | "space" -> (
      match List.nth_opt (menu_entries state) state.msx_menu_index with
      | Some ((Watch | Load _) as a) -> a
      | Some (Stay | Closed) | None ->
          render_menu ~write state;
          Stay)
  | _ ->
      render_menu ~write state;
      Stay
