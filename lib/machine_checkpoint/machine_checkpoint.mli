(** Named whole-machine checkpoints a workspace machine lane keeps on disk.

    A lane (the DOS machine today) hands this module two things: the machine's
    own bytes, which only that machine's core can read, and a small JSON
    [meta] the lane reads back itself (its input ledger, its step count). This
    module owns what every machine shares: the slot name, the file under a
    directory, a header that says which machine and which format wrote it,
    zstd compression, a checksum, and an atomic replace.

    A checkpoint is read only by the machine and the format that wrote it.
    Anything else is refused; there is no reader for another format. The
    writing core's identity rides in the header to be shown, never compared:
    a format number bumped by hand decides, not a digest that changes with
    every edit to the core.

    File layout: ["MASC-MACHINE-CHECKPOINT\000"], then length-prefixed machine
    tag and core identity, the format (int64), the body's length (int64), the
    body's MD5 (16 bytes), a compression byte, and the body — itself the
    length-prefixed [meta] JSON followed by the machine bytes. *)

type machine = Dos | Msx

val machine_to_string : machine -> string

type slot = private string
(** 1..64 letters, digits, underscores or hyphens: a file name, never a path. *)

val slot_of_string : string -> (slot, string) result
val slot_to_string : slot -> string

type header = {
  machine : machine;
  format : int;  (** the lane's own format number; the one thing compared *)
  core : string;  (** the writing core's identity, for display *)
}

type error =
  | No_slot of slot  (** nothing was saved under this name *)
  | Unreadable of string  (** a file that is there and will not read *)
  | Other_machine of { saved : machine; expected : machine }
  | Other_format of { saved : int; expected : int }
  | Corrupt of string
      (** not a checkpoint, or its checksum or layout does not hold *)

val error_to_string : error -> string

val path : dir:string -> slot -> string
(** [dir/<slot>.ckpt]. *)

val write :
  dir:string -> slot -> header -> meta:Yojson.Safe.t -> machine_bytes:string ->
  (unit, string) result
(** Replaces the slot atomically: the file is written beside its target and
    renamed over it, so a reader sees the old checkpoint or the new one,
    never half of one. Creates [dir]. *)

type contents = { header : header; meta : Yojson.Safe.t; machine_bytes : string }

val read :
  dir:string -> slot -> machine:machine -> format:int -> (contents, error) result
(** The slot's checkpoint, refused unless [machine] and [format] match. *)

type listed = {
  slot : slot;
  size : int;  (** bytes on disk *)
  modified : float;  (** Unix time of the last write *)
  header : (header, error) result;
      (** a file whose header does not read is still listed, with why *)
}

val list : dir:string -> (listed list, string) result
(** Every [*.ckpt] under [dir] whose name is a slot, by slot name. A missing
    [dir] is an empty list. *)
