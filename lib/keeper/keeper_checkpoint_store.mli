(** Keeper checkpoint store — legacy + OAS checkpoint persistence,
    OAS history archive, and SDK error classification. *)

(** [ckpt-] prefix on legacy checkpoint files. *)
val checkpoint_prefix : string

(** [.json] suffix on legacy checkpoint files. *)
val checkpoint_suffix : string

(** [true] iff [filename] is a legacy keeper checkpoint file. *)
val is_checkpoint_file : string -> bool

(** Sorted-descending list of legacy checkpoint filenames in
    [session_dir] (latest first). *)
val list_checkpoints : session_dir:string -> string list

(** Number of legacy checkpoints retained after [save] auto-prune. *)
val max_checkpoints_retained : int

(** Remove all legacy checkpoints beyond the [keep] most recent.
    Returns the number deleted. *)
val prune : session_dir:string -> keep:int -> int

(** Atomically write [ckpt] to [session_dir/<id>.json]; auto-prunes
    older entries to [max_checkpoints_retained]. Logs and swallows
    write failures. *)
val save :
  session_dir:string -> Keeper_types.checkpoint -> unit

(** Parse a legacy checkpoint JSON file. Raises on malformed JSON. *)
val parse_checkpoint_file : string -> Keeper_types.checkpoint

(** Load the newest legacy checkpoint in [session_dir]; logs and
    returns [None] on parse failure. *)
val load_latest :
  session_dir:string -> Keeper_types.checkpoint option

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
  Oas.Checkpoint.t -> string

(** Save [ckpt] to the OAS history archive in [session_dir],
    pruning to [max_oas_history_retained] entries. Logs and
    swallows write failures. *)
val save_oas_history :
  session_dir:string -> Oas.Checkpoint.t -> unit

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
  Oas.Checkpoint.t ->
  (unit, string) result

(** Load failure classification used by callers to distinguish
    cold-start absence from real I/O / parse / SDK errors. *)
type checkpoint_load_error =
  | Not_found
  | Store_error of string
  | Parse_error of string
  | Io_error of string
  | Sdk_other_error of string

(** [true] iff [detail] matches a known "file not found" rendering
    across Eio.Io, Unix_error, Sys_error, and the legacy masc-mcp
    [no_such_file] short-form. *)
val is_not_found_detail : string -> bool

(** Project an [Oas.Error.sdk_error] to [checkpoint_load_error]. *)
val classify_sdk_error :
  Oas.Error.sdk_error -> checkpoint_load_error

(** Sequence a [('a, 'e) result] list into [('a list, 'e) result],
    short-circuiting on the first [Error]. *)
val result_all : ('a, 'e) result list -> ('a list, 'e) result

(** Strict content-block parser used for compat OAS checkpoint
    decode. Errors carry an [Oas.Error.sdk_error]. *)
val content_block_of_json_strict :
  Yojson.Safe.t -> (Oas.Types.content_block, Oas.Error.sdk_error) result

(** Compat role parser — accepts trim/case variations and rejects
    unknown roles via [Oas.Error.UnknownVariant]. *)
val role_of_string_compat :
  string -> (Oas.Types.role, Oas.Error.sdk_error) result

(** Compat message-of-json parser. Errors carry an
    [Oas.Error.sdk_error]. *)
val message_of_json_compat :
  Yojson.Safe.t -> (Oas.Types.message, Oas.Error.sdk_error) result

(** Re-shape legacy checkpoint JSON so unknown roles default to
    [assistant] before handing it to the OAS deserializer. *)
val normalize_checkpoint_json_for_sdk : Yojson.Safe.t -> Yojson.Safe.t

(** Compat [Oas.Checkpoint.of_json] that re-parses messages with
    [message_of_json_compat] when the SDK rejects the raw shape. *)
val checkpoint_of_json_compat :
  Yojson.Safe.t -> (Oas.Checkpoint.t, Oas.Error.sdk_error) result

(** Compat [Oas.Checkpoint.of_string]: tries the SDK parser first,
    then falls back to [checkpoint_of_json_compat] on the
    UTF-8-sanitized raw JSON. *)
val checkpoint_of_string_compat :
  string -> (Oas.Checkpoint.t, Oas.Error.sdk_error) result

(** Load a single OAS history archive entry. Returns [Not_found]
    when the file does not exist; classifies SDK errors via
    [classify_sdk_error]. *)
val load_oas_history_file :
  session_dir:string ->
  snapshot_id:string ->
  (Oas.Checkpoint.t, checkpoint_load_error) result

(** Load the canonical OAS checkpoint for [session_id]. Uses the
    OAS Checkpoint_store when Eio FS is available; falls back to a
    direct atomic-file read otherwise. *)
val load_oas :
  session_dir:string ->
  session_id:string ->
  (Oas.Checkpoint.t, checkpoint_load_error) result
