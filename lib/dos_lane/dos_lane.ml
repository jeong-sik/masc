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

type ran = { steps_run : int; reached_input : bool }

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

(* Runs the budget, stopping early when the guest asks the BIOS for a key and
   finds none. That starvation is the machine saying "your turn" — it is a
   fact the core reports, not a settled-screen guess. *)
let advance st ~budget ~until_input =
  let m = st.m in
  let stop mm = until_input && Dos_machine.kbd_waiting mm in
  let n = Dos_machine.run_until m ~max_steps:budget ~stop in
  st.steps <- st.steps + n;
  { steps_run = n; reached_input = until_input && n < budget && not (Dos_machine.exited m) }
;;

(* After a key goes into the ring: run until the guest has taken it and asks
   for the next one. The latch stays up until a read succeeds, so wait for it
   to go down once before treating it as a fresh request. *)
let advance_after_key st ~budget =
  let m = st.m in
  let taken = ref false in
  let stop mm =
    if not (Dos_machine.kbd_waiting mm) then taken := true;
    !taken && Dos_machine.kbd_waiting mm
  in
  let n = Dos_machine.run_until m ~max_steps:budget ~stop in
  st.steps <- st.steps + n;
  { steps_run = n; reached_input = n < budget && not (Dos_machine.exited m) }
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
      let ran = advance st ~budget:boot_steps ~until_input:true in
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

let step ~steps ~until_input =
  with_machine (fun st ->
    match clamp_steps steps with
    | Error e -> Error e
    | Ok budget ->
      let ran = advance st ~budget ~until_input in
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

let press_resolved st ~who ~keys ~budget =
  let total = ref 0 in
  let last_reached = ref false in
  List.iter
    (fun (name, word) ->
      append_entry st { at_step = st.steps; who; key_name = name };
      Dos_machine.push_key st.m word;
      let ran = advance_after_key st ~budget in
      total := !total + ran.steps_run;
      last_reached := ran.reached_input)
    keys;
  { steps_run = !total; reached_input = !last_reached }
;;

let press ~who ~keys ~steps =
  with_machine (fun st ->
    if keys = [] then Error (Invalid_request "keys must name at least one key")
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

let read_guest_file ~name =
  with_machine (fun st ->
    match Dos_machine.read_mounted st.m name with
    | Some contents -> Ok contents
    | None ->
      Error (Invalid_request (Printf.sprintf "the guest has no file named %S" name)))
;;

let ledger () =
  locked (fun () ->
    match !state with
    | None -> []
    | Some st -> List.rev st.entries)
;;
