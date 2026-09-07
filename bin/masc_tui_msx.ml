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

let fit_line width s = String.sub s 0 (min (String.length s) (max width 1))

(* Box-average shrink of the native frame onto the [pcols x prows] grid the
   mosaic wants (two pixel rows per character cell): each destination cell is
   the mean of the source rectangle it covers.

   This was nearest-neighbour, chosen for hard pixel-art edges. At the sizes
   the screen actually runs it drops the art instead of sharpening it: a 150-
   column terminal maps 1.7 source pixels per cell across and 2.4 down, so a
   sample lands between the strokes of the MSX's 8x8 font and the glyph is
   gone. Measured on a live pac-man.rom frame at 150x80: the source has 11% of
   its pixels lit, nearest keeps 11% of the grid lit but not the same ones --
   whole strokes vanish -- while the average keeps 23% and every stroke leaves
   a mark. Averaging is also what makes a half-lit cell dim rather than
   absent, which is the difference between a readable glyph and a gap. *)
let mosaic_of ~pcols ~prows ~w ~h (rgb : string) =
  let grid = Bytes.create (pcols * prows * 3) in
  let clamp_hi v hi = if v > hi then hi else v in
  for py = 0 to prows - 1 do
    let y0 = py * h / prows in
    let y1 = clamp_hi (max (y0 + 1) ((py + 1) * h / prows)) h in
    for px = 0 to pcols - 1 do
      let x0 = px * w / pcols in
      let x1 = clamp_hi (max (x0 + 1) ((px + 1) * w / pcols)) w in
      let r = ref 0 and g = ref 0 and b = ref 0 and n = ref 0 in
      for y = y0 to y1 - 1 do
        for x = x0 to x1 - 1 do
          let src = ((y * w) + x) * 3 in
          if src + 2 < String.length rgb then begin
            r := !r + Char.code rgb.[src];
            g := !g + Char.code rgb.[src + 1];
            b := !b + Char.code rgb.[src + 2];
            incr n
          end
        done
      done;
      let dst = ((py * pcols) + px) * 3 in
      if !n > 0 then begin
        Bytes.set grid dst (Char.chr (!r / !n));
        Bytes.set grid (dst + 1) (Char.chr (!g / !n));
        Bytes.set grid (dst + 2) (Char.chr (!b / !n))
      end
    done
  done;
  Bytes.to_string grid

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
  (* Keep the machine's own shape. A terminal cell is about twice as tall as
     it is wide and the half-block splits it in two, so one mosaic pixel is
     roughly square and [pcols : prows] can carry the frame's own ratio
     directly. Filling the terminal instead -- which is what taking every
     available row did -- squashed a 256x192 frame to 0.6 of its height at
     wide sizes, and squashing is what turns an 8x8 glyph into a smear. Fit
     to whichever axis binds, and keep [prows] even because the mosaic pairs
     rows. *)
  let native_w = 256 and native_h = 192 in
  let avail_rows = 2 * screen_rows in
  let pcols, prows =
    let by_width = min cols native_w in
    let rows_at_width = by_width * native_h / native_w in
    if rows_at_width <= avail_rows
    then by_width, rows_at_width
    else (
      let pr = avail_rows in
      pr * native_w / native_h, pr)
  in
  let prows = prows - (prows land 1) in
  let prows = max 2 prows in
  let pcols = max 1 pcols in
  (* Centre what is narrower than the terminal; a frame pinned left reads as
     a window that failed to fill rather than a screen with margins. *)
  let left_pad = String.make (max 0 ((cols - pcols) / 2)) ' ' in
  let buf = Buffer.create (pcols * 24 * screen_rows) in
  Buffer.add_string buf "\027[2J\027[H";
  Buffer.add_string buf (fit_line cols (title_of frame));
  Buffer.add_string buf "\027[0K\r\n";
  (match frame with
   | Some f when String.length f.msx_rgb >= f.msx_width * f.msx_height * 3 ->
       List.iter
         (fun line ->
           Buffer.add_string buf left_pad;
           Buffer.add_string buf line;
           Buffer.add_string buf "\027[0K\r\n")
         (Frame.render ~cols:pcols ~rows:prows
            (mosaic_of ~pcols ~prows ~w:f.msx_width ~h:f.msx_height f.msx_rgb))
   | Some _ | None ->
       (* Nothing to draw: clear the body so a stale frame does not linger. *)
       for _ = 1 to screen_rows do
         Buffer.add_string buf "\027[0K\r\n"
       done);
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
