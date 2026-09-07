(* The workspace MSX machine and its input ledger. See msx_lane.mli. *)

type key = Msx.key

type sprite = { index : int; x : int; y : int; pattern : int; color : int }

type observation = {
  frame : int;
  mode : string;
  pc : int;
  halted : bool;
  screen_text : string;
  tiles : string list;
  sprites : sprite list;
  cartridge : string option;
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

let load ~ledger_dir ~roms_dir ~cart_path =
  locked (fun () ->
    match load_roms roms_dir, load_cart cart_path with
    | Error e, _ | _, Error e -> Error e
    | Ok roms, Ok cart ->
      let m = Msx.create ~machine:{ Msx.ram_kb = 512; vram_kb = 128; roms } in
      Option.iter (fun (_, bytes) -> Msx.load_cartridge m bytes) cart;
      Msx.step m ~frames:boot_frames;
      mkdir_p ledger_dir;
      let ledger_path = Filename.concat ledger_dir "ledger.jsonl" in
      (* A new machine starts a new ledger: truncate. *)
      Out_channel.with_open_bin ledger_path (fun _ -> ());
      let st =
        { m
        ; frame = boot_frames
        ; cart = Option.map (fun (path, _) -> Filename.basename path) cart
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

let press ~who ~keys ~hold_frames ~step_frames =
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
        match press_all st keys with
        | Error e -> Error e
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
