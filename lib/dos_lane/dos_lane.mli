(** Dos_lane — the one DOS machine the workspace plays on.

    Follows RFC-0439 (the MSX machine lives in the server) for a second
    machine: the DOS core lives here, in the server process, so every keeper
    tool puts keys into the same {!Dos_machine.t}. The core is turn-based —
    only {!step}, {!press} and {!type_text} move time — and each call is
    capped at {!max_steps_per_call}.

    {b Time is instructions, not frames.} A DOS program has no frame clock;
    it runs until it asks for something. The unit here is one 8086
    instruction, and the useful stopping point is {e ready}: the guest asked
    the BIOS for a key and found none, {e and} the screen memory stopped
    changing.

    Both halves are needed. Asking alone is not reacting: a program in its
    own loop takes a key and asks for the next one 631 instructions later
    (measured on ZZT) while the repaint it started is still half-written.
    Stopping there hands back the picture from before the key, and the press
    looks like it did nothing. A menu that is genuinely blocked matches on
    the first chunk, so the screen half costs it nothing.

    {b Keys are a queue, not a matrix.} DOS reads the keyboard through a
    BIOS ring buffer, so there is no hold or release — a key is put in the
    ring and the guest takes it out. {!press} therefore names no hold time.

    Every key is appended to a ledger as (step, who, key). The same program
    and the same ledger reproduce the same run: the core reads no clock and
    no randomness — its date, timer ticks and video retrace all come from
    the instruction counter. *)

type observation = {
  steps : int;  (** instructions executed since load *)
  video_mode : int;  (** BIOS mode number: 3 is 80x25 text, 0x13 is VGA *)
  width : int;
  height : int;  (** the frame this mode would draw *)
  cs : int;
  ip : int;
  exited : bool;  (** the program called INT 21h AH=4Ch or fell into INT 20h *)
  exit_code : int;
  halted : bool;  (** HLT — waiting for an interrupt, not finished *)
  waiting_for_key : bool;
      (** the guest asked for a key and the ring was empty. On real hardware
          it would be blocked here. This is the signal to press something. *)
  ticks : int;  (** BIOS timer ticks, 18.2/s by default *)
  screen_text : string;
      (** the 80x25 (or 40x25) text page as UTF-8, code page 437 kept — box
          drawing and game glyphs survive. Rows are newline-separated. Text
          modes only; a graphics mode leaves whatever the text page held. *)
  program : string option;  (** the loaded program's name *)
  files : string list;  (** file names the guest can open, sorted *)
}

type entry = { at_step : int; who : string; key_name : string }

type error =
  | No_machine  (** nothing loaded — [masc_dos_load] first *)
  | Invalid_request of string  (** the caller's arguments *)
  | Unreadable of string
      (** a file that is there and will not read. A path that does not exist
          is [Invalid_request] — the caller named it. *)

val error_to_string : error -> string

val max_steps_per_call : int
(** 4,000,000 instructions. The core runs about 24 million a second on this
    hardware (measured booting ZZT), so a call is roughly 170 ms — the same
    order as the MSX lane's 300-frame cap. *)

val boot_steps : int
(** Instructions run at {!load} before the first observation, stopping early
    if the program asks for a key. A DOS program reaches its title screen in
    its own time; this is the budget for getting there. *)

type ran = {
  steps_run : int;  (** instructions actually advanced *)
  settled : bool;
      (** stopped because the machine is ready: it asked for a key and the
          screen stopped moving. False means the budget ran out or the
          program exited — the observation is then mid-repaint. *)
  input_requests : int;
      (** empty-ring reads during this call. Zero with [settled] false is a
          program busy with something that is not input. *)
}

val settle_chunk : int
(** Instructions between two screen readings while waiting for {!ran.settled}. *)

val load :
  ledger_dir:string ->
  program_name:string ->
  program_bytes:string ->
  files:(string * string) list ->
  (observation * ran, error) result
(** Creates the workspace machine, replacing any previous one. The loader is
    chosen by the image's own bytes — an MZ signature is an EXE, anything
    else is a COM — not by the file name, so a misnamed image still boots the
    way DOS would boot it.

    [files] are (name, contents) the guest can open by name, case-insensitively.
    The ledger is [ledger_dir/ledger.jsonl], truncated: a new machine starts a
    new ledger. Loading is not evidence that the program reaches a screen —
    read the observation. *)

val eject : unit -> (unit, error) result
val screen : unit -> (observation, error) result

val step : steps:int -> until_ready:bool -> (observation * ran, error) result
(** Advances up to [steps] (1..{!max_steps_per_call}) with no key pressed.
    With [until_ready], stops as soon as the machine is ready for input —
    the normal way to hand a turn back. Without it, runs the whole budget,
    which is what a program that is computing rather than asking needs. *)

val press :
  who:string -> keys:string list -> steps:int -> (observation * ran, error) result
(** Puts each key in the BIOS ring in turn and runs until the machine is
    ready again, or [steps] runs out for that key. Key names
    are {!Dos_machine.key_of_string}'s: the arrows, home and page keys,
    insert, delete, enter, esc, space, tab, backspace, F1-F10, or one
    character. A name the machine has no key for is refused before anything
    is pressed. *)

val type_text :
  who:string -> text:string -> steps:int -> (observation * ran, error) result
(** Types the characters of [text] in turn, as {!press} does with one-character
    keys. For a name a program is asking for, not for menu navigation. *)

val peek : address:int -> length:int -> (string, error) result
(** Reads [length] (1..{!peek_max_bytes}) bytes at a physical address
    (0x00000-0xFFFFF) as hex pairs. Read-only: writing is the cheat the lane
    refuses. *)

val peek_max_bytes : int

val ledger : unit -> entry list
(** Oldest first. Empty when no machine is loaded. *)
