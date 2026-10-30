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

val slot_of_arguments : default:string -> Yojson.Safe.t -> (slot, string) result
(** The slot a checkpoint call names: an object whose only field, if any, is
    ["slot"] holding one string. No field means [default]. The name is checked
    like {!slot_of_string}; any other shape is an [Error] naming what is wrong. *)

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
(** Replaces the slot atomically: the file is written beside its target,
    fsynced, and renamed over it. A reader sees the old checkpoint or the new
    one, never half of one, and a crash after [Ok] cannot leave an empty or
    partial file in the slot, because the bytes were fsynced before the
    rename. The directory is fsynced after the rename, but an error from that
    fsync is ignored, as is a file system's refusal to fsync at all (this is
    [Fs_compat.save_file_atomic]; its strict sibling reports both). So a crash
    right after [Ok] can bring the previous checkpoint back, which is a valid
    one. Creates [dir]. *)

val copy : dir:string -> from:slot -> to_:slot -> (unit, string) result
(** Copies the file of [from] over [to_] byte for byte, with {!write}'s atomic
    and fsynced replace. [from] is not read as a checkpoint, so a damaged or
    foreign one copies too, and it is never modified. [Error] when [from]
    cannot be read or [to_] cannot be replaced; [to_] is then as it was. *)

type contents = { header : header; meta : Yojson.Safe.t; machine_bytes : string }

val read :
  dir:string -> slot -> machine:machine -> format:int -> (contents, error) result
(** The slot's checkpoint, refused unless [machine] and [format] match. *)

type meta_contents = { header : header; meta : Yojson.Safe.t; modified : float }

val read_meta :
  dir:string -> slot -> machine:machine -> format:int -> (meta_contents, error) result
(** {!read} without the machine bytes: still the full header check, checksum
    and decompression -- nothing here skips those -- only the final
    [String.sub] that would carve the decompressed body's tail into a second
    string is skipped. For a caller that wants to say what a checkpoint is --
    not restore it -- so it never makes that second, guest-memory-sized copy
    just to read who saved it. [modified] is the file's own mtime, the slot's
    [Unix.stat], the same clock {!listed.modified} reads. *)

type listed = {
  slot : slot;
  size : int;  (** bytes on disk *)
  modified : float;  (** Unix time of the last write *)
  header : (header, error) result;
      (** a file whose header does not read is still listed, with why *)
}

val list : dir:string -> (listed list, string) result
(** Every [*.ckpt] under [dir] whose name is a slot, by slot name. A missing
    [dir] is an empty list. Each file is read from its front only, as far as
    the header: the machine bytes behind it are not read, so listing a
    directory of large checkpoints costs a few dozen bytes a file, not their
    size. *)
