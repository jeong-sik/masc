(** Immutable original of one declared media reading. This module captures and
    validates data; it neither selects a reader nor grants or performs an effect.
    A restored binding is a semantic recipe, never an execution capability. *)

type owner
type subject
type verified_source
type t

type error =
  | Invalid_binding of string
  | Source_unavailable of Agent_core.History.media_error

val error_to_string : error -> string

val observe_owner :
  base_path:string -> keeper_name:string -> (owner, error) result
(** Observe the canonical workspace and its actual owned root through the
    shared directory reader, and validate the Keeper name. The returned data
    includes physical root identity; no directory descriptor escapes. This is
    an observation, not a workspace lease or a held process working directory. *)

val owner_base_path : owner -> string
val owner_keeper_name : owner -> string
val check_owner : expected:owner -> owner -> (unit, error) result
(** Compare complete workspace/root identity and Keeper, including when an
    original lookup is absent and supplies no subject to check. *)

val subject :
  owner -> kind:Media_reading_kind.t -> media_type:string ->
  Agent_core.History.stored -> (subject, error) result
(** The exact owner, kind, MIME and Stored reference, independent of reader
    declarations, source availability, execution and continuation route. *)

val subject_base_path : subject -> string
val subject_keeper_name : subject -> string
val same_subject : subject -> subject -> bool
val check_workspace : owner -> subject -> (unit, error) result
(** Compare canonical workspace and captured physical root identity, excluding
    the Keeper and attachment. Check every discovered summary before selecting
    a subject; a replaced root must not hide earlier originals. *)

val verify_source :
  media_store:Agent_core.History.media_store ->
  subject -> (verified_source, error) result
(** Read all original bytes and recompute their SHA and length. Only these
    verified bytes can supply the complete data URI; no URI or path is accepted
    from a caller. A failed read never permits a fresh original. *)

val create :
  execution_id:string -> source:verified_source ->
  declaration:Runtime_schema.media_reader_decl ->
  launch:Keeper_sandbox_remote.Stdio_request.binding ->
  causal_context:Keeper_gate.causal_context option -> task_id:string option ->
  continuation_channel:Keeper_continuation_channel.t ->
  (t, error) result
(** Freeze all seven declaration fields, exact complete adapter arguments,
    prepared owner/argv binding and original provenance. [execution_id] is a
    caller-reserved identity, not evidence that an execution started. [None]
    causal context means explicit unavailable approval origin; [None] task
    means no observed task. Neither is inferred from current runtime state.
    The binding must name this owner and the declaration's [command :: args]. *)

val original_subject : t -> subject
val declaration : t -> Runtime_schema.media_reader_decl
val declaration_digest : Runtime_schema.media_reader_decl -> string
val launch : t -> Keeper_sandbox_remote.Stdio_request.binding
val arguments : t -> Yojson.Safe.t
val data_uri : t -> string
val origin : t -> Keeper_approval_origin.t
val causal_context : t -> Keeper_gate.causal_context option
val task_id : t -> string option
val continuation_channel : t -> Keeper_continuation_channel.t
val request_id : t -> string
val execution_id : t -> string
val original_digest : t -> string
(** SHA-256 of the complete canonical original JSON, including its request ID.
    The request ID itself hashes the complete capture before adding that ID. *)

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, error) result
(** Strict current-schema decoder: reject unknown/duplicate/missing fields,
    revalidate nested codecs and binding owner/argv, decode all retained input
    bytes, and recompute source, declaration and request identities. This is
    pure captured-evidence validation, not current workspace authority. *)

val summary : t -> Yojson.Safe.t
val summary_subject :
  request_id:string -> request_digest:string -> Yojson.Safe.t ->
  (subject, error) result
(** Validate the complete summary schema, request/execution ID and digest
    forms, and bind its request ID/body digest to the actual discovered record
    metadata before returning its subject. Does not claim to have read the
    body. Metadata/workspace checks may happen early, but the subject is
    untrusted until [restore] verifies the exact summary against the body.
    Discovery must restore every live scope body before subject filtering. *)

val restore : Lane_addon_tool_request_owner.retained -> (t, error) result
(** Restore the semantic original and verify its request ID, complete body
    digest and exact summary against the retained record. The media owner
    separately validates the fixed scope/installation/package/tool header. *)
