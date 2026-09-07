(** Msx_lane — the one MSX machine the workspace plays on (RFC-0439 §3.1).

    The machine lives here, in the server process, so the TUI and every
    keeper tool put keys into the same [Msx.t]. The core is turn-based: only
    {!step} and {!press} move time, and each call is capped at
    {!max_frames_per_call} so a tool call stays inside the domain-0 budget
    (the real-time ticker is RFC-0439 §6.2, not this module).

    Every key edge is appended to a ledger as (frame, who, key, edge). The
    same cartridge and the same ledger reproduce the same frames — the core
    reads no clock and no randomness — so a keeper session replays in the
    core's boot harness. *)

type key = Msx.key

val key_of_string : string -> (key, string) result
(** Names a caller may send: [up down left right space esc return
    trigger_a trigger_b f1 f2 f3 f4 f5], or one printable character. The
    character's place in the matrix is checked when it is pressed. *)

val key_to_string : key -> string
(** Canonical ledger spelling; inverse of {!key_of_string} for named keys. *)

type sprite = {
  index : int;  (** SAT slot 0-31 *)
  x : int;
  y : int;  (** raw SAT value: one more than the screen row *)
  pattern : int;
  color : int;  (** raw color byte: low nibble color, bit 7 = EC (x-32) *)
}

type observation = {
  frame : int;  (** frames stepped since power-on *)
  mode : string;  (** {!Msx.display_mode_to_string} *)
  pc : int;
  halted : bool;
  screen_text : string;
      (** name table as characters — meaningful when the pattern set is a font *)
  tiles : string list;
      (** GRAPHIC1/2/3 and MULTICOLOR: 24 rows of 32 name bytes as hex pairs,
          [..] for name 0. Other modes: empty. *)
  sprites : sprite list;  (** SAT entries before the 0xD0 terminator *)
  cartridge : string option;  (** cartridge file name, if one is plugged in *)
}

type entry = { at_frame : int; who : string; key_name : string; down : bool }

type error =
  | No_machine  (** nothing loaded — [masc_msx_load] first *)
  | Invalid_request of string  (** the caller's arguments *)
  | Unreadable of string  (** a ROM or cartridge path that cannot be read *)

val error_to_string : error -> string

val max_frames_per_call : int
(** 300 frames = 5 seconds at 60 Hz; about 90 ms of emulation. *)

val boot_frames : int
(** Frames run at {!load} before the first observation, so the first picture
    is the C-BIOS logo rather than a blank screen — the TUI's convention. *)

val load :
  ledger_dir:string ->
  roms_dir:string ->
  cart_path:string option ->
  (observation, error) result
(** Creates the workspace machine, replacing any previous one. [roms_dir]
    holds the C-BIOS triple (cbios_main_msx2 / cbios_logo_msx2 / cbios_sub);
    the empty string means no BIOS and the bus reads 0xFF. The ledger is
    [ledger_dir/ledger.jsonl], truncated: a new machine starts a new ledger. *)

val eject : unit -> (unit, error) result
val screen : unit -> (observation, error) result

val step : frames:int -> (observation, error) result
(** Advances [frames] (1..{!max_frames_per_call}) with no key held. *)

val press :
  who:string ->
  keys:key list ->
  hold_frames:int ->
  step_frames:int ->
  (observation, error) result
(** Holds [keys] for [hold_frames], then runs the rest of [step_frames]
    released. [1 <= hold_frames <= step_frames <= max_frames_per_call]. A key
    the matrix has no place for is refused before anything is pressed. *)

val ledger : unit -> entry list
(** Oldest first. Empty when no machine is loaded. *)
