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

(* Nearest-neighbour shrink of the native frame onto the [pcols x prows] grid
   the mosaic wants (two pixel rows per character cell). Hard edges, so no
   filter. *)
let mosaic_of ~pcols ~prows ~w ~h (rgb : string) =
  let grid = Bytes.create (pcols * prows * 3) in
  for py = 0 to prows - 1 do
    let y = min (h - 1) (py * h / prows) in
    for px = 0 to pcols - 1 do
      let x = min (w - 1) (px * w / pcols) in
      let src = ((y * w) + x) * 3 in
      let dst = ((py * pcols) + px) * 3 in
      if src + 2 < String.length rgb then begin
        Bytes.set grid dst rgb.[src];
        Bytes.set grid (dst + 1) rgb.[src + 1];
        Bytes.set grid (dst + 2) rgb.[src + 2]
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
  let pcols = min cols 256 in
  let prows = 2 * screen_rows in
  let buf = Buffer.create (pcols * 24 * screen_rows) in
  Buffer.add_string buf "\027[2J\027[H";
  Buffer.add_string buf (fit_line cols (title_of frame));
  Buffer.add_string buf "\027[0K\r\n";
  (match frame with
   | Some f when String.length f.msx_rgb >= f.msx_width * f.msx_height * 3 ->
       List.iter
         (fun line ->
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

let open_screen ~(write : string -> unit) (state : Masc_tui_types.state) =
  state.msx_open <- true;
  render ~write state.msx_frame

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
