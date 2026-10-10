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

module Screen_change : module type of Screen_change
(** The pure settle/change judgement behind {!step_until_change}, re-exported
    for its ROM-less tests. *)

type key = Msx.key

val key_of_string : string -> (key, string) result
(** Names a caller may send: [up down left right space esc return
    trigger_a trigger_b f1 f2 f3 f4 f5], or one printable character. The
    character's place in the matrix is checked when it is pressed. *)

val key_to_string : key -> string
(** Canonical ledger spelling; inverse of {!key_of_string} for named keys. *)

val is_bitmap_mode : Msx.display_mode -> bool
(** Whether a display mode draws pixels rather than a name table:
    GRAPHIC4-7 and the undefined combinations. In those the observation's
    [screen_text] is empty — the name table underneath is leftover noise, and
    sending it anyway cost ~2 KB per screen (measured over 315 keeper calls
    averaging 3.7 KB), which is what crowds out the useful fields. *)

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
  ppi_a : int;  (** Primary-slot selection register, as read from PPI port A. *)
  slot3_sel : int;  (** Stored subslot byte; hardware reads address FFFFh inverted. *)
  screen_text : string;
      (** name table as characters — meaningful when the pattern set is a font.
          Empty in bitmap modes ({!is_bitmap_mode}): there the name table is
          leftover noise, not what the game drew; read {!screen_view} or the
          image artifact instead. *)
  screen_view : string;
      (** a 64x24 luminance ASCII picture of the frame — readable in any mode,
          for a keeper with no vision runtime. Rows are newline-separated. *)
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

val entry_json : entry -> Yojson.Safe.t
(** The native input ledger's record encoding. *)

(** Every [error] is answered before the call changes what the workspace
    keeps: the machine, its input ledger, a checkpoint's contents. A disk boot
    or a disk swap that fails ran on a private copy of the machine; a key the
    matrix has no place for is released before a frame runs; a checkpoint or
    ledger write that fails leaves the old file, because the new one is
    renamed into place last. A caller can therefore report any [error] as a
    refusal that took no effect. An exception is not an [error]: a ledger
    append that raises mid-press may already have run frames. *)
type error =
  | Activity_disabled
  | Activity_unobserved
  | No_machine  (** nothing loaded — [masc_msx_load] first *)
  | Invalid_request of string  (** the caller's arguments *)
  | Unreadable of string
      (** a file that is there and will not read: a ROM, a cartridge, a
          checkpoint. A path that does not exist is [Invalid_request] --
          the caller named it. *)

val error_to_string : error -> string

val install_activity_observer : (unit -> Machine_configuration.activity) option -> unit
(** Install the published Runtime observer. [None] means unobserved, so new
    execution is refused. Installation never changes the machine itself. *)
val activity : unit -> Machine_configuration.activity
(** Lock-free activity reading. New execution is admitted once at entry; already
    admitted work finishes even if activity changes while it waits/runs.
    Inspection, checkpoint saving, eject and controller release remain available. *)

val frames_per_second : int
(** The machine's frame rate, 60 (NTSC). The one number a caller multiplies
    seconds by to name a span in frames. *)

val max_frames_per_call : int
(** 300 frames = 5 seconds at {!frames_per_second}; about 90 ms of emulation. *)

val boot_frames : int
(** Frames run at {!load} before the first observation, so the first picture
    is the C-BIOS logo rather than a blank screen — the TUI's convention. *)

val disk_boot_frames : int
(** Extra frames a disk load runs before {!boot_frames}: the C-BIOS warm-up
    the second-stage-call replay ([Msx.boot_disk]) needs before it puts the
    machine in the loader's hands. *)

type medium =
  | Cartridge of string  (** file name in the slot *)
  | Disk of string  (** file name in drive A *)

type transition = {
  before : medium option;  (** what the machine ran when the load began *)
  after : medium option;  (** what the new machine runs *)
}
(** The medium a load replaced and the one it installed, both read inside
    the critical section the load commits under. A medium is the disk when
    one is in the drive (the slot is empty then), else the cartridge; [None]
    with no machine or a BIOS-only boot. Two loads that serialise on the lane
    see distinct transitions: the second one's [before] is the first one's
    [after]. *)

type loaded = {
  observation : observation;
  transition : transition;
}

val load :
  ledger_dir:string ->
  roms_dir:string option ->
  cart_path:string option ->
  disk_path:string option ->
  (loaded, error) result
(** Creates the workspace machine, replacing any previous one. [Some roms_dir]
    holds the C-BIOS triple (cbios_main_msx2 / cbios_logo_msx2 / cbios_sub),
    all three required -- a directory missing one is [Unreadable] naming that
    file, never a machine with an empty ROM in it. [None] means no BIOS and
    the bus reads 0xFF. The ledger is
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

type until_change = {
  frames_run : int;
      (** frames actually advanced — less than the budget when it settled early *)
  changed : bool;
      (** the screen ended up different from the start; false with a settled
          screen is the "this scene waits for a key" signal *)
  stable : bool;
      (** stopped because the screen settled; false means the budget ran out *)
}

val step_until_change : max_frames:int -> (observation * until_change, error) result
(** Advances in [Screen_change.default] intervals until the coarse screen view
    settles (two near-equal fingerprints in a row — a blinking cursor alone is
    not movement) or [max_frames] (1..{!max_frames_per_call}) runs out. The
    judgement core is pure and machine-free: {!Screen_change}. *)

val press :
  who:string ->
  keys:key list ->
  hold_frames:int ->
  step_frames:int ->
  sequence:bool ->
  (observation, error) result
(** With [sequence] false, holds every key in [keys] together for
    [hold_frames], then runs the rest of [step_frames] released -- a chord.
    With [sequence] true, taps each key in turn (down [hold_frames], up, then
    the rest of [step_frames] idle) so [keys] is a menu sequence, not a chord;
    the call advances [List.length keys * step_frames] frames.
    [1 <= hold_frames <= step_frames <= max_frames_per_call]. A key the matrix
    has no place for is refused before anything is pressed.

    A press puts keys down only inside its own call. If recording an edge
    raises -- the ledger file will not open or will not take the write -- the
    keys the call put down are released before the exception leaves, and the
    edge that was not written is not in {!ledger}. Frames the call already ran
    stay run, and edges it wrote before the failure stay written: the ledger
    can then hold a key-down with no key-up after it while the machine has
    that key up, so replaying that ledger no longer reproduces the machine. *)

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
    A spectator renders this; the pixels are the client's to downsample.
    Repeated reads of the same machine state reuse immutable rendered pixels.
    Advancing, loading, restoring, or replacing media invalidates that snapshot. *)

val capture : unit -> (observation * frame, error) result
(** Copy observation and pixels under the same machine lock. Does not advance
    the machine. Consumers encode/persist the immutable copy outside the lock. *)

type identified_capture = {
  incarnation : string;
      (** Fresh identity on successful load/restore. Reads and time progression
          preserve it, including frame counters restored to an earlier value. *)
  observation : observation;
  frame : frame;
  input_count : int;
  input_ledger : entry list;
      (** Newest-first immutable input records through [input_count], captured
          with the frame and incarnation. Encoding/persistence belongs outside
          the machine lock. *)
}

val capture_with_identity : unit -> (identified_capture, error) result
(** Atomically reads the same machine as {!capture}, with its explicit history
    identity, input cursor and ledger. Never steps, peeks, or changes a RAM
    baseline. The immutable list is shared without traversal or copying. *)

(** {b Spectating} — one read a watcher can repeat cheaply. *)

type change_mark = {
  count : int;
      (** The machine change counter. It rises once after a call runs frames,
          including a call that raises after partial progress, and right
          after load, eject, restore or change_disk installs or removes a
          machine. A call refused before it runs frames leaves it alone.
          Nothing resets it -- eject and the next load
          keep counting -- so a value never names two screens while the server
          runs. A restarted server counts from 0 again, so the count alone
          can repeat across restarts; {!live} answers [Unchanged] only when
          the incarnation matches too. *)
  incarnation : string;  (** as in {!identified_capture} *)
}

type 'mark publication = 'mark Machine_live_publication.t =
  | No_screen
  | Stable of 'mark
  | Running of 'mark
type published_state = change_mark publication

val current_publication : unit -> published_state
(** An atomic, lock-free read. [Running] is published before frames mutate
    the machine; a spectator then uses {!live} on a systhread and waits for
    the final frame. [Stable mark] permits an immediate unchanged answer for
    the same count and incarnation. A failed run returns to [Stable] with a
    raised count after any partial progress. *)

type live =
  | Nothing_loaded  (** no machine: nothing to watch *)
  | Unchanged of change_mark
      (** [since] names the current count and the current incarnation *)
  | Changed of change_mark * frame
      (** [since] was absent, or its count or incarnation differs *)

val live : since:change_mark option -> live
(** Reads the count, the incarnation and, when either differs from [since], the
    pixels under one hold of the machine lock, the same lock a call that
    advances the machine holds, so a [Changed] mark always names its pixels.
    Never steps or writes anything. The lock is a stdlib mutex that a step can
    hold for a whole call, so an Eio caller compares [since] with
    {!current_publication} first and runs this, in
    [Eio_unix.run_in_systhread], when the mark differs or frames are running. *)

val step_frame : frames:int -> (frame * entry list * change_mark, error) result
(** Advance once and capture pixels, metadata, ledger and the change mark
    under one machine lock. The tick response uses this mark so a concurrent
    press cannot attach a newer mark to older pixels. Encoding happens outside
    that lock. *)

(** {b RAM introspection} — the state sensor. The screen is the expensive
    detour a human eye needs; the game's truth is in memory, and the core
    already holds all of it. *)

type ram_change = {
  address : int;  (** logical address of the first changed byte *)
  length : int;  (** consecutive changed bytes *)
  from_hex : string;  (** snapshot bytes, hex pairs *)
  to_hex : string;  (** current bytes, hex pairs *)
}

type ram_diff = {
  changes : ram_change list;  (** up to {!ram_diff_max_runs} runs, ascending *)
  truncated : bool;  (** more runs existed than the cap returned *)
  changed_bytes : int;  (** total bytes that differ, runs and beyond *)
}

val peek_max_bytes : int
val ram_diff_max_runs : int

val peek : address:int -> length:int -> (string, error) result
(** Reads [length] (1..{!peek_max_bytes}) bytes at a logical address
    (0x0000-0xFFFF) as hex pairs, and takes a full 64K snapshot of the
    machine for the next {!ram_diff}. Read-only: writing is the cheat the
    lane refuses (RFC-0439). *)

val ram_diff : unit -> (ram_diff, error) result
(** Changes since the last {!peek}: consecutive differing bytes as runs with
    before/after hex. [Error Invalid_request] before any peek. The snapshot
    survives machine swaps — a reload after a peek reads as wholesale change,
    which it is. *)

(** {b Core identity} — the linked ocaml-msx source digest and exact source
    commit embedded by the linked core build, the exact commit at the build-time
    CI pin, and whether the linked digest matches that pin. *)

type core = {
  source_digest : string;
      (** the linked ocaml-msx core's own identity: a digest of its [lib/]
          sources, computed by its build ([Msx_core_identity]). *)
  source_commit : string option;
      (** the exact commit embedded by the linked core build, or [None] when
          that build saw no clean Git checkout: dirty or archive builds, and
          the opam-pinned install that CI uses. *)
  pinned_source_digest : string;
      (** the digest of the core at the CI pin, [OCAML_MSX_SHA] in
          [scripts/opam-pin-external-deps.sh]. *)
  pinned_source_commit : string;
      (** the ocaml-msx commit declared by the CI pin, not an observation of
          the linked core's commit. *)
  matches_pin : bool;
      (** the two digests are equal. [false] means this server runs a
          different core from the one CI builds against — an older opam
          copy, or a vendored checkout on another branch. *)
}
[@@deriving yojson]

val core : core

val core_to_yojson : core -> Yojson.Safe.t
(** PPX-generated serializer, exposed for the [masc_msx_meta] tool. *)

(** {b Checkpoint metadata} — what a saved slot holds, read without
    restoring it. A restore replaces the shared machine a watcher shows,
    so answering "what is in this slot" through {!restore} moved a live
    campaign to ask a question. *)

type checkpoint_info = {
  exists : bool;
      (** true for a successfully inspected slot; missing slots return a typed error. *)
  version : int;  (** the checkpoint envelope version, currently 1 *)
  state_format_version : int option;
      (** the embedded format version after the core validates its state
          envelope and checksum; [None] when the core rejects that envelope.
          This does not deserialize or validate the complete machine payload. *)
  frame : int option;
      (** the saved frame counter. Checkpoint version 1 does not record it —
          reading it would mean decoding the machine — so [None] until a
          format that carries it. *)
  saved_at_unix : float option;
      (** compatibility field for the checkpoint file's modification time. *)
  mtime_utc : string;
      (** the checkpoint file's modification time in UTC ISO-8601 form. *)
  core_sha : string option;
      (** the [Msx_core_identity.source_digest] of the core that saved the
          checkpoint. Checkpoints saved before the field existed read as
          [None] — an unknown core, not a wrong one. *)
  cartridge : string option;  (** file name in the slot, as saved *)
  disk : string option;  (** file name in drive A, as saved *)
  ledger_entries : int;  (** saved input edges *)
  byte_length : int;
      (** the checkpoint file's size in bytes, as read. *)
  sha256 : string;
      (** hex SHA-256 of the checkpoint file's bytes, as read — the payload
          identity a readback compares without parsing the envelope. *)
}

val checkpoint_info : path:string -> (checkpoint_info, error) result
(** Reads one checkpoint file's metadata. Never touches the machine, the
    ledger or the activity gate: inspection stays available when execution
    is disabled. A missing file is [Invalid_request] naming the path; a file
    that is there and will not read is [Unreadable]; bytes that do not
    parse as a checkpoint envelope are [Invalid_request]. *)
val save : path:string -> (observation, error) result
(** Atomically replace a named checkpoint with the complete machine and ledger.
    Does not advance or eject the machine. *)

val restore : path:string -> ledger_dir:string -> (observation, error) result
(** Restore an independently decoded checkpoint. Invalid files leave the current
    machine and ledger intact; ROM/media bytes come from the checkpoint. *)

val change_disk : path:string -> backup_path:string -> (observation, error) result
(** Decode a replacement in a private machine copy, checkpoint the outgoing
    machine, then publish the swap. Never reboots or advances game time. *)


type disk_export = {
  filename : string;
  byte_length : int;
  sha256 : string;
  source_disk : string option;
  frame : int;
}

val export_disk : catalog_dir:string -> filename:string -> (disk_export, error) result
(** Export the currently mounted floppy, including guest writes, to a new .dsk
    in an existing catalog. The name is a simple ASCII stem (letters, digits,
    underscore, hyphen; 1..64 characters) plus lowercase [.dsk].
    Existing destinations, including symlinks, are refused. Machine state,
    input ledger and original media files remain unchanged; no time advances.
    The absolute [catalog_dir] and its ancestors must be real directories,
    owned and kept stable by the process operator during publication. Resolve
    the workspace base before appending its catalog components, not the catalog
    itself: resolving the latter would hide symlinked components.
    Completed bytes are published by an exclusive hard link, so no partial
    destination is visible. This is process-restart persistence, not a promise
    of directory-entry durability across power loss. Filesystem exceptions
    after publication remain exceptions, never pre-effect [error] refusals. *)
