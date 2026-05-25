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

(** Save [ckpt] via the OAS Checkpoint_store when an Eio FS is
    available; falls back to atomic file write otherwise. Always
    appends to the OAS history archive on success. *)
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
