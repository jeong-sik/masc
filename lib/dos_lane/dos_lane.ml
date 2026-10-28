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
  saves_name : string option;
  controller : string option;
  files : string list;
}

type entry = { at_step : int; who : string; key_name : string }

type autosave_status = { program : string; steps : int; saved_by : string; mtime : float }

type autosave_lookup =
  | No_autosave
  | Autosave of autosave_status
  | Autosave_unreadable of string

(* What a slot holds, as far as it can be said: its status, or that the file
   is there and will not read. *)
type held_autosave =
  | Held of autosave_status
  | Held_unreadable of string

(* A new incarnation's first autosave copies the autosave to the
   previous-autosave slot, so it replaces what that slot held. A load, or a
   restore of a named slot, starts such an incarnation: it is the act that
   discards the previous autosave, and it is the consent for that act that is
   asked for. With no previous autosave nothing is discarded: the autosave
   moves to the slot and survives there. A restore of either autosave slot
   discards nothing and is not asked ([check_restore_consent]). *)
type previous_autosave_consent =
  | Keep_previous_autosave
  | Discard_previous_autosave

(* Both files a start would touch: [previous] is what it would discard and
   [current] is what moves into its place. *)
type discard =
  { previous : held_autosave
  ; current : held_autosave
  }

type error =
  | Activity_disabled
  | Activity_unobserved
  | No_machine
  | Invalid_request of string
  | Unreadable of string
  | Held_by of string
  | Guest_fault of string
  | Unsaveable of string
  | Checkpoint_refused of Machine_checkpoint.error
  | Other_program of { expected : string; loaded : string }
  | Would_discard_previous_autosave of discard

let error_to_string = function
  | Activity_disabled -> "machines.dos is off; enable it before new machine work"
  | Activity_unobserved -> "Machine activity configuration is unavailable"
  | No_machine -> "no DOS machine is loaded"
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
  | Unsaveable message -> "the machine cannot be checkpointed right now, so nothing was written: " ^ message
  | Checkpoint_refused e -> Machine_checkpoint.error_to_string e
  | Other_program { expected; loaded } ->
    Printf.sprintf "%s is loaded now, not %s, so nothing was pressed" loaded expected
  | Would_discard_previous_autosave { previous = Held s; current = _ } ->
    Printf.sprintf
      "the previous autosave (%s, %d steps, saved by %s) would be replaced, so nothing was done"
      s.program s.steps s.saved_by
  | Would_discard_previous_autosave { previous = Held_unreadable reason; current = _ } ->
    Printf.sprintf
      "the previous autosave file cannot be read (%s) and would be replaced, so nothing was done"
      reason
;;

open Result.Syntax
let activity_observer : (unit -> Machine_configuration.activity) option Atomic.t = Atomic.make None
let install_activity_observer observer = Atomic.set activity_observer observer
let activity () = match Atomic.get activity_observer with
  | None -> Machine_configuration.Unobserved
  | Some observe -> observe ()
let require_activity () = match activity () with
  | Machine_configuration.Enabled -> Ok ()
  | Disabled -> Error Activity_disabled
  | Unobserved -> Error Activity_unobserved

(* A call consumes at most this many machine execution steps, including
   idle waits. Actual guest instruction counts are reported separately. *)
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

(* ---------- which core ---------- *)

type core = {
  source_digest : string;
  pinned_source_digest : string;
  matches_pin : bool;
}
[@@deriving yojson]

(* The digest ocaml-dos reports for the sources at OCAML_DOS_SHA in
   scripts/opam-pin-external-deps.sh. Bump the two together: CI links the
   pinned core, and test_dos_tools checks that the linked digest equals this
   one, so a SHA bumped alone turns that test red with the new digest in its
   message. Read the digest of a commit from its build:
   _build/default/lib/identity/dos_core_identity.ml. *)
let pinned_core_source_digest = "dcc7a239c2cacba739a9819be3e46b2e"

let core =
  { source_digest = Dos_core_identity.source_digest
  ; pinned_source_digest = pinned_core_source_digest
  ; matches_pin = String.equal Dos_core_identity.source_digest pinned_core_source_digest
  }

(* What the autosave at the end of a call did. [Not_attempted] is the value a
   [ran] starts with, and the one a program that has exited keeps: there is
   nothing left to resume. *)
type autosave =
  | Not_attempted
  | Autosaved
  | Autosave_failed of string

type ran = {
  steps_run : int;
  instructions_run : int;
  elapsed_cycles : int;
  settled : bool;
  input_requests : int;
  keys_pressed : int;
  unsaved : string list;
  autosave : autosave;
}

(* How a load's boot ended. The machine is installed and the loader holds the
   controller either way, so a guest fault during boot is a result, not an
   error: an error tells the caller nothing was loaded. *)
type boot_fault =
  | Unimplemented_instruction of string
  | Core_exception of string

type boot =
  | Booted of ran
  | Boot_faulted of boot_fault

(* What a manual save found in its slot. Reads like [autosave_lookup]: a file
   that is there and will not read is its own answer. *)
type replaced =
  | Fresh_slot
  | Replaced of autosave_status
  | Replaced_unreadable of string

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
  checkpoint_dir : string;
      (* Where this machine's autosave goes: the directory [save] and
         [restore] read named checkpoints from. *)
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
  mutable previous_kept : bool;
      (* Whether the autosave this machine finds needs no keeping. A loaded
         machine, or one restored from a named slot or the previous autosave,
         starts false: its first autosave finds a file another history wrote,
         and [autosave_after] copies it to [autosave_prev_slot] before it
         writes. Once the copy is on disk this is true and it is not made
         again, even if the write that follows fails: a second copy would put
         this machine's own history over the one it was keeping. A machine
         restored from the autosave starts true: that file is the last save of
         the history it carries on ([previous_kept_on_restore]). Every write
         with this true is this history replacing its own last save. *)
  mutable resume_marked : bool;
      (* Whether this incarnation wrote the resume mark since it last removed
         it, so a successful autosave writes the mark once, not on every call.
         See [resume_mark_path]. *)
}

let state : machine option ref = ref None
let lock = Mutex.create ()
let locked f = Mutex.protect lock f

type change_mark = { count : int; incarnation : string }

(* The machine change counter a spectator compares against, one per process,
   written only while holding [lock]. It is not [steps]: a guest fault raises
   out of the core before [steps] moves, so a faulting run can leave [steps]
   where it was while the attempt still happened. [running] marks every
   completed run, including a guest fault, in one place. A call refused
   before running leaves the count alone. A load also marks when it installs
   the new machine, an eject marks when it drops it, and nothing resets the
   count, so one value never names two screens while the server runs.

   [published] also records when a run holds the lock. A spectator may answer
   unchanged from a Stable mark, but a Running mark must wait for the final
   frame even when its count matches [since]. *)
let change_count = ref 0
type 'mark publication = 'mark Machine_live_publication.t =
  | No_screen
  | Stable of 'mark
  | Running of 'mark
type published_state = change_mark publication
let published : published_state Atomic.t = Atomic.make No_screen

let publish make =
  Atomic.set published
    (match !state with
     | None -> No_screen
     | Some st -> make { count = !change_count; incarnation = st.incarnation })
;;

let publish_stable () = publish (fun mark -> Stable mark)
let publish_running () = publish (fun mark -> Running mark)
let mark_change () = incr change_count; publish_stable ()
let current_publication () = Atomic.get published

(* A short spectator feed of what a Keeper did to this Lane -- one line per
   call -- not the replay ledger on [machine.entries], which only presses
   belong to and which a checkpoint replays for continuity.

   Read lock-free, like [published]: [with_control]/[with_machine] hold
   [lock] for the emulation itself, not just a state swap -- up to
   [max_steps_per_call] (about 170ms, this file's own measurement) -- and the
   live HTTP route reads this from the fast path that answers without a
   locked read at all, on the server's main fiber. A [Mutex.protect] there
   could stall on a press or step in flight; [Atomic.get] cannot.

   Written only from call sites that already hold [lock], same as
   [published]'s writes, so the two are never torn relative to each other.
   Capped by {!Machine_action_feed.push} rather than kept whole. It outlives an
   eject on purpose -- "who ejected it" is itself an answer a spectator
   watching the screen go blank wants -- and is never otherwise reset: a load
   or restore is one more line on the same feed, not a new one, so the
   Lane's timeline reads as continuous. *)
let activity_feed : Machine_action_feed.entry list Atomic.t = Atomic.make []

let note_activity ~who action =
  Atomic.set activity_feed
    (Machine_action_feed.push { Machine_action_feed.at = Time_compat.now (); who; action } (Atomic.get activity_feed))
;;

let recent_activity () = Atomic.get activity_feed

(* ---------- the resume mark ----------

   A file beside the autosave that records one durable fact: the autosave holds
   the running machine's latest state. A worker that starts restores the
   autosave only when the mark is there ([resume_autosave]). It is a record,
   not a gate on Keepers: nothing a Keeper asks for is refused by it. Without
   it a restart cannot tell the autosave of a machine that was still running
   from one a machine left behind when it was ejected, exited or faulted, and
   would bring that machine back; an exited program's stale mounted file would
   then overwrite a newer game save in its saves directory, a loss
   uninterrupted play never has.

   A machine writes the mark after a successful autosave, once until it next
   removes it. It is removed whenever the autosave stops holding what the
   machine is: a load or a restore of another slot installs a different
   machine, the program exits, an autosave fails, a run ends without one (a
   guest fault, a ledger that will not take a line, an exception), or the
   machine is ejected. The name has no checkpoint extension, so no listing of
   the directory shows it as a slot. *)
let resume_mark_path ~dir = Filename.concat dir "autosave.current"

let write_resume_mark st =
  if st.resume_marked then Ok ()
  else
    match
      Fs_compat.save_file_atomic (resume_mark_path ~dir:st.checkpoint_dir)
        "the autosave holds the running machine's latest state\n"
    with
    | Ok () ->
      st.resume_marked <- true;
      Ok ()
    | Error message -> Error message
;;

(* No file, or no directory for it to be in: either way there is no mark. *)
let remove_resume_mark ~dir =
  match Unix.unlink (resume_mark_path ~dir) with
  | () -> Ok ()
  | exception Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) -> Ok ()
  | exception Unix.Unix_error (error, _, path) -> Error (path ^ ": " ^ Unix.error_message error)
;;

(* A load, or a restore of another slot, removes the mark before it installs
   its machine. The machine running now has no mark on disk from here: if the
   install then fails, that machine keeps running and its next autosave
   writes the mark again. *)
let remove_resume_mark_for_install ~dir =
  match remove_resume_mark ~dir with
  | Error message -> Error message
  | Ok () ->
    Option.iter (fun running -> running.resume_marked <- false) !state;
    Ok ()
;;

(* [st]'s autosave no longer holds what [st] is. *)
let forget_resume_mark st =
  st.resume_marked <- false;
  remove_resume_mark ~dir:st.checkpoint_dir
;;

let mark_not_removed message =
  "the mark that lets a restart resume the autosave could not be removed, so a restart \
   would bring that autosave back: "
  ^ message
;;

(* A load, a restore of another slot, or an eject removes the mark before it
   changes the machine. If the mark stays, a restart would bring back the
   machine that call replaced, so the call is refused and nothing changes. *)
let refused_for_mark ~nothing_was message =
  Unreadable
    (Printf.sprintf
       "the mark that lets a restart resume the autosave could not be removed, so nothing \
        was %s (a restart would bring back the machine running now): %s"
       nothing_was message)
;;

(* [reason] with what removing the mark did, so a removal that fails is
   reported beside what made it necessary and never dropped. *)
let reason_and_forget st reason =
  match forget_resume_mark st with
  | Ok () -> reason
  | Error message -> reason ^ "; " ^ mark_not_removed message
;;

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
  publish_running ();
  let result =
    match f () with
    | result -> result
    | exception Cpu86.Unsupported message -> Error (Guest_fault message)
    | exception Sys_error message -> Error (Unreadable message)
    | exception exn ->
      let backtrace = Printexc.get_raw_backtrace () in
      mark_change ();
      Printexc.raise_with_backtrace exn backtrace
  in
  (match result with
   | Ok _ | Error (Unreadable _ | Guest_fault _) -> mark_change ()
   | Error
       ( Activity_disabled | Activity_unobserved | No_machine | Invalid_request _ | Held_by _ | Unsaveable _ | Checkpoint_refused _
       | Other_program _ | Would_discard_previous_autosave _ ) ->
     publish_stable ());
  result
;;

let refuse_other st ~who =
  match st.controller with
  | Some holder when not (String.equal holder who) -> Error (Held_by holder)
  | Some _ | None -> Ok ()
;;

let with_control ~who f =
  let* () = require_activity () in
  with_machine (fun st ->
    match refuse_other st ~who with
    | Error e -> Error e
    | Ok () ->
      (* Taken before the call so the observation it returns names the new
         holder, and given back if the call is refused. *)
      let before = st.controller in
      st.controller <- Some who;
      let result =
        match running (fun () -> f st) with
        | result -> result
        | exception exn ->
          (* Not one of the outcomes [running] types, so nothing says the call
             ran. The caller is about to be told it failed, and must not be
             left holding the pad for a call it was told did nothing. The
             guest may have moved without an autosave, so the mark goes; a
             removal that fails goes on the activity feed, since the
             exception is the answer. *)
          let backtrace = Printexc.get_raw_backtrace () in
          st.controller <- before;
          (match forget_resume_mark st with
           | Ok () -> ()
           | Error message -> note_activity ~who (mark_not_removed message));
          Printexc.raise_with_backtrace exn backtrace
      in
      match result with
      | Ok _ -> result
      (* The call ran and ended without an autosave: the machine may have
         moved past it, so the autosave no longer holds what it is. *)
      | Error (Unreadable message) -> Error (Unreadable (reason_and_forget st message))
      | Error (Guest_fault message) -> Error (Guest_fault (reason_and_forget st message))
      | Error
          ( Activity_disabled | Activity_unobserved | No_machine | Invalid_request _ | Held_by _ | Unsaveable _ | Checkpoint_refused _
          | Other_program _ | Would_discard_previous_autosave _ ) ->
        st.controller <- before;
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

(* The name the program's saves are kept under: masc_dos_load keeps them in
   a directory named after the inventory entry. *)
let saves_name_of st = Filename.basename st.saves_dir

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
    saves_name = Some (saves_name_of st);
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

(* [run_until] calls [stop] once per completed machine step, including idle
   wait clocks. Preserve that execution clock for the input ledger and its
   deterministic timing. The report separately counts guest instructions.
   Keep the clock aligned after a fault, before returning its original trace. *)
let run_counted st ~max_steps =
  let completed = ref 0 in
  match
    Dos_machine.run_until st.m ~max_steps ~stop:(fun _ ->
      incr completed;
      false)
  with
  | report ->
    st.steps <- st.steps + report.Dos_machine.machine_steps;
    report
  | exception fault ->
    let backtrace = Printexc.get_raw_backtrace () in
    st.steps <- st.steps + !completed;
    Printexc.raise_with_backtrace fault backtrace
;;

(* Runs the budget straight through, with nothing watching. *)
let advance_blind st ~budget =
  let before = Dos_machine.input_requests st.m in
  let report = run_counted st ~max_steps:budget in
  { steps_run = report.Dos_machine.machine_steps
  ; instructions_run = report.Dos_machine.instructions
  ; elapsed_cycles = report.Dos_machine.elapsed_cycles
  ; settled = false
  ; input_requests = Dos_machine.input_requests st.m - before
  ; keys_pressed = 0
  ; unsaved = []
  ; autosave = Not_attempted
  }
;;

(* Runs until an empty keyboard poll overlaps unchanged screen memory.
   This observation is not proof that a game reached its next prompt:

   - the guest asked the BIOS for a key inside this chunk and the ring was
     empty, and
   - the screen memory is the same as it was one chunk ago.

   The first alone can stop mid-repaint. A program in its own loop takes a key and
   asks for the next one 631 instructions later (measured on ZZT) while the
   repaint it started is still half-written; stopping there hands the caller
   the picture from before their key, and the press looks like it did
   nothing. Both facts can also hold during a transition: 삼국지3 returned
   settled before its command menu appeared with no additional key. Callers
   can instead run an explicit machine-step allowance with [until_ready=false]. *)
let advance_until_ready st ~budget =
  let m = st.m in
  let requests_before = Dos_machine.input_requests m in
  let previous = ref (Dos_machine.screen_digest m) in
  let ran = ref 0 and instructions = ref 0 and cycles = ref 0 in
  let settled = ref false in
  while (not !settled) && !ran < budget && not (Dos_machine.exited m) do
    let asked_before = Dos_machine.input_requests m in
    let report = run_counted st ~max_steps:(min settle_chunk (budget - !ran)) in
    ran := !ran + report.Dos_machine.machine_steps;
    instructions := !instructions + report.Dos_machine.instructions;
    cycles := !cycles + report.Dos_machine.elapsed_cycles;
    let asked = Dos_machine.input_requests m > asked_before in
    let now = Dos_machine.screen_digest m in
    if asked && now = !previous then settled := true;
    previous := now
  done;
  { steps_run = !ran
  ; instructions_run = !instructions
  ; elapsed_cycles = !cycles
  ; settled = !settled
  ; input_requests = Dos_machine.input_requests m - requests_before
  ; keys_pressed = 0
  ; unsaved = []
  ; autosave = Not_attempted
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

(* The lane's part of a checkpoint: what the machine bytes do not carry. The
   machine bytes are Dos_snapshot's and carry their own format; this number
   covers the meta beside them. Bump it by hand when [checkpoint_meta] changes
   shape or meaning -- a checkpoint of any other number is refused, and
   nothing reads an old one. *)
let checkpoint_format = 1

(* The one slot autosave writes to. A literal that never fails
   [Machine_checkpoint.slot_of_string] -- "autosave" is 8 lowercase letters --
   parsed once here so every caller shares the same validated value instead
   of a string repeated at each call site. *)
let autosave_slot =
  match Machine_checkpoint.slot_of_string "autosave" with
  | Ok s -> s
  | Error message -> failwith message
;;

(* Where a new incarnation's first autosave copies whatever [autosave_slot]
   already held, before writing its own state there. That prior file is
   another history's last autosave, and a fresh load's or a named restore's
   first write must not erase it silently. *)
let autosave_prev_slot =
  match Machine_checkpoint.slot_of_string "autosave-prev" with
  | Ok s -> s
  | Error message -> failwith message
;;

(* A slot name is either one the lane writes itself or one a caller chose. A
   manual save may only take the second kind: [masc_dos_save slot=autosave]
   used to replace the file every load and restore offers back, with no
   confirmation. Names are compared without case because a case-folding
   filesystem maps "AUTOSAVE" onto autosave.ckpt. *)
type named_slot = Machine_checkpoint.slot

type slot =
  | Named of named_slot
  | Current_autosave
  | Previous_autosave

let classify_slot slot =
  let name = String.lowercase_ascii (Machine_checkpoint.slot_to_string slot) in
  if String.equal name (Machine_checkpoint.slot_to_string autosave_slot) then Current_autosave
  else if String.equal name (Machine_checkpoint.slot_to_string autosave_prev_slot) then
    Previous_autosave
  else Named slot
;;

let named_slot_to_string = Machine_checkpoint.slot_to_string

(* The file a classified slot names. A lane-owned slot names its canonical
   file however the caller spelled it: on a case-sensitive filesystem
   "AUTOSAVE.ckpt" is another file, and on a case-folding one a write counter
   keyed by that spelling would miss the lane's own writes to autosave.ckpt. *)
let checkpoint_slot = function
  | Named named -> named
  | Current_autosave -> autosave_slot
  | Previous_autosave -> autosave_prev_slot
;;

let checkpoint_meta st ~who : Yojson.Safe.t =
  `Assoc
    [ ("program", `String st.program)
    ; ("saves", `String (Filename.basename st.saves_dir))
    ; ("steps", `Int st.steps)
    ; ("saved_by", `String who)
    ; ("ledger", `List (List.rev_map entry_json st.entries))
    ]
;;

(* How many times this lane replaced each checkpoint file, keyed by its path,
   written only while holding [lock]. A restore reads its slot outside the
   lock; it records this count first and commit refuses when a lane save
   replaced the slot in between, so the restored machine is never older than
   the checkpoint the slot now holds. A path this lane never wrote counts 0. *)
let checkpoint_writes : (string, int) Hashtbl.t = Hashtbl.create 8

let checkpoint_write_count path =
  Option.value ~default:0 (Hashtbl.find_opt checkpoint_writes path)

let mark_checkpoint_write path =
  Hashtbl.replace checkpoint_writes path (checkpoint_write_count path + 1)

(* Writes the machine to [slot] under the lock the caller already holds. [save]
   and the autosave at the end of every run both go through here, so the two
   cannot disagree on what a checkpoint holds. *)
let write_checkpoint st ~who ~dir ~slot =
  let header =
    { Machine_checkpoint.machine = Machine_checkpoint.Dos
    ; format = checkpoint_format
    ; core = Dos_core_identity.source_digest
    }
  in
  match Dos_snapshot.save st.m with
  | Error e -> Error (Unsaveable (Dos_snapshot.save_error_to_string e))
  | Ok machine_bytes ->
    (match
       Machine_checkpoint.write ~dir slot header ~meta:(checkpoint_meta st ~who)
         ~machine_bytes
     with
     | Ok () ->
       mark_checkpoint_write (Machine_checkpoint.path ~dir slot);
       Ok ()
     | Error message -> Error (Unreadable message))
;;

(* Copies what [autosave_slot] holds to [autosave_prev_slot], so the file an
   incarnation's first autosave replaces survives it. A copy and not a rename:
   the autosave stays in place until the new one replaces it atomically, so a
   copy that fails, or a write that fails after it, leaves the autosave as it
   was. Nothing here is swallowed. No file at [autosave_slot] means there is
   nothing to keep. The copy is made from the lane's own file and not read as
   a checkpoint, so one this server cannot decode is kept like any other. *)
let keep_previous_autosave ~dir =
  if not (Sys.file_exists (Machine_checkpoint.path ~dir autosave_slot)) then Ok ()
  else
    match
      Machine_checkpoint.copy ~dir ~from:autosave_slot ~to_:autosave_prev_slot
    with
    | Ok () ->
      mark_checkpoint_write (Machine_checkpoint.path ~dir autosave_prev_slot);
      Ok ()
    | Error message -> Error message
;;

(* The autosave at the end of a call that ran the guest to an answer. It runs
   under the machine's lock inside [ran_then_kept], so the state it writes is
   the one the call's observation reports and no other Keeper's call lands
   between the two.

   A fault, a refusal and an unreadable ledger never get here: the machine
   left by a fault faults again on its next step, and writing it would replace
   the last resume point that works. A program that has exited has nothing to
   resume. A failed write is reported in [ran.autosave] and never turns the
   call into an error, because the guest moved either way.

   Until [previous_kept], the first autosave keeps whatever [autosave_slot]
   held, by copying it to [autosave_prev_slot] first: that file is another
   history's last save, and a load's or a named restore's very next call must
   not silently overwrite it. If the copy fails nothing is written and the
   reason is reported, so the old autosave stays and the next call tries
   again. Every autosave after that is this history replacing its own last
   save. A success writes the resume mark; an exit or a failure removes it. *)
let autosave_after st ~who =
  if Dos_machine.exited st.m then
    (* Nothing to resume: the autosave is the program before it exited. *)
    (match forget_resume_mark st with
     | Ok () -> Not_attempted
     | Error message -> Autosave_failed ("the program has exited, and " ^ mark_not_removed message))
  else begin
    let kept =
      if st.previous_kept then Ok () else keep_previous_autosave ~dir:st.checkpoint_dir
    in
    match kept with
    | Error message ->
      Autosave_failed
        (reason_and_forget st
           (Printf.sprintf "the previous autosave could not be kept, so nothing was written: %s"
              message))
    | Ok () ->
      st.previous_kept <- true;
      (match write_checkpoint st ~who ~dir:st.checkpoint_dir ~slot:autosave_slot with
       | Error e -> Autosave_failed (reason_and_forget st (error_to_string e))
       | Ok () ->
         (match write_resume_mark st with
          | Ok () -> Autosaved
          | Error message ->
            Autosave_failed
              ("the autosave was written, but the mark that lets a restart resume it was \
                not, so a restart would start with no machine: " ^ message)))
  end
;;

type restored_meta = {
  saved_program : string;
  saved_saves : string;
  saved_steps : int;
  saved_by : string;
  saved_ledger : entry list;  (* oldest first *)
}

(* Every field the lane wrote, or the checkpoint is corrupt: a missing step
   count is not zero and a missing ledger is not empty. *)
let meta_of_json json =
  let corrupt message = Error (Checkpoint_refused (Machine_checkpoint.Corrupt message)) in
  let field name =
    match json with
    | `Assoc fields -> List.assoc_opt name fields
    | _ -> None
  in
  let entry_of = function
    | `Assoc fields ->
      (match
         ( List.assoc_opt "step" fields
         , List.assoc_opt "who" fields
         , List.assoc_opt "key" fields )
       with
       | Some (`Int at_step), Some (`String who), Some (`String key_name) ->
         Some { at_step; who; key_name }
       | _ -> None)
    | _ -> None
  in
  match field "program", field "saves", field "steps", field "ledger", field "saved_by" with
  | ( Some (`String program)
    , Some (`String saves)
    , Some (`Int steps)
    , Some (`List items)
    , Some (`String saved_by) ) ->
    let ledger = List.filter_map entry_of items in
    let rec ordered previous = function
      | [] -> true
      | e :: rest -> e.at_step >= previous && e.at_step <= steps && ordered e.at_step rest
    in
    if List.length ledger <> List.length items then corrupt "a ledger line does not read"
    else if not (ordered 0 ledger) then corrupt "the ledger does not fit the saved step count"
    else if escapes saves || String.equal saves "" then corrupt "the saves name is a path"
    else Ok { saved_program = program; saved_saves = saves; saved_steps = steps; saved_by; saved_ledger = ledger }
  | _ -> corrupt "the lane's fields are missing"
;;

let snapshot_error_to_checkpoint_error = function
  | Dos_snapshot.Wrong_format { saved; supported } ->
    Machine_checkpoint.Other_format { saved; expected = supported }
  | (Dos_snapshot.Not_a_snapshot | Dos_snapshot.Corrupt _) as e ->
    Machine_checkpoint.Corrupt (Dos_snapshot.error_to_string e)
;;

let check_snapshot_header machine_bytes =
  match Dos_snapshot.header machine_bytes with
  | Error e -> Error (snapshot_error_to_checkpoint_error e)
  | Ok { Dos_snapshot.format; core = _ } ->
    if format <> Dos_snapshot.format_version then
      Error
        (Machine_checkpoint.Other_format
           { saved = format; expected = Dos_snapshot.format_version })
    else Ok ()
;;

(* Read only, through {!Machine_checkpoint}'s header, meta and {!Dos_snapshot.header}
   -- never {!Dos_snapshot.restore}, which would reconstruct the whole guest
   machine just to say who last saved it. The snapshot header and [meta_of_json]
   use the same format and metadata schema checks as restore. This lookup does
   not validate payload checksums, decoding, or guest consistency. A file that
   is there but will not read
   is its own answer: reporting it as "nothing there" would hide it until the
   next run replaced it. *)
let lookup_slot ~dir slot =
  match
    Machine_checkpoint.read ~dir slot ~machine:Machine_checkpoint.Dos
      ~format:checkpoint_format
  with
  | Error (Machine_checkpoint.No_slot _) -> No_autosave
  | Error
      ((Machine_checkpoint.Unreadable _
       | Machine_checkpoint.Other_machine _
       | Machine_checkpoint.Other_format _
       | Machine_checkpoint.Corrupt _) as e) ->
    Autosave_unreadable (Machine_checkpoint.error_to_string e)
  | Ok { Machine_checkpoint.meta; machine_bytes; header = _ } ->
    (match Unix.stat (Machine_checkpoint.path ~dir slot) with
     | exception Unix.Unix_error (e, _, _) ->
       Autosave_unreadable (Unix.error_message e)
     | st ->
       (match check_snapshot_header machine_bytes with
        | Error e -> Autosave_unreadable (Machine_checkpoint.error_to_string e)
        | Ok () ->
          (match meta_of_json meta with
           | Error e -> Autosave_unreadable (error_to_string e)
           | Ok m ->
             Autosave
               { program = m.saved_program
               ; steps = m.saved_steps
               ; saved_by = m.saved_by
               ; mtime = st.Unix.st_mtime
               })))
;;

let lookup_autosave ~dir = lookup_slot ~dir autosave_slot
;;

let lookup_previous_autosave ~dir = lookup_slot ~dir autosave_prev_slot
;;

(* Every call that ran the guest ends here. The guest has moved whatever the
   disk did, so the observation always comes back; a save that did not reach
   disk rides along in [unsaved] instead of turning the call into an error a
   caller would answer by sending the same keys again. The autosave is written
   after the game's own saves, and the record is built from named results so
   the order is not left to the compiler. *)
let ran_then_kept st ~who ran =
  let unsaved = keep_writes st in
  let autosave = autosave_after st ~who in
  Ok (observe st, { ran with unsaved; autosave })
;;

(* The saves over inventory, matched the way DOS matches names. Preparation
   snapshots the lane counter first; commit rejects a concurrent guest run. *)
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

(* ---------- program images ---------- *)

(* The core's loaders raise [Invalid_argument] on an image they cannot place:
   a header shorter than its fixed part, a header or relocation table that
   runs past the file, a payload past the end of memory. An exception out of
   [prepare_load] reaches the caller as a crash, not as the caller's mistake.
   [image_of_bytes] checks those conditions first and returns the image as a
   value only when the loader can take it.

   For an MZ image the check is exactly the loader's: refused if and only if
   [Dos_dos.load_exe] would raise. Two refusals are stricter than the loader
   (ocaml-dos 323609dd, Dos_dos.load_com and load_exe), on purpose:

   - A COM image of more than [max_com_bytes]. [load_com] copies any size up
     to the end of memory, but it then writes the 2-byte return word at
     PSP:FFFE, which lies inside such an image, and points SP there. The
     program is placed with its tail overwritten and its stack on top of it.
     DOS itself refuses a COM that does not fit its segment.
   - The signature "ZM", which DOS also accepts for an EXE. [load_exe] takes
     only "MZ", so a ZM file would be loaded as a COM and run its header as
     code.

   test_dos_lane_image runs the real loader beside the check: it compares
   them on seeded MZ images and at the memory edge, and it shows the two
   stricter facts above with the loader itself, so a pin bump that moves any
   of them turns it red. *)

(* The machine's address space: 20 address lines. *)
let memory_bytes = 0x100000
let last_address = memory_bytes - 1

(* Both loaders put the image no lower than segment 0x1000 plus the 256-byte
   PSP. *)
let image_floor = 0x10100

(* The image starts at PSP:0100 and the return word sits at PSP:FFFE, so the
   largest image that leaves the word outside it ends at offset 0xFEFE: 65,278
   bytes. *)
let max_com_bytes = 0xFFFE - 0x100

(* The fixed MZ header, through the relocation table offset at 0x18. *)
let mz_fixed_header_bytes = 0x1C
let mz_reloc_entry_bytes = 4

let max_exe_payload_bytes = memory_bytes - image_floor

type image =
  | Com of string
  | Exe of string

let is_zm image =
  String.length image >= 2 && Char.equal image.[0] 'Z' && Char.equal image.[1] 'M'
;;

let u16_at image offset = Char.code image.[offset] lor (Char.code image.[offset + 1] lsl 8)

let image_of_bytes ~program_name image =
  let refuse fmt = Printf.ksprintf (fun message -> Error (Invalid_request message)) fmt in
  let size = String.length image in
  if size = 0 then refuse "%s is empty" program_name
  else if is_zm image then
    refuse "%s starts with ZM, a DOS executable signature this machine does not load (it takes MZ)"
      program_name
  else if not (is_mz image) then
    if size > max_com_bytes then
      refuse "%s is %d bytes, more than a COM image holds (%d)" program_name size max_com_bytes
    else Ok (Com image)
  else if size < mz_fixed_header_bytes then
    refuse "%s is an MZ executable cut short: %d bytes, and its fixed header is %d" program_name
      size mz_fixed_header_bytes
  else begin
    let header_bytes = u16_at image 0x08 * 16 in
    let reloc_count = u16_at image 0x06 and reloc_offset = u16_at image 0x18 in
    if header_bytes > size then
      refuse "%s is an MZ executable cut short: its header is %d bytes and the file is %d"
        program_name header_bytes size
    else if reloc_count > 0 && reloc_offset + (reloc_count * mz_reloc_entry_bytes) > size then
      refuse "%s is an MZ executable cut short: its relocation table ends at byte %d and the file is %d"
        program_name (reloc_offset + (reloc_count * mz_reloc_entry_bytes)) size
    else if size - header_bytes > max_exe_payload_bytes then
      refuse "%s holds %d bytes of program, more than fit in memory (%d)" program_name
        (size - header_bytes) max_exe_payload_bytes
    else Ok (Exe image)
  end
;;

let load_image machine = function
  | Com image -> Dos_machine.load_com machine image
  | Exe image -> Dos_machine.load_exe machine image
;;

type prepared_load = {
  load_machine : (Dos_machine.t * (string, string) Hashtbl.t) option ref;
  load_program : string;
  load_ledger_dir : string;
  load_saves_dir : string;
  load_checkpoint_dir : string;
  load_change_count : int;
}

let held_of = function
  | No_autosave -> None
  | Autosave status -> Some (Held status)
  | Autosave_unreadable reason -> Some (Held_unreadable reason)
;;

(* What a machine started now would discard, if anything. Its first autosave
   copies the autosave to [autosave_prev_slot] and replaces that slot, so the
   previous autosave is lost exactly when both files exist; with no autosave
   there is nothing to copy and the previous one stays, and with no previous
   one the autosave moves into the slot and survives. An unreadable file counts
   as there: the campaign it held may be the only copy. The files are read only
   to name them in a refusal, after both are known to exist. *)
let discard_at_stake ~dir =
  let exists slot = Sys.file_exists (Machine_checkpoint.path ~dir slot) in
  if not (exists autosave_slot && exists autosave_prev_slot) then None
  else
    match held_of (lookup_previous_autosave ~dir), held_of (lookup_autosave ~dir) with
    | Some previous, Some current -> Some { previous; current }
    | None, _ | _, None -> None (* a file vanished between the check and the read *)
;;

let check_previous_autosave_consent ~dir = function
  | Discard_previous_autosave -> Ok ()
  | Keep_previous_autosave ->
    (match discard_at_stake ~dir with
     | None -> Ok ()
     | Some discard -> Error (Would_discard_previous_autosave discard))
;;

let prepare_load ~ledger_dir ~saves_dir ~checkpoint_dir ~previous_autosave ~program_name ~program_bytes ~files =
  let* () = require_activity () in
  (* Guest writes raise this counter. A load must not install a save overlay
     read across a concurrent run of the old machine. *)
  let load_change_count = locked (fun () -> !change_count) in
  let* image = image_of_bytes ~program_name program_bytes in
  let* files = with_saves ~saves_dir files in
  match dos_name_collision files with
  | Some (earlier, later) ->
      Error (Invalid_request (Printf.sprintf
        "%s and %s are one name to DOS; the guest can only see one" earlier later))
  | None ->
      let* () = check_previous_autosave_consent ~dir:checkpoint_dir previous_autosave in
      let m = Dos_machine.create () in
      List.iter (fun (name, contents) -> Dos_machine.mount_file m name contents) files;
      load_image m image;
      let kept = Hashtbl.create (List.length files) in
      List.iter (fun (name, contents) -> Hashtbl.replace kept (String.uppercase_ascii name) contents) files;
      Ok {load_machine=ref (Some (m, kept)); load_program=program_name;
          load_ledger_dir=ledger_dir; load_saves_dir=saves_dir;
          load_checkpoint_dir=checkpoint_dir; load_change_count}
;;

let commit_load ~who prepared ~announce =
  locked (fun () ->
    let* () = require_activity () in
    let* () = match !state with None -> Ok () | Some st -> refuse_other st ~who in
    if !change_count <> prepared.load_change_count then
      Error (Invalid_request "DOS machine changed during load preparation; request the load again")
    else match !(prepared.load_machine) with
    | None -> Error (Invalid_request "DOS load preparation was already consumed")
    | Some (m, kept) ->
      match remove_resume_mark_for_install ~dir:prepared.load_checkpoint_dir with
      | Error message -> Error (refused_for_mark ~nothing_was:"loaded" message)
      | Ok () ->
      prepared.load_machine := None;
      let ledger_path = Filename.concat prepared.load_ledger_dir "ledger.jsonl" in
      match
        mkdir_p prepared.load_ledger_dir;
        Out_channel.with_open_bin ledger_path (fun _ -> ())
      with
      | exception Sys_error message -> Error (Unreadable message)
      | () ->
        let st = {m; steps=0; program=prepared.load_program; ledger_path; entries=[];
          saves_dir=prepared.load_saves_dir; checkpoint_dir=prepared.load_checkpoint_dir; kept;
          controller=Some who; incarnation=Random_id.uuid_v7 (); previous_kept=false;
          resume_marked=false} in
        state := Some st;
        mark_change ();
        note_activity ~who (Printf.sprintf "load %s" prepared.load_program);
        (* From here the machine is installed and the loader holds it, so
           whatever the boot does, the answer is [Ok] with how it ended and
           [announce] runs once: a result that said "nothing was loaded"
           would be false, and a skipped announce would hide a machine that
           changed. The core can raise out of a run (a malformed EXEC child);
           that is a boot fault too. Cancellation is not a fault. *)
        let booted =
          match
            running (fun () ->
              let ran = advance st ~budget:boot_steps ~until_ready:true in
              ran_then_kept st ~who ran)
          with
          | Ok settled -> Ok settled
          | Error (Guest_fault message) -> Error (Unimplemented_instruction message)
          | Error
              (( Activity_disabled | Activity_unobserved | No_machine | Invalid_request _
               | Unreadable _ | Held_by _ | Unsaveable _ | Checkpoint_refused _
               | Other_program _ | Would_discard_previous_autosave _ ) as error) ->
            Error (Core_exception (error_to_string error))
          | exception (Eio.Cancel.Cancelled _ as cancelled) -> raise cancelled
          | exception exn -> Error (Core_exception (Printexc.to_string exn))
        in
        announce ();
        (match booted with
         | Ok (observation, ran) -> Ok (observation, Booted ran)
         | Error fault -> Ok (observe st, Boot_faulted fault)))
;;

let load ~who ~ledger_dir ~saves_dir ~checkpoint_dir ~previous_autosave ~program_name ~program_bytes ~files ~announce =
  let* prepared = prepare_load ~ledger_dir ~saves_dir ~checkpoint_dir ~previous_autosave
      ~program_name ~program_bytes ~files in
  commit_load ~who prepared ~announce
;;

let eject ~who ~announce () =
  locked (fun () ->
    match !state with
    | None -> Error No_machine
    | Some st ->
      (match refuse_other st ~who with
       | Error e -> Error e
       | Ok () ->
         (* An ejected machine stays restorable from its autosave, but a
            restart does not bring it back. *)
         (match forget_resume_mark st with
          | Error message -> Error (refused_for_mark ~nothing_was:"ejected" message)
          | Ok () ->
            state := None;
            mark_change ();
            note_activity ~who "eject";
            announce ();
            Ok ())))
;;

let pass ~who ~to_ ~announce =
  let* () = match to_ with None -> Ok () | Some _ -> require_activity () in
  with_machine (fun st ->
    match refuse_other st ~who with
    | Error e -> Error e
    | Ok () ->
      st.controller <- to_;
      note_activity ~who
        (match to_ with Some name -> "pass -> " ^ name | None -> "release control");
      announce ();
      Ok (observe st))
;;

(* A holder that can no longer act cannot pass. The caller, which can read
   Keeper state (this module cannot), names the holder it found gone; the
   controller is freed only if that holder still has it, so a hand-off that
   landed in between is kept. *)
let release_left ~holder ~announce =
  with_machine (fun st ->
    match st.controller with
    | Some current when String.equal current holder ->
      st.controller <- None;
      note_activity ~who:holder "released (idle)";
      announce ();
      Ok true
    | Some _ | None -> Ok false)
;;

let check_key_name name = Result.map (fun (_ : int) -> ()) (Dos_machine.key_of_string name)

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

type live =
  | Nothing_loaded
  | Unchanged of change_mark
  | Changed of change_mark * frame

(* Compare and copy under one lock hold, so the count, the incarnation and the
   pixels always describe the same machine state. An unchanged answer renders
   nothing. *)
let live ~since =
  locked (fun () ->
    match !state with
    | None -> Nothing_loaded
    | Some st ->
      let mark = { count = !change_count; incarnation = st.incarnation } in
      (match since with
       | Some seen when seen.count = mark.count
                        && String.equal seen.incarnation mark.incarnation -> Unchanged mark
       | Some _ | None ->
         let width, height = Dos_machine.frame_dims st.m in
         Changed (mark, { width; height; rgb = Dos_machine.frame_rgb st.m })))
;;

let step ~who ~steps ~until_ready =
  with_control ~who (fun st ->
    match clamp_steps steps with
    | Error e -> Error e
    | Ok budget ->
      let ran = advance st ~budget ~until_ready in
      note_activity ~who (Printf.sprintf "step %d" ran.steps_run);
      ran_then_kept st ~who ran)
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
   is a quarter of a billion machine steps held under the machine's mutex,
   with every other keeper queued behind it. A sequence that runs out comes
   back with [keys_pressed] below what was asked, and the caller sends the
   rest; the keys not pressed are not in the ledger and never reached the
   ring. *)
let press_resolved st ~who ~keys ~budget ~until_ready =
  let total = ref 0 and requests = ref 0 and pressed = ref 0 in
  let instructions = ref 0 and cycles = ref 0 in
  let last_settled = ref false in
  List.iter
    (fun (name, word) ->
      let left = max_steps_per_call - !total in
      (* The default mode continues only after its settling observation.
         Full-allowance mode deliberately sends one key: it does not infer
         permission to inject the remaining suffix from keyboard polling. *)
      let ready = !pressed = 0 || (until_ready && !last_settled) in
      if left > 0 && ready then begin
        append_entry st { at_step = st.steps; who; key_name = name };
        Dos_machine.push_key st.m word;
        let ran = advance st ~budget:(min budget left) ~until_ready in
        total := !total + ran.steps_run;
        instructions := !instructions + ran.instructions_run;
        cycles := !cycles + ran.elapsed_cycles;
        requests := !requests + ran.input_requests;
        last_settled := ran.settled;
        incr pressed
      end)
    keys;
  { steps_run = !total
  ; instructions_run = !instructions
  ; elapsed_cycles = !cycles
  ; settled = !last_settled
  ; input_requests = !requests
  ; keys_pressed = !pressed
  ; unsaved = []
  ; autosave = Not_attempted
  }
;;

let press_on st ~who ~keys ~steps ~until_ready =
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
         let ran = press_resolved st ~who ~keys:resolved ~budget ~until_ready in
         note_activity ~who ("press " ^ String.concat ","
           (List.map fst (List.take ran.keys_pressed resolved)));
         ran_then_kept st ~who ran)
;;

let press ~who ~keys ~steps ~until_ready =
  with_control ~who (fun st -> press_on st ~who ~keys ~steps ~until_ready)

let press_into ~saves_name ~who ~keys ~steps ~until_ready =
  with_control ~who (fun st ->
    let loaded = saves_name_of st in
    if String.equal loaded saves_name then press_on st ~who ~keys ~steps ~until_ready
    else Error (Other_program { expected = saves_name; loaded }))
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
(* The core's own mask for the mouse: bit 0 left, bit 1 right, bit 2 middle
   (Dos_machine.set_mouse). *)
let mouse_button_mask = 0b111

let click ~who ~x ~y ~buttons ~steps =
  with_control ~who (fun st ->
    let width, height = Dos_machine.frame_dims st.m in
    if x < 0 || y < 0 || x >= width || y >= height then
      Error
        (Invalid_request
           (Printf.sprintf "click must land inside the %dx%d frame, got (%d,%d)"
              width height x y))
    else if buttons land lnot mouse_button_mask <> 0 then
      Error
        (Invalid_request
           (Printf.sprintf
              "buttons is a bitmask of 1 left, 2 right and 4 middle (0 only moves), got %d"
              buttons))
    else
      match clamp_steps steps with
      | Error e -> Error e
      | Ok budget ->
        append_entry st
          { at_step = st.steps; who; key_name = Printf.sprintf "mouse(%d,%d,%d)" x y buttons };
        note_activity ~who (Printf.sprintf "click (%d,%d)" x y);
        Dos_machine.set_mouse st.m ~x ~y ~buttons;
        if buttons = 0 then begin
          let ran = advance st ~budget ~until_ready:true in
          ran_then_kept st ~who ran
        end
        else begin
          let half = max 1 (budget / 2) in
          let down = advance st ~budget:half ~until_ready:true in
          Dos_machine.set_mouse st.m ~x ~y ~buttons:0;
          let up = advance st ~budget:(budget - down.steps_run) ~until_ready:true in
          ran_then_kept st ~who
            { steps_run = down.steps_run + up.steps_run
              ; instructions_run = down.instructions_run + up.instructions_run
              ; elapsed_cycles = down.elapsed_cycles + up.elapsed_cycles
              ; settled = down.settled && up.settled
              ; input_requests = down.input_requests + up.input_requests
              ; keys_pressed = 0
              ; unsaved = []
              ; autosave = Not_attempted
              }
        end)
;;

let type_text ~who ~text ~steps ~until_ready =
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
           let ran = press_resolved st ~who ~keys:resolved ~budget ~until_ready in
           note_activity ~who (Printf.sprintf "type %d chars" ran.keys_pressed);
           ran_then_kept st ~who ran))
;;

(* ---------- checkpoints ---------- *)

let save ~who ~dir ~slot =
  with_machine (fun st ->
    (* Read under the lock, so what is reported replaced is what the write
       replaces and not what was there a moment before. *)
    let replaced =
      match lookup_slot ~dir slot with
      | No_autosave -> Fresh_slot
      | Autosave status -> Replaced status
      | Autosave_unreadable reason -> Replaced_unreadable reason
    in
    match write_checkpoint st ~who ~dir ~slot with
    | Ok () ->
      note_activity ~who ("save " ^ Machine_checkpoint.slot_to_string slot);
      Ok (observe st, replaced)
    | Error e -> Error e)
;;

type restore_payload = {
  restore_machine : Dos_machine.t;
  restore_kept : (string, string) Hashtbl.t;
  restore_meta : restored_meta;
  restore_entries : entry list;
  restore_staged_ledger : string;
  restore_ledger_path : string;
  restore_saves_dir : string;
  restore_checkpoint_dir : string;
  restore_slot : slot;
      (* Classified once by [prepare_restore]; its file is [checkpoint_slot]. *)
  restore_slot_writes : int;
  restore_previous_writes : int;
      (* How many times this lane replaced the previous autosave when the
         consent was checked. A load that lands between preparation and commit
         copies the autosave into that slot, and the restore's own first
         autosave would then discard what it just kept. *)
}

type prepared_restore = restore_payload option Atomic.t

let remove_restore_stage path =
  try Unix.unlink path with Unix.Unix_error (Unix.ENOENT,_,_) -> ()

let discard_prepared_restore prepared =
  match Atomic.exchange prepared None with
  | None -> ()
  | Some owned -> remove_restore_stage owned.restore_staged_ledger
;;

(* A restore of a named slot starts a new incarnation, as a load does: its
   first autosave copies the autosave to [autosave_prev_slot], so it discards
   the previous autosave and the same consent is asked. A restore of either
   lane-owned slot continues the history whose last save is that file, and
   loses nothing. The autosave's machine replaces only the autosave, which it
   holds, and leaves the previous autosave as it is
   ([previous_kept_on_restore]). The previous autosave's machine replaces only
   the previous autosave, which it holds, after keeping the autosave there. A
   slot that is not there is not asked about: the read reports it. *)
let check_restore_consent ~dir slot consent =
  match slot with
  | Current_autosave | Previous_autosave -> Ok ()
  | Named named ->
    if Sys.file_exists (Machine_checkpoint.path ~dir named) then
      check_previous_autosave_consent ~dir consent
    else Ok ()
;;

(* Whether a restored machine starts with the autosave it finds already kept.
   The autosave's own machine does: it carries on the history whose last save
   is that file, so its autosaves replace the autosave and the previous
   autosave stays as uninterrupted play leaves it. Every other restored
   machine keeps the autosave in [autosave_prev_slot] with its first save, as
   a loaded one does. *)
let previous_kept_on_restore = function
  | Current_autosave -> true
  | Previous_autosave | Named _ -> false
;;

(* What a restore does to the resume mark before it installs the machine. The
   autosave's own machine continues the history the mark records, so the mark
   stays as it is. Any other restored machine is not what the autosave holds,
   so the mark goes, and comes back with that machine's first autosave. *)
let clear_mark_on_restore ~dir = function
  | Current_autosave -> Ok ()
  | Previous_autosave | Named _ -> remove_resume_mark_for_install ~dir
;;

let prepare_restore ~dir ~slot ~previous_autosave ~ledger_dir ~saves_dir_of =
  let classified = classify_slot slot in
  let slot = checkpoint_slot classified in
  let* () = require_activity () in
  let restore_slot_writes, restore_previous_writes =
    locked (fun () ->
      ( checkpoint_write_count (Machine_checkpoint.path ~dir slot)
      , checkpoint_write_count (Machine_checkpoint.path ~dir autosave_prev_slot) )) in
  let* () = check_restore_consent ~dir classified previous_autosave in
  let* checkpoint = match Machine_checkpoint.read ~dir slot ~machine:Machine_checkpoint.Dos
      ~format:checkpoint_format with
    | Ok checkpoint -> Ok checkpoint
    | Error (Machine_checkpoint.Unreadable message) -> Error (Unreadable message)
    | Error
        ((Machine_checkpoint.No_slot _
         | Machine_checkpoint.Other_machine _
         | Machine_checkpoint.Other_format _
         | Machine_checkpoint.Corrupt _) as e) -> Error (Checkpoint_refused e) in
  let* meta = meta_of_json checkpoint.Machine_checkpoint.meta in
  let* m = match Dos_snapshot.restore checkpoint.machine_bytes with
    | Ok m -> Ok m
    | Error e -> Error (Checkpoint_refused (snapshot_error_to_checkpoint_error e)) in
  let kept = Hashtbl.create 16 in
  List.iter (fun name ->
    Option.iter (Hashtbl.replace kept name) (Dos_machine.read_mounted m name))
    (Dos_machine.mounted_names m);
  let lines = String.concat ""
      (List.map (fun e -> Yojson.Safe.to_string (entry_json e) ^ "\n") meta.saved_ledger) in
  let entries = List.rev meta.saved_ledger in
  let saves_dir = saves_dir_of meta.saved_saves in
  try
    mkdir_p ledger_dir;
    let temporary,channel = Filename.open_temp_file ~temp_dir:ledger_dir ".restore-ledger-" ".tmp" in
    let transferred = ref false in
    Fun.protect ~finally:(fun () ->
      close_out_noerr channel;
      if not !transferred then remove_restore_stage temporary)
      (fun () ->
        output_string channel lines;
        close_out channel;
        let prepared = Atomic.make (Some {
          restore_machine=m;restore_kept=kept;restore_meta=meta;restore_entries=entries;
          restore_staged_ledger=temporary;restore_ledger_path=Filename.concat ledger_dir "ledger.jsonl";
          restore_saves_dir=saves_dir;restore_checkpoint_dir=dir;restore_slot=classified;
          restore_slot_writes;restore_previous_writes}) in
        transferred := true;
        Ok prepared)
  with
  | Sys_error message -> Error (Unreadable message)
  | Unix.Unix_error (error,operation,path) ->
      Error (Unreadable (operation ^ " " ^ path ^ ": " ^ Unix.error_message error))
;;

(* The commit itself, under the lock, once the caller's activity and admission
   checks passed. [controller] holds the restored machine: the caller who asked
   for it, or nobody for a worker's start. [by] names who did it on the
   activity feed. The caller's cleanup and this commit atomically compete for
   the one payload; cleanup can never unlink a staged file already owned here. *)
let commit_admitted ~controller ~by prepared ~announce =
  match Atomic.exchange prepared None with
  | None -> Error (Invalid_request "DOS restore preparation was already consumed or discarded")
  | Some owned ->
    Fun.protect ~finally:(fun () -> remove_restore_stage owned.restore_staged_ledger)
      (fun () ->
        let slot = checkpoint_slot owned.restore_slot in
        if checkpoint_write_count (Machine_checkpoint.path ~dir:owned.restore_checkpoint_dir slot)
           <> owned.restore_slot_writes
        then
          Error (Invalid_request (Printf.sprintf
            "DOS checkpoint %s was saved again during restore preparation; request the restore again"
            (Machine_checkpoint.slot_to_string slot)))
        else if checkpoint_write_count
                  (Machine_checkpoint.path ~dir:owned.restore_checkpoint_dir autosave_prev_slot)
                <> owned.restore_previous_writes
        then
          Error (Invalid_request
            "the previous autosave changed during restore preparation; request the restore again")
        else
        let meta = owned.restore_meta in
        let st = {m=owned.restore_machine; steps=meta.saved_steps; program=meta.saved_program;
          ledger_path=owned.restore_ledger_path; entries=owned.restore_entries;
          saves_dir=owned.restore_saves_dir;checkpoint_dir=owned.restore_checkpoint_dir;
          kept=owned.restore_kept;controller;
          incarnation=Random_id.uuid_v7 ();
          previous_kept=previous_kept_on_restore owned.restore_slot;
          resume_marked=false} in
        (* Read before anything changes: the core's readers can raise, and a
           machine must not be published, nor the mark removed, for a commit
           that then fails. *)
        let observation = observe st in
        match clear_mark_on_restore ~dir:owned.restore_checkpoint_dir owned.restore_slot with
        | Error message -> Error (refused_for_mark ~nothing_was:"restored" message)
        | Ok () ->
        (* The checkpoint's ledger replaces the file. At a worker's start this
           drops any keys a killed process appended after its last autosave;
           what those keys did to the guest died with that process too, so the
           ledger and the machine still agree. *)
        match Sys.rename owned.restore_staged_ledger owned.restore_ledger_path with
        | exception Sys_error message -> Error (Unreadable message)
        | () ->
          state := Some st;
          mark_change ();
          note_activity ~who:by ("restore " ^ Machine_checkpoint.slot_to_string slot);
          announce ();
          Ok observation)
;;

let commit_restore ~who prepared ~announce =
  (* After admission the lock covers revalidation and publication only. *)
  locked (fun () ->
    let* () = require_activity () in
    let* () = match !state with None -> Ok () | Some st -> refuse_other st ~who in
    commit_admitted ~controller:(Some who) ~by:who prepared ~announce)
;;

let restore ~who ~dir ~slot ~previous_autosave ~ledger_dir ~saves_dir_of ~announce =
  let* prepared = prepare_restore ~dir ~slot ~previous_autosave ~ledger_dir ~saves_dir_of in
  Fun.protect ~finally:(fun () -> discard_prepared_restore prepared)
    (fun () -> commit_restore ~who prepared ~announce)
;;

type resume =
  | Nothing_to_resume
  | Machine_loaded
  | Resumed of observation
  | Not_resumed of error
  | Resume_raised of string

(* Who did it, on the activity feed: nobody asked for this machine, and no
   Keeper's name is put on what a worker does as it starts. *)
let worker_start = "worker start"

(* The restore of the autosave a caller would make, admitted only with no
   machine loaded: nobody asked, so nobody's machine is replaced. The checks
   run in this order: a loaded machine, then the resume mark, then the file,
   and only then activity and the file's contents, so a loaded machine wins
   over everything and a missing mark or file is always a quiet
   [Nothing_to_resume]. The consent argument is never consulted for this slot
   ([check_restore_consent]). The restore runs inside the worker before it
   serves, so an exception from it is reported as [Resume_raised] and never
   ends the worker; cancellation goes on unwinding. *)
let resume_autosave ~dir ~ledger_dir ~saves_dir_of =
  let attempt () =
    if locked (fun () -> Option.is_some !state) then Machine_loaded
    else if not (Sys.file_exists (resume_mark_path ~dir)) then Nothing_to_resume
    else if not (Sys.file_exists (Machine_checkpoint.path ~dir autosave_slot)) then
      Nothing_to_resume
    else
      match
        prepare_restore ~dir ~slot:autosave_slot ~previous_autosave:Keep_previous_autosave
          ~ledger_dir ~saves_dir_of
      with
      | Error (Checkpoint_refused (Machine_checkpoint.No_slot _)) -> Nothing_to_resume
      | Error
          (( Activity_disabled | Activity_unobserved | No_machine | Invalid_request _
           | Unreadable _ | Held_by _ | Guest_fault _ | Unsaveable _
           | Checkpoint_refused
               ( Machine_checkpoint.Unreadable _ | Machine_checkpoint.Other_machine _
               | Machine_checkpoint.Other_format _ | Machine_checkpoint.Corrupt _ )
           | Other_program _ | Would_discard_previous_autosave _ ) as error) ->
        Not_resumed error
      | Ok prepared ->
        Fun.protect ~finally:(fun () -> discard_prepared_restore prepared) (fun () ->
          locked (fun () ->
            match require_activity () with
            | Error error -> Not_resumed error
            | Ok () ->
              (match !state with
               | Some _ -> Machine_loaded
               | None ->
                 (match
                    commit_admitted ~controller:None ~by:worker_start prepared ~announce:ignore
                  with
                  | Ok observation -> Resumed observation
                  | Error error -> Not_resumed error))))
  in
  let resumed =
    match attempt () with
    | resumed -> resumed
    | exception (Eio.Cancel.Cancelled _ as cancelled) -> raise cancelled
    | exception exn -> Resume_raised (Printexc.to_string exn)
  in
  let failed reason =
    locked (fun () ->
      note_activity ~who:worker_start
        ("restore " ^ Machine_checkpoint.slot_to_string autosave_slot ^ " failed: " ^ reason))
  in
  (match resumed with
   | Not_resumed error -> failed (error_to_string error)
   | Resume_raised exn -> failed ("the restore raised " ^ exn)
   | Nothing_to_resume | Machine_loaded | Resumed _ -> ());
  resumed
;;

let checkpoints ~dir =
  match Machine_checkpoint.list ~dir with
  | Ok listed -> Ok listed
  | Error message -> Error (Unreadable message)
;;

(* ---------- introspection ---------- *)

(* An address the machine has: 0 to [last_address]. The only way to make one
   is [address_of_int], so [peek] cannot be handed a sentinel. *)
type address = int

let address_of_int n =
  if n < 0 || n > last_address then
    Error (Invalid_request (Printf.sprintf "address must be 0..0x%X, got %d" last_address n))
  else Ok n
;;

let address_to_int address = address

let peek ~address ~length =
  with_machine (fun st ->
    if length < 1 || length > peek_max_bytes then
      Error
        (Invalid_request
           (Printf.sprintf "length must be 1..%d, got %d" peek_max_bytes length))
    else begin
      let b = Buffer.create (length * 2) in
      for i = 0 to length - 1 do
        Buffer.add_string b
          (Printf.sprintf "%02x" (Dos_machine.mem_read st.m ((address + i) land last_address)))
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
