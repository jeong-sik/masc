(* The MSX screen. The drawing half of this file mirrors what [open_image]
   does for a picture: write the whole screen directly, because the retained
   frame underneath would otherwise repaint rows over it. The frame loop knows
   to yield while [msx_open] is set -- masc_tui.ml skips its Render step the
   same way it does for [image_open].

   The keyboard is the emulator's. A key arriving here never reaches the
   surface underneath: the loop intercepts it before computing [key], exactly
   where it intercepts the dismiss key of a showing picture. *)

let machine_of (state : Masc_tui_types.state) =
  match state.msx with
  | Some m -> m
  | None ->
      let m = Msx.create ~machine:{ ram_kb = 128; vram_kb = 128; roms = [] } in
      state.msx <- Some m;
      m

(* Nothing may wrap: a wrapped title or footer line would push the mosaic off
   the bottom on a short terminal. *)
let fit_line width s = String.sub s 0 (min (String.length s) (max width 1))

let draw ~write (state : Masc_tui_types.state) =
  let m = machine_of state in
  let rows, cols = Masc_tui_ansi.get_terminal_size () in
  let screen_rows = max 4 (rows - 2) in
  let pcols = min cols 256 in
  let prows = 2 * screen_rows in
  let w, h = Msx.frame_dims m in
  let rgb = Msx.frame_rgb m in
  (* Nearest-neighbour shrink of the native frame onto the [pcols x prows]
     grid the mosaic renderer wants: [pcols] cells wide, two pixel rows per
     cell. The pattern has hard edges; a filter would only grey them. *)
  let grid = Bytes.create (pcols * prows * 3) in
  for py = 0 to prows - 1 do
    let y = min (h - 1) (py * h / prows) in
    for px = 0 to pcols - 1 do
      let x = min (w - 1) (px * w / pcols) in
      let src = ((y * w) + x) * 3 in
      let dst = ((py * pcols) + px) * 3 in
      Bytes.set grid dst rgb.[src];
      Bytes.set grid (dst + 1) rgb.[src + 1];
      Bytes.set grid (dst + 2) rgb.[src + 2]
    done
  done;
  let buf = Buffer.create (pcols * 24 * screen_rows) in
  Buffer.add_string buf "\027[2J\027[H";
  Buffer.add_string buf (fit_line cols " ocaml-msx (stub) — MSX2 core attachment demo");
  Buffer.add_string buf "\027[0K\r\n";
  List.iter
    (fun line ->
      Buffer.add_string buf line;
      Buffer.add_string buf "\027[0K\r\n")
    (Masc_tui_image_mosaic.render ~cols:pcols ~rows:prows
       (Bytes.to_string grid));
  Buffer.add_string buf
    (fit_line cols " esc: back   arrows / space / letters: keys (one frame each)");
  Buffer.add_string buf "\027[0K";
  write (Buffer.contents buf)

let open_screen ~write state =
  ignore (machine_of state);
  state.msx_open <- true;
  draw ~write state

let key_of = function
  | "up" -> Some Msx.Up
  | "down" -> Some Msx.Down
  | "left" -> Some Msx.Left
  | "right" -> Some Msx.Right
  | " " -> Some Msx.Space
  | c when String.length c = 1 && Char.code c.[0] >= 32 && Char.code c.[0] < 127 ->
      Some (Msx.Char c.[0])
  | _ -> None

let consume ~write (state : Masc_tui_types.state) key =
  if String.equal key "esc" then begin
    state.msx_open <- false;
    false
  end else begin
    let m = machine_of state in
    (match key_of key with
    | Some k ->
        Msx.set_key m k ~pressed:true;
        Msx.step m ~frames:1;
        draw ~write state;
        (* Release only after the frame the key was down for is drawn -- the
           pattern marks held keys, and drawing after the release would always
           show none. *)
        Msx.set_key m k ~pressed:false
    | None ->
        Msx.step m ~frames:1;
        draw ~write state);
    true
  end
