(* The workspace MSX machine and its input ledger. See msx_lane.mli. *)

(* 순수 판별 코어를 lane 의 namespace 로 올린다 (mli 재노출용). *)
module Screen_change = Screen_change

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
  | "backspace" -> Ok Msx.Backspace
  | "trigger_a" -> Ok Msx.Trigger_a
  | "trigger_b" -> Ok Msx.Trigger_b
  | "shift" -> Ok Msx.Shift
  | "ctrl" -> Ok Msx.Ctrl
  | "graph" -> Ok Msx.Graph
  | "select" -> Ok Msx.Select
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
         "unknown key %S: use up, down, left, right, space, esc, return, backspace, \
          trigger_a, trigger_b, shift, ctrl, graph, select, f1-f5, or one character"
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
  | Msx.Backspace -> "backspace"
  | Msx.Trigger_a -> "trigger_a"
  | Msx.Trigger_b -> "trigger_b"
  | Msx.Shift -> "shift"
  | Msx.Ctrl -> "ctrl"
  | Msx.Graph -> "graph"
  | Msx.Select -> "select"
  | Msx.Function n -> Printf.sprintf "f%d" n
  | Msx.Char c -> String.make 1 c
;;

type machine = {
  m : Msx.t;
  incarnation : string;
  mutable frame : int;
  mutable pixels : (int * int * string) option;
  (* Immutable RGB snapshot for this machine state, guarded by [lock]. *)
  cart : string option;
  disk : string option;
  disk_id : string option;
  media : (string * string) list;
  ledger_path : string;
  mutable entries : entry list;  (* newest first *)
  mutable input_count : int;
}

let state : machine option ref = ref None
let lock = Mutex.create ()
let locked f = Mutex.protect lock f
(* Used only while holding [lock]. An incarnation names a newly installed
   history, including a restore of the exact same checkpoint. *)
let fresh_incarnation () = Random_id.uuid_v7 ()

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

let rendered_pixels st =
  match st.pixels with
  | Some pixels -> pixels
  | None ->
      let width, height = Msx.frame_dims st.m in
      let pixels = width, height, Msx.frame_rgb st.m in
      st.pixels <- Some pixels;
      pixels

(* Bitmap modes draw their screens into pixels; the name table underneath is
   leftover noise, not what the game drew. Sending it anyway cost ~2 KB per
   observation (measured: 315 keeper screens averaged 3.7 KB), which is what
   drowns the useful fields in a playing keeper's context. Text and tile
   modes keep the name table — there it is the game's text. *)
let is_bitmap_mode mode =
  match mode with
  | "GRAPHIC4" | "GRAPHIC5" | "GRAPHIC6" | "GRAPHIC7" -> true
  | _ -> String.starts_with ~prefix:"UNDEFINED" mode
;;

let observe st =
  let mode = Msx.display_mode st.m in
  { frame = st.frame
  ; mode = Msx.display_mode_to_string mode
  ; pc = Msx.dump_pc st.m
  ; halted = Msx.cpu_halted st.m
  ; screen_text =
      (if is_bitmap_mode (Msx.display_mode_to_string mode) then ""
       else Msx.screen_text st.m)
  ; tiles = tiles_of st.m mode
  ; sprites = sprites_of st.m mode
  ; cartridge = st.cart
  ; disk = st.disk
  ; screen_view =
      (let w, h, rgb = rendered_pixels st in
       ascii_view rgb ~w ~h)
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
  st.input_count <- st.input_count + 1;
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

type medium =
  | Cartridge of string
  | Disk of string

type transition = {
  before : medium option;
  after : medium option;
}

type loaded = {
  observation : observation;
  transition : transition;
}

(* [load] empties the slot when a disk is in the drive, so the drive is asked
   first and the two never both answer. *)
let medium_of (st : machine option) =
  match st with
  | None -> None
  | Some st ->
    (match st.disk, st.cart with
     | Some name, _ -> Some (Disk name)
     | None, Some name -> Some (Cartridge name)
     | None, None -> None)
;;

let load ~ledger_dir ~roms_dir ~cart_path ~disk_path =
  locked (fun () ->
    (* Read under the lock the load commits under: two loads that serialise
       here see the machine each one replaced, not the one both started
       from. *)
    let before = medium_of !state in
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
          ; incarnation = fresh_incarnation ()
          ; pixels = None
          ; frame = pre_frames
          ; cart =
              (if Option.is_some disk then None
               else Option.map (fun (path, _) -> Filename.basename path) cart)
          ; disk = Option.map (fun (path, _) -> Filename.basename path) disk
          ; disk_id = Option.map (fun (_, bytes) -> media_id bytes) disk
          ; media = []
          ; ledger_path
          ; entries = []
          ; input_count = 0
          }
        in
        state := Some st;
        Ok { observation = observe st
           ; transition = { before; after = medium_of (Some st) } })
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
  (* Invalidate before mutating even if stepping raises after partial progress. *)
  st.pixels <- None;
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

type until_change = {
  frames_run : int;
      (** frames actually advanced — less than the budget when it settled early *)
  changed : bool;
      (** the screen ended up different from the start; false with a settled
          screen is the "this scene waits for a key" signal *)
  stable : bool;
      (** stopped because the screen settled; false means the budget ran out *)
}

(* 화면이 스스로 멈출 때까지 논다 — "n 프레임" 대신 "장면이 안착할 때까지"를
   한 번의 호출로. 지문은 screen_view 그대로고 판정은 순수 코어(Screen_change)
   가 한다: 키퍼는 큰 관찰 없이도 변화·정지·키 대기 후보를 알 수 있다. *)
let step_until_change ~max_frames =
  with_machine (fun st ->
    match check_frames ~what:"frames" max_frames with
    | Error e -> Error e
    | Ok () ->
      let cfg = Screen_change.default in
      let start = observe st in
      let base = start.screen_view in
      let state = ref (Screen_change.initial base) in
      let frames_run = ref 0 in
      let stopped = ref false in
      while not !stopped && !frames_run < max_frames do
        let chunk = min cfg.interval (max_frames - !frames_run) in
        advance st chunk;
        frames_run := !frames_run + chunk;
        let view = (observe st).screen_view in
        state := Screen_change.feed cfg !state view;
        stopped := Screen_change.settled cfg !state
      done;
      Ok
        ( observe st
        , { frames_run = !frames_run
          ; changed = Screen_change.changed cfg base !state
          ; stable = !stopped
          } ))
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
      let width, height, rgb = rendered_pixels st in
        { number = st.frame
        ; width
        ; height
        ; rgb
        ; mode = Msx.display_mode_to_string (Msx.display_mode st.m)
        ; cartridge = st.cart
        ; disk = st.disk
        }
;;

let frame () = locked (fun () -> Option.map frame_of !state)
;;

let step_frame ~frames =
  with_machine (fun st ->
    match check_frames ~what:"frames" frames with
    | Error _ as error -> error
    | Ok () ->
        advance st frames;
        Ok (frame_of st, List.rev st.entries))
;;

let capture () = with_machine (fun st -> Ok (observe st, frame_of st))
;;

type identified_capture = {
  incarnation : string;
  observation : observation;
  frame : frame;
  input_count : int;
  input_ledger : entry list;
}

let capture_with_identity () =
  with_machine (fun st ->
    Ok { incarnation = st.incarnation; observation = observe st;
         frame = frame_of st; input_count = st.input_count;
         input_ledger = st.entries })
  (* The immutable list spine is captured under the lock. Traversal need not
     hold up another controller's input or frame progression. *)
  |> Result.map (fun capture ->
       { capture with input_ledger = List.rev capture.input_ledger })
;;

(* --- RAM 인트로스펙션 — 상태 센서 ---------------------------------------
   화면 판독은 "인간의 눈"으로 상태를 다시 읽는 비싼 우회다. 게임의 진실은
   메모리에 있고, 코어는 그 전체를 이미 들고 있다. peek은 논리 주소의 바이트를
   hex로 읽으며 내부 64K 스냅샷을 갱신하고, ram_diff는 직전 peek 이후 달라진
   바이트를 변화 구간으로 돌려준다 — "이 조작이 무엇을 바꿨나"를 큰 덤프 없이
   파악한다. 읽기만 한다: 쓰기는 치트 계약(RFC-0439) 위반이다. *)

let peek_max_bytes = 256
let ram_diff_max_runs = 64
let address_space = 0x10000

(* 스냅샷은 머신이 아니라 레인이 든다: peek을 부른 시점의 세계 그 자체가
   기준이고, 머신 교체(load/restore) 후의 diff도 "달라졌다"로 옳다. *)
let last_peek : Bytes.t option ref = ref None

type ram_change = { address : int; length : int; from_hex : string; to_hex : string }

let hex_pairs bytes lo hi =
  String.concat ""
    (List.init (hi - lo) (fun i -> Printf.sprintf "%02x" (Char.code (Bytes.get bytes (lo + i)))))
;;

let peek ~address ~length =
  if address < 0 || length < 1 || length > peek_max_bytes
     || address + length > address_space then
    Error
      (Invalid_request
         (Printf.sprintf "peek needs 1..%d bytes inside 0x0000-0xFFFF, got %d..%d"
            peek_max_bytes address (address + length)))
  else
    with_machine (fun st ->
      let snap = Bytes.create address_space in
      for a = 0 to address_space - 1 do
        Bytes.set snap a (Char.chr (Msx.mem_read st.m a))
      done;
      last_peek := Some snap;
      Ok (hex_pairs snap address (address + length)))
;;

type ram_diff = { changes : ram_change list; truncated : bool; changed_bytes : int }

let ram_diff () =
  match !last_peek with
  | None -> Error (Invalid_request "no snapshot yet: call masc_msx_peek first")
  | Some snap ->
    with_machine (fun st ->
      let rec go a changes total =
        if a >= address_space || List.length changes >= ram_diff_max_runs then
          { changes = List.rev changes
          ; truncated = a < address_space
          ; changed_bytes = total }
        else if Char.code (Bytes.get snap a) = Msx.mem_read st.m a then go (a + 1) changes total
        else begin
          (* 하나의 변화 구간: 연속해서 달라진 바이트를 묶는다. *)
          let rec run b =
            if b >= address_space
               || Char.code (Bytes.get snap b) = Msx.mem_read st.m b
            then b
            else run (b + 1)
          in
          let hi = run a in
          let change =
            { address = a
            ; length = hi - a
            ; from_hex = hex_pairs snap a hi
            ; to_hex =
                String.concat ""
                  (List.init (hi - a) (fun i ->
                       Printf.sprintf "%02x" (Msx.mem_read st.m (a + i))))
            }
          in
          go hi (change :: changes) (total + (hi - a))
        end
      in
      Ok (go 0 [] 0))
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
  (* A slot that was never saved is the caller naming one that does not
     exist, which is an argument problem and refusable. Reaching the read
     first turned it into [Unreadable], and the tool answered with a runtime
     failure -- the caller cannot tell from that whether the machine changed.
     [Unreadable] keeps its meaning: a file that is there and will not read. *)
  if not (Sys.file_exists path)
  then Error (Invalid_request ("no MSX checkpoint at " ^ path))
  else
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
        let st = {m; incarnation = fresh_incarnation (); pixels = None; frame;
                  cart; disk; disk_id; media; ledger_path; entries = List.rev entries;
                  input_count = List.length entries} in
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
            let next = {st with m; pixels = None; disk = Some (Filename.basename path); disk_id = Some target_id; media = List.remove_assoc target_id media} in
            state := Some next;
            Ok (observe next)))
      | _ -> Error (Invalid_request "load a disk game before changing disks"))
  with Sys_error message -> Error (Unreadable message)
;;
