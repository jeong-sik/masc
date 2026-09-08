(* The workspace MSX machine and its input ledger. See msx_lane.mli. *)

type key = Msx.key

type sprite = { index : int; x : int; y : int; pattern : int; color : int }

type observation = {
  frame : int;
  mode : string;
  pc : int;
  halted : bool;
  screen_text : string;
  screen_view : string;
  tiles : string list;
  sprites : sprite list;
  cartridge : string option;
  disk : string option;
}

type entry = { at_frame : int; who : string; key_name : string; down : bool }

type error =
  | No_machine
  | Invalid_request of string
  | Unreadable of string

let error_to_string = function
  | No_machine -> "no MSX machine is loaded: call masc_msx_load first"
  | Invalid_request message -> message
  | Unreadable message -> message
;;

let max_frames_per_call = 300
let boot_frames = 45

(* A disk boots through the warm-up replay: this much C-BIOS runs first so the
   F380 inter-slot primitives sit in RAM, then [Msx.boot_disk] replays the Disk
   ROM's second-stage call onto the machine. The cart-INIT path the core also
   wires reboots mid-boot on a game's first stage (ocaml-msx #10), so the lane
   takes the replay -- the path a loader runs to its title screen on. *)
let disk_boot_frames = 720

(* C-BIOS file names, in the order Msx.create wants them: main, logo, sub. *)
let bios_files = [ "cbios_main_msx2.rom"; "cbios_logo_msx2.rom"; "cbios_sub.rom" ]

let key_of_string s : (key, string) result =
  match String.lowercase_ascii s with
  | "up" -> Ok Msx.Up
  | "down" -> Ok Msx.Down
  | "left" -> Ok Msx.Left
  | "right" -> Ok Msx.Right
  | "space" -> Ok Msx.Space
  | "esc" | "escape" -> Ok Msx.Esc
  | "return" | "enter" -> Ok Msx.Return
  | "trigger_a" -> Ok Msx.Trigger_a
  | "trigger_b" -> Ok Msx.Trigger_b
  | "f1" -> Ok (Msx.Function 1)
  | "f2" -> Ok (Msx.Function 2)
  | "f3" -> Ok (Msx.Function 3)
  | "f4" -> Ok (Msx.Function 4)
  | "f5" -> Ok (Msx.Function 5)
  | k when String.length k = 1 && Char.code k.[0] > 32 && Char.code k.[0] < 127 ->
    Ok (Msx.Char k.[0])
  | k ->
    Error
      (Printf.sprintf
         "unknown key %S: use up, down, left, right, space, esc, return, \
          trigger_a, trigger_b, f1-f5, or one character"
         k)
;;

let key_to_string : key -> string = function
  | Msx.Up -> "up"
  | Msx.Down -> "down"
  | Msx.Left -> "left"
  | Msx.Right -> "right"
  | Msx.Space -> "space"
  | Msx.Esc -> "esc"
  | Msx.Return -> "return"
  | Msx.Trigger_a -> "trigger_a"
  | Msx.Trigger_b -> "trigger_b"
  | Msx.Function n -> Printf.sprintf "f%d" n
  | Msx.Char c -> String.make 1 c
;;

type machine = {
  m : Msx.t;
  mutable frame : int;
  cart : string option;
  disk : string option;
  disk_id : string option;
  media : (string * string) list;
  ledger_path : string;
  mutable entries : entry list;  (* newest first *)
}

let state : machine option ref = ref None
let lock = Mutex.create ()
let locked f = Mutex.protect lock f

let with_machine f =
  locked (fun () ->
    match !state with
    | None -> Error No_machine
    | Some st -> f st)
;;

let hex2 = Printf.sprintf "%02x"

(* Name table rows for the tile modes: 32 names a row, 24 rows, from R#2. *)
let tiles_of m (mode : Msx.display_mode) =
  match mode with
  | Msx.Graphic1 | Msx.Graphic2 | Msx.Graphic3 | Msx.Multicolor ->
    let regs = Msx.vdp_regs m in
    let nt = (regs.(2) land 0x7f) lsl 10 in
    List.init 24 (fun row ->
      String.concat ""
        (List.init 32 (fun col ->
           let b = Msx.vram_read m (nt + (row * 32) + col) in
           if b = 0 then ".." else hex2 b)))
  | Msx.Text1 | Msx.Text2 | Msx.Graphic4 | Msx.Graphic5 | Msx.Graphic6 | Msx.Graphic7
  | Msx.Undefined _ -> []
;;

(* Sprite attribute table: R#11 A16-A15, R#5 A14-A7; four bytes a slot,
   Y = 0xD0 ends the list. Text modes have no sprites. *)
let sprites_of m (mode : Msx.display_mode) =
  match mode with
  | Msx.Text1 | Msx.Text2 | Msx.Undefined _ -> []
  | Msx.Graphic1 | Msx.Graphic2 | Msx.Graphic3 | Msx.Multicolor | Msx.Graphic4
  | Msx.Graphic5 | Msx.Graphic6 | Msx.Graphic7 ->
    let regs = Msx.vdp_regs m in
    let sat = ((regs.(11) land 3) lsl 15) lor ((regs.(5) land 0xff) lsl 7) in
    let rec go i acc =
      if i >= 32 then List.rev acc
      else begin
        let base = sat + (4 * i) in
        let y = Msx.vram_read m base in
        if y = 0xd0 then List.rev acc
        else
          go (i + 1)
            ({ index = i
             ; y
             ; x = Msx.vram_read m (base + 1)
             ; pattern = Msx.vram_read m (base + 2)
             ; color = Msx.vram_read m (base + 3)
             }
            :: acc)
      end
    in
    go 0 []
;;

(* A coarse text picture of the frame, so a keeper with no vision runtime can
   still recognise the screen (a title, a menu, a map) in any mode. Each cell is
   the average luminance of the pixels under it, mapped to a ramp. Not a
   replacement for [screen_text] -- that reads a text-mode name table and is
   exact when the pattern set is a font; [screen_view] works in every mode,
   including the bitmap modes where the name table is not characters. *)
let screen_view_cols = 64
let screen_view_rows = 24
let screen_view_ramp = " .:-=+*#%@"

let ascii_view rgb ~w ~h =
  if w <= 0 || h <= 0 || String.length rgb < w * h * 3 then ""
  else begin
    let ramp = screen_view_ramp in
    let levels = String.length ramp in
    let cols = screen_view_cols and rows = screen_view_rows in
    let buf = Buffer.create (rows * (cols + 1)) in
    for ry = 0 to rows - 1 do
      let y0 = ry * h / rows and y1 = (ry + 1) * h / rows in
      for cx = 0 to cols - 1 do
        let x0 = cx * w / cols and x1 = (cx + 1) * w / cols in
        let sum = ref 0 and n = ref 0 in
        for y = y0 to max y0 (y1 - 1) do
          for x = x0 to max x0 (x1 - 1) do
            let i = ((y * w) + x) * 3 in
            let r = Char.code rgb.[i]
            and g = Char.code rgb.[i + 1]
            and b = Char.code rgb.[i + 2] in
            sum := !sum + (((r * 30) + (g * 59) + (b * 11)) / 100);
            incr n
          done
        done;
        let lum = if !n = 0 then 0 else !sum / !n in
        Buffer.add_char buf ramp.[lum * (levels - 1) / 255]
      done;
      Buffer.add_char buf '\n'
    done;
    Buffer.contents buf
  end
;;

let observe st =
  let mode = Msx.display_mode st.m in
  { frame = st.frame
  ; mode = Msx.display_mode_to_string mode
  ; pc = Msx.dump_pc st.m
  ; halted = Msx.cpu_halted st.m
  ; screen_text = Msx.screen_text st.m
  ; tiles = tiles_of st.m mode
  ; sprites = sprites_of st.m mode
  ; cartridge = st.cart
  ; disk = st.disk
  ; screen_view =
      (let w, h = Msx.frame_dims st.m in
       ascii_view (Msx.frame_rgb st.m) ~w ~h)
  }
;;

let entry_json (e : entry) : Yojson.Safe.t =
  `Assoc
    [ ("frame", `Int e.at_frame)
    ; ("who", `String e.who)
    ; ("key", `String e.key_name)
    ; ("edge", `String (if e.down then "down" else "up"))
    ]
;;

let append_entry st e =
  st.entries <- e :: st.entries;
  Out_channel.with_open_gen
    [ Open_append; Open_creat; Open_wronly ]
    0o644
    st.ledger_path
    (fun oc ->
      output_string oc (Yojson.Safe.to_string (entry_json e));
      output_char oc '\n')
;;

let read_file path = In_channel.with_open_bin path In_channel.input_all

let rec mkdir_p dir =
  if not (Sys.file_exists dir) then begin
    mkdir_p (Filename.dirname dir);
    Sys.mkdir dir 0o755
  end
;;

let load_roms roms_dir =
  if roms_dir = "" then Ok []
  else begin
    let main = Filename.concat roms_dir (List.hd bios_files) in
    if not (Sys.file_exists main) then
      Error (Unreadable (Printf.sprintf "no %s in %s" (List.hd bios_files) roms_dir))
    else
      Ok
        (List.map
           (fun f ->
             let p = Filename.concat roms_dir f in
             if Sys.file_exists p then read_file p else "")
           bios_files)
  end
;;

let load_cart = function
  | None -> Ok None
  | Some path ->
    if Sys.file_exists path then Ok (Some (path, read_file path))
    else Error (Unreadable (Printf.sprintf "cartridge not found: %s" path))
;;

let load_disk = function
  | None -> Ok None
  | Some path ->
    if Sys.file_exists path then Ok (Some (path, read_file path))
    else Error (Unreadable (Printf.sprintf "disk not found: %s" path))
;;

let media_id bytes = Digestif.SHA256.(to_hex (digest_string bytes))

let media_json media =
  `List (List.map (fun (id, bytes) -> `Assoc
    ["id", `String id; "sha256", `String (media_id bytes);
     "bytes", `String (Base64.encode_string bytes)]) media)
;;

let load ~ledger_dir ~roms_dir ~cart_path ~disk_path =
  locked (fun () ->
    match load_roms roms_dir, load_cart cart_path, load_disk disk_path with
    | Error e, _, _ | _, Error e, _ | _, _, Error e -> Error e
    | Ok roms, Ok cart, Ok disk ->
      let m = Msx.create ~machine:{ Msx.ram_kb = 512; vram_kb = 128; roms } in
      (* A disk wins over a cartridge: the image boots through the warm-up
         replay, which wants the cartridge slot empty -- a C-BIOS boot that
         finds the interface ROM re-enters the sector boot every cycle. *)
      let boot_result =
        match disk with
        | Some (_, bytes) ->
          Msx.load_disk ~interface_rom:false m bytes;
          Msx.step m ~frames:disk_boot_frames;
          (match Msx.boot_disk m with
           | Ok () -> Ok (disk_boot_frames + boot_frames)
           | Error message -> Error (Invalid_request ("disk boot failed: " ^ message)))
        | None ->
          Option.iter (fun (_, bytes) -> Msx.load_cartridge m bytes) cart;
          Ok boot_frames
      in
      match boot_result with
      | Error e -> Error e
      | Ok pre_frames ->
        Msx.step m ~frames:boot_frames;
        mkdir_p ledger_dir;
        let ledger_path = Filename.concat ledger_dir "ledger.jsonl" in
        (* A new machine starts a new ledger: truncate. *)
        Out_channel.with_open_bin ledger_path (fun _ -> ());
        let st =
          { m
          ; frame = pre_frames
          ; cart =
              (if Option.is_some disk then None
               else Option.map (fun (path, _) -> Filename.basename path) cart)
          ; disk = Option.map (fun (path, _) -> Filename.basename path) disk
          ; disk_id = Option.map (fun (_, bytes) -> media_id bytes) disk
          ; media = []
          ; ledger_path
          ; entries = []
          }
        in
        state := Some st;
        Ok (observe st))
;;

let eject () =
  locked (fun () ->
    match !state with
    | None -> Error No_machine
    | Some _ ->
      state := None;
      Ok ())
;;

let screen () = with_machine (fun st -> Ok (observe st))

let check_frames ~what n =
  if n < 1 || n > max_frames_per_call then
    Error
      (Invalid_request
         (Printf.sprintf "%s must be 1..%d, got %d" what max_frames_per_call n))
  else Ok ()
;;

let advance st n =
  Msx.step st.m ~frames:n;
  st.frame <- st.frame + n
;;

let step ~frames =
  with_machine (fun st ->
    match check_frames ~what:"frames" frames with
    | Error e -> Error e
    | Ok () ->
      advance st frames;
      Ok (observe st))
;;

(* Press everything or nothing: a key without a matrix place is refused
   before any key goes down, and a refusal releases whatever went down. *)
let press_all st keys =
  let rec go pressed = function
    | [] -> Ok ()
    | k :: rest ->
      if Msx.set_key st.m k ~pressed:true then go (k :: pressed) rest
      else begin
        (* See Msx.set_key: a key that went down has a matrix place, so its release cannot miss. *)
        List.iter (fun p -> ignore (Msx.set_key st.m p ~pressed:false : bool)) pressed;
        Error
          (Invalid_request
             (Printf.sprintf "the keyboard matrix has no key for %S" (key_to_string k)))
      end
  in
  go [] keys
;;

let tap_one st ~who ~hold_frames ~step_frames k =
  (* Tap [k] in its own frame window: down, hold, up, then the rest idle. *)
  (* See Msx.set_key: press_all checked [k]'s matrix place, so this edge cannot miss. *)
  ignore (Msx.set_key st.m k ~pressed:true : bool);
  append_entry st { at_frame = st.frame; who; key_name = key_to_string k; down = true };
  advance st hold_frames;
  (* See Msx.set_key: the key just went down, so its release cannot miss. *)
  ignore (Msx.set_key st.m k ~pressed:false : bool);
  append_entry st { at_frame = st.frame; who; key_name = key_to_string k; down = false };
  advance st (step_frames - hold_frames)
;;

let press ~who ~keys ~hold_frames ~step_frames ~sequence =
  with_machine (fun st ->
    if keys = [] then Error (Invalid_request "keys must name at least one key")
    else
      match check_frames ~what:"hold_frames" hold_frames, check_frames ~what:"frames" step_frames with
      | Error e, _ | _, Error e -> Error e
      | Ok (), Ok () when hold_frames > step_frames ->
        Error
          (Invalid_request
             (Printf.sprintf "hold_frames (%d) cannot exceed frames (%d)" hold_frames step_frames))
      | Ok (), Ok () -> (
        (* [press_all] validates every key against the matrix up front, so a
           bad key in a sequence is refused before any tap advances time. *)
        match press_all st keys with
        | Error e -> Error e
        | Ok () when sequence ->
          (* [press_all] left the keys down with no frame advanced; release them
             and tap each in turn, so ["down"; "return"] is a menu sequence, not
             a chord held together. *)
          (* See Msx.set_key: press_all just checked every key, so these cannot miss. *)
          List.iter (fun k -> ignore (Msx.set_key st.m k ~pressed:false : bool)) keys;
          List.iter (tap_one st ~who ~hold_frames ~step_frames) keys;
          Ok (observe st)
        | Ok () ->
          List.iter
            (fun k ->
              append_entry st
                { at_frame = st.frame; who; key_name = key_to_string k; down = true })
            keys;
          advance st hold_frames;
          List.iter
            (fun k ->
              (* See Msx.set_key: the key went down a moment ago, so its release cannot miss. *)
              ignore (Msx.set_key st.m k ~pressed:false : bool);
              append_entry st
                { at_frame = st.frame; who; key_name = key_to_string k; down = false })
            keys;
          advance st (step_frames - hold_frames);
          Ok (observe st)))
;;

let ledger () =
  locked (fun () ->
    match !state with
    | None -> []
    | Some st -> List.rev st.entries)
;;

type frame = {
  number : int;
  width : int;
  height : int;
  rgb : string;
  mode : string;
  cartridge : string option;
  disk : string option;
}

let frame_of (st : machine) =
      let width, height = Msx.frame_dims st.m in
        { number = st.frame
        ; width
        ; height
        ; rgb = Msx.frame_rgb st.m
        ; mode = Msx.display_mode_to_string (Msx.display_mode st.m)
        ; cartridge = st.cart
        ; disk = st.disk
        }
;;

let frame () = locked (fun () -> Option.map frame_of !state)
;;

let capture () = with_machine (fun st -> Ok (observe st, frame_of st))
;;

let atomic_write path contents =
  mkdir_p (Filename.dirname path);
  let tmp, oc = Filename.open_temp_file ~temp_dir:(Filename.dirname path) ".msx-" ".tmp" in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc; if Sys.file_exists tmp then Sys.remove tmp)
    (fun () -> output_string oc contents; close_out oc; Sys.rename tmp path)
;;

let checkpoint_json (st : machine) =
  let named = function None -> `Null | Some name -> `String name in
  `Assoc
    [ "version", `Int 1
    ; "machine", `String (Base64.encode_string (Msx.serialize st.m))
    ; "cartridge", named st.cart
    ; "disk", named st.disk
    ; "disk_id", named st.disk_id
    ; "media", media_json st.media
    ; "ledger", `List (List.map entry_json (List.rev st.entries))
    ]
;;

let save ~path =
  locked (fun () ->
    match !state with
    | None -> Error No_machine
    | Some st ->
      try
        atomic_write path (Yojson.Safe.to_string (checkpoint_json st));
        Ok (observe st)
      with Sys_error message -> Error (Unreadable message))
;;

let decode_checkpoint json =
  let open Yojson.Safe.Util in
  let invalid message = Error (Invalid_request ("invalid MSX checkpoint: " ^ message)) in
  let named = function `Null -> None | `String s -> Some s
    | value -> raise (Type_error ("expected media name or null", value)) in
  try
    if member "version" json <> `Int 1 then invalid "unsupported version"
    else
      match Base64.decode (member "machine" json |> to_string) with
      | Error (`Msg message) -> invalid message
      | Ok bytes -> (
        match Msx.restore ~state:bytes with
        | Error message -> invalid message
        | Ok m ->
          let cart = named (member "cartridge" json) and disk = named (member "disk" json) in
          let disk_id = named (member "disk_id" json) in
          let valid_id id = String.length id = 64 && String.for_all (function
            | '0'..'9' | 'a'..'f' -> true | _ -> false) id in
          let media = member "media" json |> to_list |> List.map (fun item ->
            let id = member "id" item |> to_string in
            let hash = member "sha256" item |> to_string in
            let encoded = member "bytes" item |> to_string in
            match Base64.decode encoded with
            | Error (`Msg message) -> raise (Type_error (message, item))
            | Ok bytes ->
              if not (valid_id id) || media_id bytes <> hash then
                raise (Type_error ("invalid saved disk identity or checksum", item));
              id, bytes) in
          if List.length (List.sort_uniq String.compare (List.map fst media)) <> List.length media then
            raise (Type_error ("duplicate saved disk identity", json));
          if (Option.is_some disk <> Option.is_some disk_id)
             || not (Option.fold ~none:true ~some:valid_id disk_id) then
            raise (Type_error ("saved disk has no valid original identity", json));
          let frame = Msx.frame_number m in
          let entries = member "ledger" json |> to_list |> List.map (fun e ->
            let at_frame = member "frame" e |> to_int in
            let who = member "who" e |> to_string in
            let key_name = member "key" e |> to_string in
            let down = match member "edge" e with
              | `String "down" -> true | `String "up" -> false
              | value -> raise (Type_error ("expected down or up edge", value)) in
            {at_frame; who; key_name; down}) in
          let rec valid_edges previous = function
            | [] -> true
            | e :: rest -> e.at_frame >= previous && e.at_frame <= frame
                && Result.is_ok (key_of_string e.key_name) && valid_edges e.at_frame rest in
          if not (valid_edges 0 entries) then invalid "ledger does not match saved frame"
          else Ok (m, frame, cart, disk, disk_id, media, entries))
  with Type_error (message, _) -> invalid message
;;

let restore ~path ~ledger_dir =
  let decoded =
    try decode_checkpoint (Yojson.Safe.from_string (read_file path)) with
    | Sys_error message -> Error (Unreadable message)
    | Yojson.Json_error message -> Error (Invalid_request ("invalid MSX checkpoint JSON: " ^ message)) in
  match decoded with
  | Error e -> Error e
  | Ok (m, frame, cart, disk, disk_id, media, entries) ->
    locked (fun () ->
      let ledger_path = Filename.concat ledger_dir "ledger.jsonl" in
      try
        let ledger_bytes = String.concat "" (List.map (fun e -> Yojson.Safe.to_string (entry_json e) ^ "\n") entries) in
        atomic_write ledger_path ledger_bytes;
        let st = {m; frame; cart; disk; disk_id; media; ledger_path; entries = List.rev entries} in
        state := Some st;
        Ok (observe st)
      with Sys_error message -> Error (Unreadable message))
;;

let change_disk ~path ~backup_path =
  try
    let original = read_file path in
    let target_id = media_id original in
    with_machine (fun st ->
      match st.disk_id, Msx.disk_image st.m with
      | Some current_id, Some current_bytes -> (
        let media = (current_id, current_bytes) :: List.remove_assoc current_id st.media in
        let target_bytes = match List.assoc_opt target_id media with
          | Some retained -> retained | None -> original in
        match Msx.restore ~state:(Msx.serialize st.m) with
        | Error message -> Error (Unreadable ("cannot checkpoint current machine: " ^ message))
        | Ok m -> (
          match Msx.change_disk m target_bytes with
          | Error message -> Error (Invalid_request message)
          | Ok () ->
            atomic_write backup_path (Yojson.Safe.to_string (checkpoint_json st));
            let next = {st with m; disk = Some (Filename.basename path); disk_id = Some target_id; media = List.remove_assoc target_id media} in
            state := Some next;
            Ok (observe next)))
      | _ -> Error (Invalid_request "load a disk game before changing disks"))
  with Sys_error message -> Error (Unreadable message)
;;
