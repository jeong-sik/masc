(** Keeper checkpoint store — OAS checkpoint persistence, OAS
    history archive, and SDK error classification. *)

(** Path of the canonical OAS checkpoint file
    [session_dir/<session_id>.json]. *)
val oas_checkpoint_path :
  session_dir:string -> session_id:string -> string

(** [oas-snapshot-] prefix on OAS history archive entries. *)
val oas_history_prefix : string

(** [.json] suffix on OAS history archive entries. *)
val oas_history_suffix : string

(** [true] iff [filename] is an OAS history archive file. *)
val is_oas_history_file : string -> bool

(** Sorted-descending list of OAS history archive filenames in
    [session_dir]. *)
val list_oas_history_files : session_dir:string -> string list

(** Number of OAS history archive entries retained after a save. *)
val max_oas_history_retained : int

(** Path of an OAS history archive entry within [session_dir]. *)
val oas_history_path :
  session_dir:string -> snapshot_id:string -> string

(** Compose an OAS history archive snapshot id from a checkpoint
    (created_at_ms + keeper_generation suffix). *)
val oas_history_snapshot_id_of_checkpoint :
  Agent_sdk.Checkpoint.t -> string

(** Save [ckpt] to the OAS history archive in [session_dir],
    pruning to [max_oas_history_retained] entries. Logs and
    swallows write failures. *)
val save_oas_history :
  session_dir:string -> Agent_sdk.Checkpoint.t -> unit

(** Delete OAS history archive entries by [snapshot_ids]. Returns
    [(deleted, missing)] in input-order, with [missing] containing
    every snapshot id whose file was absent OR removal failed. *)
val delete_oas_history_files :
  session_dir:string ->
  snapshot_ids:string list ->
  string list * string list

(** Relation between an incoming checkpoint and the current known high
    watermark for the same canonical OAS checkpoint path. *)
type save_oas_relation = [ `Cold | `Forward | `Equal ]

(** Classified checkpoint save result.

    [Stale_noop] is a successful no-op: the canonical checkpoint was left
    untouched because accepting [incoming_turn_count] would move memory
    behind the known high watermark. It must not be treated as keeper
    turn failure, pause, or stop. *)
type save_oas_outcome =
  | Saved of { relation : save_oas_relation; turn_count : int }
  | Stale_noop of { incoming_turn_count : int; known_turn_count : int }

(** Save [ckpt] via the OAS Checkpoint_store when an Eio FS is
    available; falls back to atomic file write otherwise. Always
    appends to the OAS history archive on success.

    RFC-0225 §3.2 checkpoint watermark: returns [Ok Stale_noop] when
    [ckpt.turn_count] is older than the last checkpoint saved for the
    same session. A stale writer must not clobber a conversation the
    newer writer already persisted, but this is not a keeper lifecycle
    failure. Equal turn_count re-saves pass. If the existing checkpoint is
    present but unreadable, returns [Error] instead of treating the write as
    a cold save. *)
val save_oas_classified :
  session_dir:string ->
  Agent_sdk.Checkpoint.t ->
  (save_oas_outcome, string) result

(** Compatibility wrapper around {!save_oas_classified}. [Saved] and
    [Stale_noop] both return [Ok ()]; only real store/IO failures return
    [Error]. *)
val save_oas :
  session_dir:string ->
  Agent_sdk.Checkpoint.t ->
  (unit, string) result

(** Load failure classification used by callers to distinguish
    cold-start absence from real I/O / parse / SDK errors. *)
type checkpoint_load_error =
  | Not_found
  | Store_error of string
  | Parse_error of string
  | Io_error of string
  | Sdk_other_error of string

val checkpoint_load_error_to_string : checkpoint_load_error -> string

(** Project an [Agent_sdk.Error.sdk_error] to [checkpoint_load_error].

    RFC-0089 G4: this no longer classifies [Not_found] from string-matched
    [FileOpFailed.detail]. Cold-start "checkpoint absent" is detected at
    the OS boundary via [Agent_sdk.Checkpoint_store.exists] *before* the
    SDK [load] call, so any [sdk_error] reaching this function is a real
    I/O / parse / SDK fault and routes accordingly. *)
val classify_sdk_error :
  Agent_sdk.Error.sdk_error -> checkpoint_load_error

(** Load a single OAS history archive entry. Returns [Not_found]
    when the file does not exist; classifies SDK errors via
    [classify_sdk_error]. *)
val load_oas_history_file :
  session_dir:string ->
  snapshot_id:string ->
  (Agent_sdk.Checkpoint.t, checkpoint_load_error) result

(** Load the canonical OAS checkpoint for [session_id]. Uses the
    OAS Checkpoint_store when Eio FS is available; falls back to a
    direct atomic-file read otherwise. *)
val load_oas :
  session_dir:string ->
  session_id:string ->
  (Agent_sdk.Checkpoint.t, checkpoint_load_error) result

module For_testing : sig
  val reset_stale_write_guard : unit -> unit
  (** Clear the process-local last-saved turn_count map so tests that
      reuse session ids across temp dirs start from a cold state. *)
end
