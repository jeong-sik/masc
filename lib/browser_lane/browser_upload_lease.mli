(** Private upload snapshots are owned by a browser session once WebDriver may
    have exposed them to a File object. Selection completion does not end that
    ownership: Firefox can open the file lazily during a later read/submit. *)
val max_file_bytes : int
(** Existing per-file upload resource bound, shared by host staging and worker copies. *)

type owner
val create_owner : unit -> owner
val claim : owner:owner -> paths:string list -> unit
(** Claim only an exact registered snapshot batch. Arbitrary caller paths are
    never registered, owned or deleted by this module. Call before mutation. *)
val release_owner : owner -> unit
(** Release only after confirmed session teardown or invalid-session evidence.
    Transport failure/cancellation is not teardown evidence. *)
type 'read_error staging_error =
  | Read_failed of 'read_error
  | Snapshot_failed of string

val with_staged_files :
  files:(string * (unit -> (string, 'read_error) result)) list ->
  (string list -> 'a) -> ('a, 'read_error staging_error) result
(** Each pair supplies a basename and an authorized byte reader. Unclaimed
    snapshots are removed when the callback exits. Reader errors retain their
    source type; snapshot errors carry this module's message. Claimed snapshots
    survive callback success, failure and cancellation until their owner is
    released. *)

type snapshot
val prepare_files : ?temp_dir:string ->
  files:(string * (unit -> (string, 'read_error) result)) list -> unit ->
  (snapshot, 'read_error staging_error) result
(** Prepare an immutable registered batch without borrowing a callback scope.
    The caller must [release] it. A browser claim transfers its lifetime to the
    session owner, so [release] never removes a claimed batch. [temp_dir] must
    be a private allocation owned by the caller. *)
val paths : snapshot -> string list
val release : snapshot -> unit
val pending : paths:string list -> bool
(** True only for an exact, currently registered, unclaimed snapshot batch in
    this process. Used by the host before minting a cross-process upload grant. *)
