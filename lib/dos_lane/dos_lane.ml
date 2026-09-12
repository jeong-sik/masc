(* The workspace DOS machine and its input ledger. See dos_lane.mli. *)

type observation = {
  steps : int;
  video_mode : int;
  width : int;
  height : int;
  cs : int;
  ip : int;
  exited : bool;
  exit_code : int;
  halted : bool;
  waiting_for_key : bool;
  ticks : int;
  screen_text : string;
  program : string option;
  files : string list;
}

type entry = { at_step : int; who : string; key_name : string }

type error =
  | No_machine
  | Invalid_request of string
  | Unreadable of string

let error_to_string = function
  | No_machine -> "no DOS machine is loaded: call masc_dos_load first"
  | Invalid_request message -> message
  | Unreadable message -> message
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

(* ---------- observation ---------- *)

let observe st =
  let m = st.m in
  let cpu = Dos_machine.cpu_of m in
  let width, height = Dos_machine.frame_dims m in
  {
    steps = st.steps;
    video_mode = Dos_machine.video_mode m;
    width;
    height;
    cs = Cpu86.seg cpu 1;
    ip = Cpu86.dump_ip cpu;
    exited = Dos_machine.exited m;
    exit_code = Dos_machine.exit_code m;
    halted = Dos_machine.halted m;
    waiting_for_key = Dos_machine.kbd_waiting m;
    ticks = Dos_machine.tick_count m;
    screen_text = Dos_machine.screen_text_utf8 m;
    program = Some st.program;
    files = Dos_machine.mounted_names m;
  }
;;

(* ---------- ledger ---------- *)

let entry_json e : Yojson.Safe.t =
  `Assoc
    [ ("step", `Int e.at_step); ("who", `String e.who); ("key", `String e.key_name) ]
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

let rec mkdir_p dir =
  if not (Sys.file_exists dir) then begin
    mkdir_p (Filename.dirname dir);
    Sys.mkdir dir 0o755
  end
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
  }
;;

let advance st ~budget ~until_ready =
  if until_ready then advance_until_ready st ~budget else advance_blind st ~budget
;;

(* ---------- lifecycle ---------- *)

let is_mz image =
  String.length image >= 2 && Char.equal image.[0] 'M' && Char.equal image.[1] 'Z'
;;

let load ~ledger_dir ~program_name ~program_bytes ~files =
  locked (fun () ->
    if String.length program_bytes = 0 then
      Error (Invalid_request (Printf.sprintf "%s is empty" program_name))
    else begin
      let m = Dos_machine.create () in
      List.iter (fun (name, contents) -> Dos_machine.mount_file m name contents) files;
      (* The image's own bytes choose the loader, not its name: an MZ header is
         a relocatable EXE, anything else is a flat COM at 0x100. A misnamed
         file still boots the way DOS would boot it. *)
      if is_mz program_bytes then Dos_machine.load_exe m program_bytes
      else Dos_machine.load_com m program_bytes;
      mkdir_p ledger_dir;
      let ledger_path = Filename.concat ledger_dir "ledger.jsonl" in
      (* A new machine starts a new ledger. *)
      Out_channel.with_open_bin ledger_path (fun _ -> ());
      let st =
        { m; steps = 0; program = program_name; ledger_path; entries = [] }
      in
      state := Some st;
      let ran = advance st ~budget:boot_steps ~until_ready:true in
      Ok (observe st, ran)
    end)
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

let step ~steps ~until_ready =
  with_machine (fun st ->
    match clamp_steps steps with
    | Error e -> Error e
    | Ok budget ->
      let ran = advance st ~budget ~until_ready in
      Ok (observe st, ran))
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
      if left > 0 then begin
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
  }
;;

let press ~who ~keys ~steps =
  with_machine (fun st ->
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
           Ok (observe st, ran)))
;;

let type_text ~who ~text ~steps =
  with_machine (fun st ->
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
           Ok (observe st, ran)))
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
