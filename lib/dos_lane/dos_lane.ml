(* The workspace DOS machine and its input ledger. See dos_lane.mli. *)

type observation = {
  steps : int;
  video_mode : int;
  width : int;
  height : int;
  cs : int;
  ip : int;
  psp : int;
  exited : bool;
  exit_code : int;
  halted : bool;
  waiting_for_key : bool;
  ticks : int;
  screen_text : string;
  frame_nonblack : int;
  frame_ascii : string;
  program : string option;
  controller : string option;
  files : string list;
}

type entry = { at_step : int; who : string; key_name : string }

type error =
  | No_machine
  | Invalid_request of string
  | Unreadable of string
  | Held_by of string
  | Guest_fault of string

let error_to_string = function
  | No_machine -> "no DOS machine is loaded: call masc_dos_load first"
  | Invalid_request message -> message
  | Unreadable message -> message
  | Held_by holder ->
    Printf.sprintf
      "%s holds the controller, so nothing was done: wait until they pass it with \
       masc_dos_pass. masc_dos_screen needs no controller"
      holder
  | Guest_fault message ->
    "the program ran something this machine does not implement, and stopped there: "
    ^ message
;;

(* The core runs about 24 million instructions a second on this hardware
   (measured booting ZZT: 6M steps in 0.25 s). 4M is roughly 170 ms, the same
   order as the MSX lane's 300-frame cap. *)
let max_steps_per_call = 4_000_000

(* A DOS program reaches its title screen in its own time. This is the budget
   for getting there; the load stops earlier if the program asks for a key. *)
let boot_steps = 4_000_000

let peek_max_bytes = 256

(* How many keys one call may name. The ceiling above bounds the machine's
   time, but not a call's work: a program that has exited runs no
   instructions, so without this a 100,000-character masc_dos_type would
   still walk 100,000 keys and write 100,000 ledger lines. A DOS program asks
   for a name, a number or a path. config/tools/masc_dos_press.toml and
   masc_dos_type.toml declare the same two numbers to the caller. *)
let max_keys_per_call = 64
let max_text_length = 256

type ran = {
  steps_run : int;
  settled : bool;
  input_requests : int;
  keys_pressed : int;
  unsaved : string list;
}

(* How far the machine runs between two screen readings. Measured on ZZT: the
   repaint that follows a key finishes inside one of these. *)
let settle_chunk = 50_000

type machine = {
  m : Dos_machine.t;
  mutable steps : int;
  program : string;
  ledger_path : string;
  mutable entries : entry list;  (* newest first *)
  saves_dir : string;
  kept : (string, string) Hashtbl.t;
      (* DOS name -> the contents last known to be on disk, either in the
         inventory or in [saves_dir]. A file whose mounted contents differ
         from this is one the program wrote since. *)
  mutable controller : string option;
      (* Who may move this machine's time. See [with_control]. *)
  incarnation : string;
      (* A fresh identity per load: an observer holding an older one knows
         the machine it read was replaced, even when the step count is back
         where it was. *)
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

(* The controller is the hotseat's pad. A hotseat game such as 삼국지3 asks
   each human ruler in turn at the same keyboard; on one shared machine a
   second Keeper's keys land in whoever's turn is on screen. The MSX lane had
   no such hand-off, and Keepers there swapped the program and restored slots
   under each other mid-campaign.

   Whoever moves the machine first holds it; everyone else is refused before
   anything happens and can still watch. The holder hands it on with [pass].
   A refused call takes nothing. *)
(* A call that runs the guest can fail two ways that are not the caller's
   arguments: the core meets an instruction it does not implement (ocaml-dos
   raises rather than misbehave quietly), or the ledger file will not take a
   line. Both come back as errors, not exceptions out of the tool. *)
let running f =
  match f () with
  | result -> result
  | exception Cpu86.Unsupported message -> Error (Guest_fault message)
  | exception Sys_error message -> Error (Unreadable message)
;;

let refuse_other st ~who =
  match st.controller with
  | Some holder when not (String.equal holder who) -> Error (Held_by holder)
  | Some _ | None -> Ok ()
;;

let with_control ~who f =
  with_machine (fun st ->
    match refuse_other st ~who with
    | Error e -> Error e
    | Ok () ->
      (* Taken before the call so the observation it returns names the new
         holder, and given back if the call is refused. *)
      let before = st.controller in
      st.controller <- Some who;
      let result = running (fun () -> f st) in
      (match result with
       | Ok _ | Error (Unreadable _ | Guest_fault _) -> ()
         (* the call ran: the machine may have moved *)
       | Error (No_machine | Invalid_request _ | Held_by _) -> st.controller <- before);
      result)
;;

(* ---------- observation ---------- *)

(* Graphics modes leave [screen_text] at whatever the text page last held, so
   a VGA game is invisible to the caller. Two summaries close that gap. Both
   read the frame the same way real hardware would: a pixel the raster has
   not written yet reads as black, never as an exception. *)
let luminance r g b = (r * 30 + g * 59 + b * 11) / 100

let frame_summaries m =
  let width, height = Dos_machine.frame_dims m in
  let rgb = Dos_machine.frame_rgb m in
  let byte i = if i < String.length rgb then Char.code rgb.[i] else 0 in
  let nonblack = ref 0 in
  let cols = max 1 (width / 8) and rows = max 1 (height / 16) in
  let ramp = " .:-=+*#%@" in
  let b = Buffer.create ((cols + 1) * rows) in
  for r = 0 to rows - 1 do
    for c = 0 to cols - 1 do
      let sum = ref 0 in
      let lit = ref false in
      for y = r * 16 to min (r * 16 + 15) (height - 1) do
        for x = c * 8 to min (c * 8 + 7) (width - 1) do
          let i = (y * width + x) * 3 in
          let r' = byte i and g' = byte (i + 1) and b' = byte (i + 2) in
          if r' > 8 || g' > 8 || b' > 8 then lit := true;
          sum := !sum + luminance r' g' b'
        done
      done;
      if !lit then incr nonblack;
      let avg = !sum / (8 * 16) in
      Buffer.add_char b ramp.[min 9 (avg * 10 / 256)]
    done;
    Buffer.add_char b '\n'
  done;
  (cols, rows, !nonblack, Buffer.contents b)
;;

let observe st =
  let m = st.m in
  let cpu = Dos_machine.cpu_of m in
  let width, height = Dos_machine.frame_dims m in
  let _cols, _rows, nonblack, ascii = frame_summaries m in
  {
    steps = st.steps;
    video_mode = Dos_machine.video_mode m;
    width;
    height;
    cs = Cpu86.seg cpu 1;
    psp = Dos_machine.psp_seg_of m;
    ip = Cpu86.dump_ip cpu;
    exited = Dos_machine.exited m;
    exit_code = Dos_machine.exit_code m;
    halted = Dos_machine.halted m;
    waiting_for_key = Dos_machine.kbd_waiting m;
    ticks = Dos_machine.tick_count m;
    screen_text = Dos_machine.screen_text_utf8 m;
    frame_nonblack = nonblack;
    frame_ascii = ascii;
    program = Some st.program;
    controller = st.controller;
    files = Dos_machine.mounted_names m;
  }
;;

(* ---------- ledger ---------- *)

let entry_json e : Yojson.Safe.t =
  `Assoc
    [ ("step", `Int e.at_step); ("who", `String e.who); ("key", `String e.key_name) ]
;;

(* The file first, then the list. A failed append -- a full disk, a mode
   changed under the process -- raises out of here before the key reaches the
   ring, so recording it first would leave a key in [ledger ()] that the guest
   never got and no file remembers. *)
let append_entry st e =
  Out_channel.with_open_gen
    [ Open_append; Open_creat; Open_wronly ]
    0o644
    st.ledger_path
    (fun oc ->
      output_string oc (Yojson.Safe.to_string (entry_json e));
      output_char oc '\n');
  st.entries <- e :: st.entries
;;

(* ---------- time ---------- *)

let clamp_steps steps =
  if steps < 1 || steps > max_steps_per_call then
    Error
      (Invalid_request
         (Printf.sprintf "steps must be 1..%d, got %d" max_steps_per_call steps))
  else Ok steps
;;

(* Runs the budget straight through, with nothing watching. *)
let advance_blind st ~budget =
  let before = Dos_machine.input_requests st.m in
  let n = Dos_machine.run_until st.m ~max_steps:budget ~stop:(fun _ -> false) in
  st.steps <- st.steps + n;
  { steps_run = n
  ; settled = false
  ; input_requests = Dos_machine.input_requests st.m - before
  ; keys_pressed = 0
  ; unsaved = []
  }
;;

(* Runs until the machine is ready for input, in chunks.
   Ready is two facts overlapped, and neither is a guess about the picture:

   - the guest asked the BIOS for a key inside this chunk and the ring was
     empty, and
   - the screen memory is the same as it was one chunk ago.

   The first alone is not enough. A program in its own loop takes a key and
   asks for the next one 631 instructions later (measured on ZZT) while the
   repaint it started is still half-written; stopping there hands the caller
   the picture from before their key, and the press looks like it did
   nothing. A menu that is genuinely blocked matches on the first chunk, so
   waiting costs it nothing. *)
let advance_until_ready st ~budget =
  let m = st.m in
  let requests_before = Dos_machine.input_requests m in
  let previous = ref (Dos_machine.screen_digest m) in
  let ran = ref 0 and settled = ref false in
  while (not !settled) && !ran < budget && not (Dos_machine.exited m) do
    let asked_before = Dos_machine.input_requests m in
    let n =
      Dos_machine.run_until m ~max_steps:(min settle_chunk (budget - !ran))
        ~stop:(fun _ -> false)
    in
    ran := !ran + n;
    let asked = Dos_machine.input_requests m > asked_before in
    let now = Dos_machine.screen_digest m in
    if asked && now = !previous then settled := true;
    previous := now
  done;
  st.steps <- st.steps + !ran;
  { steps_run = !ran
  ; settled = !settled
  ; input_requests = Dos_machine.input_requests m - requests_before
  ; keys_pressed = 0
  ; unsaved = []
  }
;;

let advance st ~budget ~until_ready =
  if until_ready then advance_until_ready st ~budget else advance_blind st ~budget
;;

(* ---------- the program's own saves ---------- *)

(* A DOS game saves by writing a file, and Dos_machine keeps what the guest
   wrote only in its mount table. Without this a server restart, an eject or
   the next load took every campaign with it: the MSX 삼국지2 lane lost its
   Keepers' games that way. After every call that ran the guest, a file whose
   mounted contents differ from what is on disk is written to [saves_dir],
   and the next load of the same program mounts it over the inventory copy.

   A file the program deletes is not carried: the inventory copy comes back
   at the next load. None of the games this lane runs delete their saves. *)

let write_atomically ~dir name contents =
  let path = Filename.concat dir name in
  let tmp = Filename.concat dir ("." ^ name ^ ".tmp") in
  Out_channel.with_open_bin tmp (fun oc -> output_string oc contents);
  Sys.rename tmp path
;;

let rec mkdir_p dir =
  if not (Sys.file_exists dir) then begin
    mkdir_p (Filename.dirname dir);
    Sys.mkdir dir 0o755
  end
;;

(* A name a file may be kept under: one plain name, never a path or a drive.
   The inventory's names pass the same test, and so does every name a guest
   creates before it reaches [saves_dir] -- DOS accepts "/" as a separator,
   and a guest asked for a save name will take "../../X". *)
let escapes name =
  String.contains name '/'
  || String.contains name '\\'
  || String.contains name ':'
  || String.equal name ".."
  || String.starts_with ~prefix:"." name
;;

(* Writes every changed file and returns what did not reach disk, one line
   per file. A file is recorded as kept only once it is on disk, so a failed
   write is tried again after the next call. A name that is a path is never
   written; it is recorded as seen so it is reported once, not on every call. *)
let keep_writes st =
  List.filter_map
    (fun name ->
      match Dos_machine.read_mounted st.m name with
      | None -> None
      | Some now ->
        (match Hashtbl.find_opt st.kept name with
         | Some before when String.equal before now -> None
         | _ when escapes name ->
           Hashtbl.replace st.kept name now;
           Some (name ^ ": a path, not a file name; it stays in this machine only")
         | _ ->
           (match
              mkdir_p st.saves_dir;
              write_atomically ~dir:st.saves_dir name now
            with
            | () ->
              Hashtbl.replace st.kept name now;
              None
            | exception Sys_error message -> Some (name ^ ": " ^ message))))
    (Dos_machine.mounted_names st.m)
;;

(* Every call that ran the guest ends here. The guest has moved whatever the
   disk did, so the observation always comes back; a save that did not reach
   disk rides along in [unsaved] instead of turning the call into an error a
   caller would answer by sending the same keys again. *)
let ran_then_kept st ran = Ok (observe st, { ran with unsaved = keep_writes st })

(* The saves over the inventory, matched the way DOS matches names. Read
   under the machine's lock by [load], so a save the running machine writes
   cannot land between this read and the new machine's first record of it. *)
let with_saves ~saves_dir files =
  match
    if Sys.file_exists saves_dir && Sys.is_directory saves_dir then
      Sys.readdir saves_dir
      |> Array.to_list
      |> List.filter (fun f -> not (escapes f))
      |> List.filter (fun f -> not (Sys.is_directory (Filename.concat saves_dir f)))
      |> List.map (fun f ->
        (f, In_channel.with_open_bin (Filename.concat saves_dir f) In_channel.input_all))
    else []
  with
  | exception Sys_error message -> Error (Unreadable message)
  | saved ->
    let folded (name, _) = String.uppercase_ascii name in
    let inventory_only =
      List.filter (fun f -> not (List.exists (fun s -> folded s = folded f) saved)) files
    in
    Ok (inventory_only @ saved)
;;

(* ---------- lifecycle ---------- *)

(* DOS folds filenames to upper case, so DATA.DAT and data.dat are one name to
   the guest: mounting both leaves one shadowing the other while the
   observation still lists two, and the program reads bytes the inventory does
   not appear to hold. A host that keeps them apart is not a reason to guess
   which one the program meant. *)
let dos_name_collision files =
  let rec go seen = function
    | [] -> None
    | (name, _) :: rest ->
      let folded = String.uppercase_ascii name in
      (match List.assoc_opt folded seen with
       | Some earlier -> Some (earlier, name)
       | None -> go ((folded, name) :: seen) rest)
  in
  go [] files
;;

let is_mz image =
  String.length image >= 2 && Char.equal image.[0] 'M' && Char.equal image.[1] 'Z'
;;

let load ~who ~ledger_dir ~saves_dir ~program_name ~program_bytes ~files ~announce =
  locked (fun () ->
    match Option.map (refuse_other ~who) !state with
    | Some (Error e) -> Error e
    | Some (Ok ()) | None ->
    match with_saves ~saves_dir files with
    | Error e -> Error e
    | Ok files ->
    if String.length program_bytes = 0 then
      Error (Invalid_request (Printf.sprintf "%s is empty" program_name))
    else
      match dos_name_collision files with
      | Some (earlier, later) ->
        Error
          (Invalid_request
             (Printf.sprintf "%s and %s are one name to DOS; the guest can only see one"
                earlier later))
      | None ->
        (* A new machine starts a new ledger. *)
        let ledger_path = Filename.concat ledger_dir "ledger.jsonl" in
        match
          mkdir_p ledger_dir;
          Out_channel.with_open_bin ledger_path (fun _ -> ())
        with
        | exception Sys_error message -> Error (Unreadable message)
        | () -> begin
        let m = Dos_machine.create () in
        List.iter (fun (name, contents) -> Dos_machine.mount_file m name contents) files;
        (* The image's own bytes choose the loader, not its name: an MZ header is
           a relocatable EXE, anything else is a flat COM at 0x100. A misnamed
           file still boots the way DOS would boot it. *)
        if is_mz program_bytes then Dos_machine.load_exe m program_bytes
        else Dos_machine.load_com m program_bytes;
        let kept = Hashtbl.create (List.length files) in
        List.iter
          (fun (name, contents) -> Hashtbl.replace kept (String.uppercase_ascii name) contents)
          files;
        let st =
          { m; steps = 0; program = program_name; ledger_path; entries = []; saves_dir; kept
          ; controller = Some who; incarnation = Random_id.uuid_v7 () }
        in
        state := Some st;
        let booted =
          running (fun () ->
            let ran = advance st ~budget:boot_steps ~until_ready:true in
            ran_then_kept st ran)
        in
        (* Announced once the machine is the workspace's and has booted as far
           as it will, still under the lock so announcements keep machine
           order. *)
        announce ();
        booted
      end)
;;

let eject ~who ~announce () =
  locked (fun () ->
    match !state with
    | None -> Error No_machine
    | Some st ->
      (match refuse_other st ~who with
       | Error e -> Error e
       | Ok () ->
         state := None;
         announce ();
         Ok ()))
;;

let pass ~who ~to_ ~announce =
  with_machine (fun st ->
    match refuse_other st ~who with
    | Error e -> Error e
    | Ok () ->
      st.controller <- to_;
      announce ();
      Ok (observe st))
;;

let screen () = with_machine (fun st -> Ok (observe st))

type frame = { width : int; height : int; rgb : string }

let capture () =
  with_machine (fun st ->
    let width, height = Dos_machine.frame_dims st.m in
    Ok (observe st, { width; height; rgb = Dos_machine.frame_rgb st.m }))
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
    let width, height = Dos_machine.frame_dims st.m in
    Ok
      { incarnation = st.incarnation
      ; observation = observe st
      ; frame = { width; height; rgb = Dos_machine.frame_rgb st.m }
      ; input_count = List.length st.entries
      ; input_ledger = st.entries
      })
;;

let step ~who ~steps ~until_ready =
  with_control ~who (fun st ->
    match clamp_steps steps with
    | Error e -> Error e
    | Ok budget ->
      let ran = advance st ~budget ~until_ready in
      ran_then_kept st ran)
;;

(* ---------- input ---------- *)

let resolve_keys names =
  List.fold_left
    (fun acc name ->
      match acc with
      | Error _ -> acc
      | Ok resolved ->
        (match Dos_machine.key_of_string name with
         | Ok word -> Ok ((name, word) :: resolved)
         | Error message -> Error (Invalid_request message)))
    (Ok [])
    names
  |> Result.map List.rev
;;

(* A sequence spends one ceiling, not one per key. [budget] is what a single
   key may take -- a menu that repaints slowly needs room -- but the call as a
   whole stops at [max_steps_per_call], the same ceiling one masc_dos_step
   runs under. Per-key budgets multiply: sixty-four keys at four million each
   is a quarter of a billion instructions held under the machine's mutex,
   with every other keeper queued behind it. A sequence that runs out comes
   back with [keys_pressed] below what was asked, and the caller sends the
   rest; the keys not pressed are not in the ledger and never reached the
   ring. *)
let press_resolved st ~who ~keys ~budget =
  let total = ref 0 and requests = ref 0 and pressed = ref 0 in
  let last_settled = ref false in
  List.iter
    (fun (name, word) ->
      let left = max_steps_per_call - !total in
      (* A key goes in only when the machine is ready for it. If the previous
         key left the program busy -- a fade, a load, an AI turn -- the next
         one would land in whatever loop is running, and a "press any key"
         wait or a skip check eats it. On 삼국지3 that turned a copy-protection
         code typed during the fade into a wrong code, and the game exited.
         The rest of the sequence is not sent; keys_pressed says where it
         stopped. *)
      let ready = !pressed = 0 || !last_settled in
      if left > 0 && ready then begin
        append_entry st { at_step = st.steps; who; key_name = name };
        Dos_machine.push_key st.m word;
        let ran = advance_until_ready st ~budget:(min budget left) in
        total := !total + ran.steps_run;
        requests := !requests + ran.input_requests;
        last_settled := ran.settled;
        incr pressed
      end)
    keys;
  { steps_run = !total
  ; settled = !last_settled
  ; input_requests = !requests
  ; keys_pressed = !pressed
  ; unsaved = []
  }
;;

let press ~who ~keys ~steps =
  with_control ~who (fun st ->
    if keys = [] then Error (Invalid_request "keys must name at least one key")
    else if List.length keys > max_keys_per_call then
      Error
        (Invalid_request
           (Printf.sprintf "keys may name at most %d keys, got %d" max_keys_per_call
              (List.length keys)))
    else
      match clamp_steps steps with
      | Error e -> Error e
      | Ok budget ->
        (* Every name is resolved before anything is pressed: a typo must not
           leave half a sequence in the ring. *)
        (match resolve_keys keys with
         | Error e -> Error e
         | Ok resolved ->
           let ran = press_resolved st ~who ~keys:resolved ~budget in
           ran_then_kept st ran))
;;

(* The mouse is state, not a queue. A key enters the ring and is gone; the
   cursor and buttons stay where they are put until someone moves them. That
   is why a click is one call doing two settings -- button down, then button
   up -- with the run split between them: a game that polls INT 33h or the
   BIOS data area reads the same press-and-release a human makes of it. The
   down half waits for ready like a key would, so a text-mode program that
   reacts and blocks costs no more than it needs; the up half always runs,
   whatever the down half saw, or the button would stay held for the next
   caller. A move ([buttons = 0]) sets the position and runs once. *)
let click ~who ~x ~y ~buttons ~steps =
  with_control ~who (fun st ->
    let width, height = Dos_machine.frame_dims st.m in
    if x < 0 || y < 0 || x >= width || y >= height then
      Error
        (Invalid_request
           (Printf.sprintf "click must land inside the %dx%d frame, got (%d,%d)"
              width height x y))
    else if buttons < 0 || buttons > 2 then
      Error (Invalid_request "buttons is a bitmask: 0 move, 1 left, 2 right")
    else
      match clamp_steps steps with
      | Error e -> Error e
      | Ok budget ->
        append_entry st
          { at_step = st.steps; who; key_name = Printf.sprintf "mouse(%d,%d,%d)" x y buttons };
        Dos_machine.set_mouse st.m ~x ~y ~buttons;
        if buttons = 0 then begin
          let ran = advance st ~budget ~until_ready:true in
          ran_then_kept st ran
        end
        else begin
          let half = max 1 (budget / 2) in
          let down = advance st ~budget:half ~until_ready:true in
          Dos_machine.set_mouse st.m ~x ~y ~buttons:0;
          let up = advance st ~budget:(budget - down.steps_run) ~until_ready:true in
          ran_then_kept st
            { steps_run = down.steps_run + up.steps_run
              ; settled = down.settled && up.settled
              ; input_requests = down.input_requests + up.input_requests
              ; keys_pressed = 0
              ; unsaved = []
              }
        end)
;;

let type_text ~who ~text ~steps =
  with_control ~who (fun st ->
    if String.length text = 0 then Error (Invalid_request "text must not be empty")
    else if String.length text > max_text_length then
      Error
        (Invalid_request
           (Printf.sprintf "text may be at most %d characters, got %d" max_text_length
              (String.length text)))
    else
      match clamp_steps steps with
      | Error e -> Error e
      | Ok budget ->
        let names = List.init (String.length text) (fun i -> String.make 1 text.[i]) in
        (match resolve_keys names with
         | Error e -> Error e
         | Ok resolved ->
           let ran = press_resolved st ~who ~keys:resolved ~budget in
           ran_then_kept st ran))
;;

(* ---------- introspection ---------- *)

let peek ~address ~length =
  with_machine (fun st ->
    if address < 0 || address > 0xFFFFF then
      Error (Invalid_request (Printf.sprintf "address must be 0..0xFFFFF, got %d" address))
    else if length < 1 || length > peek_max_bytes then
      Error
        (Invalid_request
           (Printf.sprintf "length must be 1..%d, got %d" peek_max_bytes length))
    else begin
      let b = Buffer.create (length * 2) in
      for i = 0 to length - 1 do
        Buffer.add_string b
          (Printf.sprintf "%02x" (Dos_machine.mem_read st.m ((address + i) land 0xFFFFF)))
      done;
      Ok (Buffer.contents b)
    end)
;;

let ledger () =
  locked (fun () ->
    match !state with
    | None -> []
    | Some st -> List.rev st.entries)
;;
