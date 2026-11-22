type reclaimed_key =
  | Literal_next
  | Discard_output
  | Delayed_suspend
  | Quit

external literal_next_slot : unit -> int = "masc_tui_v2_termios_literal_next_slot"
external discard_output_slot : unit -> int = "masc_tui_v2_termios_discard_output_slot"
external delayed_suspend_slot : unit -> int = "masc_tui_v2_termios_delayed_suspend_slot"
external quit_slot : unit -> int = "masc_tui_v2_termios_quit_slot"

let slot = function
  | Literal_next -> literal_next_slot ()
  | Discard_output -> discard_output_slot ()
  | Delayed_suspend -> delayed_suspend_slot ()
  | Quit -> quit_slot ()

external slot_char : Unix.file_descr -> int -> int = "masc_tui_v2_termios_slot_char"
external set_slot_char : Unix.file_descr -> int -> int -> bool = "masc_tui_v2_termios_set_slot_char"
external disable_slot : Unix.file_descr -> int -> bool = "masc_tui_v2_termios_disable_slot"

let key_char fd key = slot_char fd (slot key)
let set_key_char fd key ch = set_slot_char fd (slot key) ch
let disable_key fd key = disable_slot fd (slot key)

type 'a per_key = {
  literal_next : 'a;
  discard_output : 'a;
  delayed_suspend : 'a;
  quit : 'a;
}

let per_key f =
  {
    literal_next = f Literal_next;
    discard_output = f Discard_output;
    delayed_suspend = f Delayed_suspend;
    quit = f Quit;
  }

type snapshot = int per_key

let snapshot fd = per_key (key_char fd)
let reclaim fd = ignore (per_key (fun k -> disable_key fd k) : bool per_key)

let restore_one fd key ch =
  if ch >= 0 then ignore (set_key_char fd key ch : bool)

let restore fd (snap : snapshot) =
  let { literal_next; discard_output; delayed_suspend; quit } = snap in
  restore_one fd Literal_next literal_next;
  restore_one fd Discard_output discard_output;
  restore_one fd Delayed_suspend delayed_suspend;
  restore_one fd Quit quit

type restore_outcome =
  | Restored
  | Already_restored
  | Terminal_gone of Unix.error

type raw_session = {
  fd : Unix.file_descr;
  saved_io : Unix.terminal_io;
  saved_keys : snapshot;
  restored : bool Atomic.t;
}

let enter_raw_mode fd =
  match Unix.tcgetattr fd with
  | exception Unix.Unix_error (err, _, _) -> Error err
  | saved_io -> (
      let saved_keys = snapshot fd in
      let raw =
        {
          saved_io with
          Unix.c_icanon = false;
          c_echo = false;
          c_icrnl = false;
          c_ixon = false;
          c_ixoff = false;
          c_vmin = 1;
          c_vtime = 0;
        }
      in
      match Unix.tcsetattr fd Unix.TCSANOW raw with
      | () ->
          reclaim fd;
          Ok { fd; saved_io; saved_keys; restored = Atomic.make false }
      | exception Unix.Unix_error (err, _, _) -> Error err)

let restore_raw_mode session =
  if not (Atomic.compare_and_set session.restored false true) then
    Already_restored
  else
    match Unix.tcsetattr session.fd Unix.TCSANOW session.saved_io with
    | () ->
        restore session.fd session.saved_keys;
        Restored
    | exception Unix.Unix_error (((Unix.ENOTTY | Unix.EIO) as err), _, _) ->
        Terminal_gone err
    | exception Unix.Unix_error (err, _, _) -> Terminal_gone err

let with_raw_mode_switch ~sw fd =
  Eio.Switch.check sw;
  match enter_raw_mode fd with
  | Error _ as err -> err
  | Ok session ->
      Eio.Switch.on_release sw (fun () ->
          ignore (restore_raw_mode session : restore_outcome));
      Ok session
