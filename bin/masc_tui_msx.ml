(* The MSX screen. The drawing half of this file mirrors what [open_image]
   does for a picture: write the whole screen directly, because the retained
   frame underneath would otherwise repaint rows over it. The frame loop knows
   to yield while [msx_open] is set -- masc_tui.ml skips its Render step the
   same way it does for [image_open].

   The keyboard is the emulator's. A key arriving here never reaches the
   surface underneath: the loop intercepts it before computing [key], exactly
   where it intercepts the dismiss key of a showing picture. *)

(* The ROM set comes from the environment, not from the client's knowledge
   of where the core repo lives: MSX_ROMS names a directory holding the
   C-BIOS triple (main_msx2, logo_msx2, sub). Without it the machine still
   runs -- on 0xff bus reads, so the screen stays black; the title says so.
   MSX_CART names one cartridge image (16/32KB) to plug into slot 2. *)
let rom_dir () = try Sys.getenv "MSX_ROMS" with Not_found -> ""
let cart_path () = try Sys.getenv "MSX_CART" with Not_found -> ""

type load_error = { path : string; detail : string }
exception Image_read_failed of load_error

let read_file path =
  try In_channel.with_open_bin path In_channel.input_all with
  | Sys_error detail -> raise (Image_read_failed { path; detail })

let load_roms dir =
  if dir = "" then []
  else
    List.filter_map
      (fun f ->
        let path = Filename.concat dir f in
        if Sys.file_exists path then Some (read_file path) else None)
      [ "cbios_main_msx2.rom"; "cbios_logo_msx2.rom"; "cbios_sub.rom" ]

(* Single-machine module, like state.msx itself: the title wants to know how
   the one machine booted without threading a flag through state. *)
let booted_with_roms = ref false
let cart_name = ref ""

let machine_of (state : Masc_tui_types.state) =
  match state.msx with
  | Some m -> m
  | None ->
      let roms = load_roms (rom_dir ()) in
      let m = Msx.create ~machine:{ ram_kb = 512; vram_kb = 128; roms } in
      let cartridge = cart_path () in
      (match cartridge with
      | "" -> ()
      | path ->
          Msx.load_cartridge m (read_file path));
      (* Run ahead to the boot logo (~30 frames in, full at 45) so the first
         paint shows something; afterwards one key is one frame -- the
         spectator contract. *)
      Msx.step m ~frames:45;
      booted_with_roms := roms <> [];
      cart_name := if cartridge = "" then "" else Filename.basename cartridge;
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
  let title =
    if not !booted_with_roms then
      " ocaml-msx — no ROM (set MSX_ROMS to a C-BIOS directory)"
    else if !cart_name = "" then " ocaml-msx — MSX2 C-BIOS"
    else " ocaml-msx — MSX2 C-BIOS + " ^ !cart_name
  in
  Buffer.add_string buf (fit_line cols title);
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

let open_screen ~write (state : Masc_tui_types.state) =
  (* Expected file failures are handled before giving this screen the keyboard
     and renderer. Terminal writes and emulator faults remain distinct. *)
  let loaded =
    try Ok (machine_of state) with Image_read_failed error -> Error error
  in
  match loaded with
  | Error error -> Error error
  | Ok _ ->
      state.msx_open <- true;
      draw ~write state;
      Ok ()

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
    | Some k when Msx.set_key m k ~pressed:true ->
        Msx.step m ~frames:1;
        draw ~write state;
        (* Release only after the frame the key was down for is drawn -- the
           pattern marks held keys, and drawing after the release would always
           show none. *)
        (* See Msx.set_key: it was true a frame ago and the matrix is static. *)
        ignore (Msx.set_key m k ~pressed:false)
    | Some _ | None ->
        (* A key the matrix has no place for still advances one frame, so
           the spectator's clock never stalls on a typo. *)
        Msx.step m ~frames:1;
        draw ~write state);
    true
  end
