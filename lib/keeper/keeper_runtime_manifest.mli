(** Durable per-turn decision manifest for keeper runtime diagnosis.

    The manifest is intentionally narrower than execution receipts.  Receipts
    describe what happened after a turn; manifest rows record the routing and
    context decisions that explain why the turn took that path.

    All type definitions ([event_kind], [links], [t], [turn_context]) and
    their pure converters live in {!Keeper_runtime_manifest_types}.
    Re-exported here so callers can continue using
    [Keeper_runtime_manifest.event_kind] etc. without reaching into
    the types submodule.

    {2 Layered SSOT}

    The manifest is structured in five layers.  Each layer has a single
    authoritative source of truth and a clear boundary:

    - {b Layer 1 — Identity}: [keeper_name], [agent_name], [trace_id],
      [generation].  Stable across every event in a turn.  SSOT is the
      keeper registry entry at turn start.

    - {b Layer 2 — Time}: [ts], [source_clock], [clock_refs].  Provides
      wall / monotonic / logical / provider / event_bus provenance.
      SSOT is the runtime clock snapshot taken when the event is emitted.

    - {b Layer 3 — Event}: [event_kind].  Tracks turn/routing/context
      lifecycle boundaries. Tool calls are recorded by the hook-owned
      tool-call log, not duplicated in manifest lineage rows.

    - {b Layer 4 — Payload}: [payload_role] ([Model_input],
      [Operator_evidence], [Checkpoint], [Memory_store]).  Classifies the
      semantic role of the decision data.  SSOT is the caller contract
      at the injection point.

    - {b Layer 5 — Trust}: public projection allowlist.  Redacts sensitive
      fields based on consumer identity.  SSOT is the consumer capability
      profile. *)

(** {1 SSOT Types} *)
include module type of struct
  include Keeper_runtime_manifest_types
end

(** {1 Own-module types} *)

type payload_role =
  | Model_input
  | Operator_evidence
  | Checkpoint
  | Memory_store

type source_clock =
  | Wall
  | Monotonic
  | Logical
  | Provider
  | Event_bus

(** {2 F5: Clock separation policy}

    Wall-clock ([ts]) is display-only.  Ordering uses logical
    [parent_event_id]/[caused_by]/[logical_seq].  Latency comparison
    ([elapsed_ms]) is only valid between events that share the same
    [source_clock]. *)

type logical_ordering = {
  parent_event_id : string option;
  caused_by : string option;
  logical_seq : int option;
}

type status =
  | Skipped
  | Other of string

(** {1 Own-module vals} *)

val payload_role_to_string : payload_role -> string
val payload_role_of_string : string -> payload_role option

val source_clock_to_string : source_clock -> string
val source_clock_of_string : string -> source_clock option
val source_clock_of_event : event_kind -> source_clock

val schema_version : int
val manifest_file_suffix : string
val safe_segment : string -> string

val status_of_string : string -> status
val status_to_string : status -> string
val status_is_skipped : t -> bool

val clock_refs :
  ?edge_id:string ->
  ?lane:string ->
  ?source_clock:source_clock ->
  ?observed_at:string ->
  ?started_at:string ->
  ?finished_at:string ->
  ?elapsed_ms:int ->
  ?provider_attempt_id:string ->
  ?tool_batch_id:string ->
  ?checkpoint_id:string ->
  ?compaction_id:string ->
  ?compaction_source:string ->
  ?event_bus_correlation_id:string ->
  ?event_bus_run_id:string ->
  ?parent_event_id:string ->
  ?caused_by:string ->
  ?logical_seq:int ->
  unit ->
  Yojson.Safe.t

val clock_refs_for_context :
  turn_context ->
  event:event_kind ->
  ?oas_turn_count:int ->
  ?elapsed_ms:int ->
  ?event_bus_correlation_id:string ->
  ?event_bus_run_id:string ->
  ?parent_event_id:string ->
  ?caused_by:string ->
  ?logical_seq:int ->
  ?compaction_source:string ->
  unit ->
  Yojson.Safe.t

val with_clock_refs : clock_refs:Yojson.Safe.t -> Yojson.Safe.t -> Yojson.Safe.t

val with_payload_role : payload_role:payload_role -> Yojson.Safe.t -> Yojson.Safe.t

val make :
  ?ts:string ->
  keeper_name:string ->
  ?agent_name:string ->
  trace_id:string ->
  ?generation:int ->
  ?keeper_turn_id:int ->
  ?oas_turn_count:int ->
  ?logical_seq:int ->
  event:event_kind ->
  ?runtime_id:string ->
  ?status:string ->
  ?decision:Yojson.Safe.t ->
  ?receipt_path:string ->
  ?checkpoint_path:string ->
  ?tool_call_log_path:string ->
  unit ->
  t

val make_for_context :
  turn_context ->
  event:event_kind ->
  ?oas_turn_count:int ->
  ?logical_seq:int ->
  ?runtime_id:string ->
  ?status:string ->
  ?decision:Yojson.Safe.t ->
  ?receipt_path:string ->
  ?checkpoint_path:string ->
  ?tool_call_log_path:string ->
  unit ->
  t

val to_json : t -> Yojson.Safe.t
val public_to_json : t -> Yojson.Safe.t
val public_projection_of_decision : Yojson.Safe.t -> Yojson.Safe.t
(** Decode and validate the common persisted envelope before classifying its
    event as active, retired, or genuinely unsupported. *)
val decode_persisted_row : Yojson.Safe.t -> (decoded_row, string) result
val of_json : Yojson.Safe.t -> (t, string) result

val execution_receipt_path_for_today :
  Workspace.config -> keeper_name:string -> string

(** [.masc/keepers/<keeper>/runtime-manifests]. *)
val base_dir : Workspace.config -> keeper_name:string -> string

(** [.masc/keepers/<keeper>/runtime-manifests/<trace_id>.jsonl].
    [trace_id] is sanitized as a path segment. *)
val path_for_trace : Workspace.config -> keeper_name:string -> trace_id:string -> string

val append_to_path : string -> t -> (unit, string) result
val append : Workspace.config -> t -> (unit, string) result
val append_best_effort : ?site:string -> Workspace.config -> t -> unit

val append_unfinished_provider_attempt_finished_best_effort :
  ?site:string ->
  Workspace.config ->
  turn_context ->
  status:string ->
  error:string ->
  ?exception_kind:string ->
  unit ->
  unit

(** Extract the source_clock from a manifest's decision JSON. *)
val source_clock_from_manifest : t -> source_clock option

(** Extract the logical ordering fields from a manifest's clock_refs. *)
val logical_ordering : t -> logical_ordering

(** Validate that two manifests share the same source_clock so that
    their [elapsed_ms] values are comparable.  Returns [Ok source_clock]
    on match, [Error msg] on mismatch or missing clock. *)
val comparable_for_latency : t -> t -> (source_clock, string) result

(** {2 F8: Turn completeness policy} *)

(** The clock_refs keys that are mandatory for a structurally complete
    manifest at this event lane. *)
val mandatory_clock_refs_for_event : event_kind -> string list

(** Check whether a manifest carries all mandatory clock_refs for its event. *)
val validate_manifest_completeness : t -> (unit, string) result

(** Whether a list of manifests includes a [Turn_finished] event. *)
val is_finished_turn : t list -> bool

(** Whether a turn is both [finished] and has all mandatory lane artifacts:
    receipt link + checkpoint link. *)
val is_complete_turn : t list -> bool
