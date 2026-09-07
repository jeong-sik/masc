(** Private upload snapshots are owned by a browser session once WebDriver may
    have exposed them to a File object. Selection completion does not end that
    ownership: Firefox can open the file lazily during a later read/submit. *)
type owner
val create_owner : unit -> owner
val claim : owner:owner -> paths:string list -> unit
(** Claim only an exact registered snapshot batch. Arbitrary caller paths are
    never registered, owned or deleted by this module. Call before mutation. *)
val release_owner : owner -> unit
(** Release only after confirmed session teardown or invalid-session evidence.
    Transport failure/cancellation is not teardown evidence. *)
val with_staged_files :
  files:(string * (unit -> (string, string) result)) list ->
  (string list -> 'a) -> ('a, string) result
(** Each pair supplies a basename and an authorized byte reader. Unclaimed
    snapshots are removed when the callback exits. Claimed snapshots survive
    callback success, failure and cancellation until their owner is released. *)
