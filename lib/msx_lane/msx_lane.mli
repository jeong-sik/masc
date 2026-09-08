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
  disk : string option;
      (** floppy image file name (.dsk), if one is in the drive. A disk boots
          through the interface ROM that takes the cartridge slot, so a disk
          and a cartridge cannot both run — see {!load}. *)
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

val disk_boot_frames : int
(** Extra frames a disk load runs before {!boot_frames}: the C-BIOS warm-up
    the second-stage-call replay ([Msx.boot_disk]) needs before it puts the
    machine in the loader's hands. *)

val load :
  ledger_dir:string ->
  roms_dir:string ->
  cart_path:string option ->
  disk_path:string option ->
  (observation, error) result
(** Creates the workspace machine, replacing any previous one. [roms_dir]
    holds the C-BIOS triple (cbios_main_msx2 / cbios_logo_msx2 / cbios_sub);
    the empty string means no BIOS and the bus reads 0xFF. The ledger is
    [ledger_dir/ledger.jsonl], truncated: a new machine starts a new ledger.

    [disk_path] plugs a raw .dsk floppy image into drive A and boots it
    through the warm-up replay: {!disk_boot_frames} of C-BIOS, then
    [Msx.boot_disk] re-enters the image's boot sector with the loader
    running — the path a game's loader reaches its title screen on (the
    cart-INIT path the core also wires reboots mid-boot). A disk therefore
    wins over [cart_path] — the slot is one, and the replay wants it empty.
    A rejected disk boot preserves the previous machine and ledger. Successful
    loading alone is not evidence that a game reaches an interactive screen. *)

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

type frame = {
  number : int;  (** frames stepped since power-on *)
  width : int;
  height : int;
  rgb : string;  (** width*height*3 bytes, row-major RGB *)
  mode : string;
  cartridge : string option;
  disk : string option;  (** floppy image file name, if one is in the drive *)
}

val frame : unit -> frame option
(** The current native-resolution frame, or [None] when no machine is loaded.
    A spectator renders this; the pixels are the client's to downsample. *)

val save : path:string -> (observation, error) result
(** Atomically replace a named checkpoint with the complete machine and ledger.
    Does not advance or eject the machine. *)

val restore : path:string -> ledger_dir:string -> (observation, error) result
(** Restore an independently decoded checkpoint. Invalid files leave the current
    machine and ledger intact; ROM/media bytes come from the checkpoint. *)

val change_disk : path:string -> backup_path:string -> (observation, error) result
(** Decode a replacement in a private machine copy, checkpoint the outgoing
    machine, then publish the swap. Never reboots or advances game time. *)
