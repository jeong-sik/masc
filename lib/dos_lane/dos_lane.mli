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
  psp : int;
      (** the program's PSP segment. Only a COM image starts with [cs] equal
          to it; an EXE begins in its own code segment, so a caller reading
          the PSP through {!peek} has to be told where it is. *)
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
  frame_nonblack : int;
      (** graphics-mode reading of the same frame: the number of 8x16 cells
          holding any pixel brighter than near-black. A text mode has a value
          here too — its frame is the text page rendered — so a caller can
          fingerprint either kind of screen with one field. Two different
          screens can share a count; use it to notice change, not to read. *)
  frame_ascii : string;
      (** the whole frame as a coarse luminance map: 8x16 pixel cells, each
          one character of " .:-=+*#%@", rows newline-separated. This is the
          only field that shows what a graphics mode drew. A VGA game's
          title screen, map and menus read here the way text programs read
          in [screen_text]. *)
  program : string option;  (** the loaded program's name *)
  controller : string option;
      (** who may move this machine's time now; [None] until someone does.
          See {!pass}. *)
  files : string list;  (** file names the guest can open, sorted *)
}

type entry = { at_step : int; who : string; key_name : string }

type error =
  | No_machine  (** nothing loaded — [masc_dos_load] first *)
  | Invalid_request of string  (** the caller's arguments *)
  | Unreadable of string
      (** a file that is there and will not read. A path that does not exist
          is [Invalid_request] — the caller named it. *)
  | Held_by of string
      (** another caller holds the controller; nothing was done. *)

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
  keys_pressed : int;
      (** keys this call delivered. {!step} and {!load} press nothing, so it
          is zero there. Below the number {!press} or {!type_text} was given,
          it means the call reached its step ceiling: the rest were not
          recorded and never reached the ring, so the caller sends them
          again. *)
  unsaved : string list;
      (** files the program wrote during this call that did not reach the
          saves directory, one line each with the reason. Empty when every
          save is on disk. The call itself happened: the guest moved either
          way, so this is not a reason to send the same keys again. *)
}

val settle_chunk : int
(** Instructions between two screen readings while waiting for {!ran.settled}. *)

val escapes : string -> bool
(** A name that is a path or a drive rather than one plain file name: a
    separator, a colon, [..] or a leading dot. The program inventory refuses
    such names, and a file the guest creates under one is never written to
    the saves directory. *)

val load :
  who:string ->
  ledger_dir:string ->
  saves_dir:string ->
  program_name:string ->
  program_bytes:string ->
  files:(string * string) list ->
  announce:(unit -> unit) ->
  (observation * ran, error) result
(** Creates the workspace machine, replacing any previous one. The loader is
    chosen by the image's own bytes — an MZ signature is an EXE, anything
    else is a COM — not by the file name, so a misnamed image still boots the
    way DOS would boot it.

    [files] are (name, contents) the guest can open by name, case-insensitively.
    The ledger is [ledger_dir/ledger.jsonl], truncated: a new machine starts a
    new ledger. Loading is not evidence that the program reaches a screen —
    read the observation.

    Two names that differ only in case are refused: DOS folds filenames, so
    the guest would see one of them and the observation would list both.

    [saves_dir] holds what this program wrote on earlier machines. Its files
    are mounted over [files] of the same DOS name, and every call that runs
    the guest writes a file whose contents changed back to it, so a game's
    own save survives an eject and a server restart. A save that cannot be
    written is listed in {!ran.unsaved}. A file the program deletes is not
    carried: the next load mounts the inventory copy again. A save directory
    that will not read is [Unreadable].

    [announce] runs while the machine's lock is still held, right after this
    machine becomes the workspace's. Announcements therefore reach whoever
    reads them in the order the machines actually changed. It must not call
    back into this module — the lock is not reentrant. *)

val eject : who:string -> announce:(unit -> unit) -> unit -> (unit, error) result
(** Drops the workspace machine. [announce] runs under the same lock as
    {!load}'s, with the same restriction. *)
val screen : unit -> (observation, error) result

type frame = { width : int; height : int; rgb : string }
(** The frame as the display would show it: [width * height] pixels, three
    bytes each, rows top to bottom. *)

val capture : unit -> (observation * frame, error) result
(** {!screen} and the frame it describes, read under one lock, so the two
    cannot come from different moments. The frame is what a Keeper with
    vision reads: a VGA game's Korean menus are glyphs in pixels, which
    [frame_ascii]'s luminance cells cannot spell. *)

type identified_capture = {
  incarnation : string;
      (** Fresh on every load. Reads and time leave it alone. *)
  observation : observation;
  frame : frame;
  input_count : int;
  input_ledger : entry list;
      (** Newest first, every input through [input_count], read with the
          frame under the same lock. *)
}

val capture_with_identity : unit -> (identified_capture, error) result
(** {!capture} with the machine's identity and input history, for a Lane
    Add-on source ([dos_capture]). Never advances the machine. *)

val entry_json : entry -> Yojson.Safe.t
(** One ledger line: [{"step", "who", "key"}], the shape written to
    [ledger.jsonl]. *)

(** {1 The controller}

    One machine, several players: a hotseat game such as 삼국지3 asks each
    human ruler in turn at the same keyboard. The controller says whose hands
    are on it. {!load}, {!eject}, {!step}, {!press}, {!click} and
    {!type_text} from anyone but the holder are refused with [Held_by] before
    anything happens; reading ({!screen}, {!capture}, {!peek}) needs no
    controller. A free controller goes to whoever next moves the machine
    successfully, and {!load} gives the new machine's to its loader. *)

val pass :
  who:string -> to_:string option -> announce:(unit -> unit) ->
  (observation, error) result
(** The holder (or anyone, while it is free) hands the controller to [to_],
    or frees it with [None]. [announce] runs under the machine's lock, as
    {!load}'s does. *)

val step :
  who:string -> steps:int -> until_ready:bool -> (observation * ran, error) result
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

val click :
  who:string -> x:int -> y:int -> buttons:int -> steps:int ->
  (observation * ran, error) result
(** Sets the mouse and runs. The mouse is state, not a queue: the cursor and
    buttons stay where they are put until the next call moves them. A click
    ([buttons] 1 left or 2 right) is button down, run, button up, run, in one
    call — the up half always runs so the button is never left held. A move
    ([buttons = 0]) sets the position and runs once. Coordinates are frame
    pixels and must land inside the frame; [steps] is the shared ceiling of
    the whole call, as in {!press}. A program that polls the mouse rather
    than asking the BIOS for keys never reaches {!settled}; its clicks read
    as [settled = false] with the budget spent, which is the expected shape
    for a game driven this way. The action is appended to the ledger like a
    key, so a replay reproduces it. *)

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
