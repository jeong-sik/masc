(** Durable per-turn decision manifest for keeper runtime diagnosis.

    The manifest is intentionally narrower than execution receipts.  Receipts
    describe what happened after a turn; manifest rows record the routing and
    context decisions that explain why the turn took that path.

    {2 Layered SSOT}

    The manifest is structured in five layers.  Each layer has a single
    authoritative source of truth and a clear boundary:

    - {b Layer 1 — Identity}: [keeper_name], [agent_name], [trace_id],
      [generation].  Stable across every event in a turn.  SSOT is the
      keeper registry entry at turn start.

    - {b Layer 2 — Time}: [ts], [source_clock], [clock_refs].  Provides
      wall / monotonic / logical / provider / event_bus provenance.
      SSOT is the runtime clock snapshot taken when the event is emitted.

    - {b Layer 3 — Lineage}: [event_kind], [tool_lineage] (6 stages:
      searched / visible / materialized / emitted / executed / verified).
      Tracks the tool lifecycle.  SSOT is the tool dispatch pipeline.

    - {b Layer 4 — Payload}: [payload_role] ([Model_input],
      [Operator_evidence], [Checkpoint], [Memory_store]).  Classifies the
      semantic role of the decision data.  SSOT is the caller contract
      at the injection point.

    - {b Layer 5 — Trust}: public projection allowlist.  Redacts sensitive
      fields based on consumer identity.  SSOT is the consumer capability
      profile. *)

type event_kind =
  | Turn_started
  | Phase_gate_decided
  | Cascade_routed
  | Pre_dispatch_blocked
  | Tool_surface_selected
  | Provider_lane_resolved
  | Tool_lineage_recorded
  | Provider_attempt_started
  | Provider_attempt_finished
  | Context_injected
  | Context_compacted
  | State_snapshot_sidecar_saved
  | Working_state_sidecar_saved
  | Event_bus_correlated
  | Memory_injected
  | Memory_flushed
  | Checkpoint_loaded
  | Checkpoint_saved
  | Receipt_appended
  | Turn_finished

type links = {
  receipt_path : string option;
  checkpoint_path : string option;
  tool_call_log_path : string option;
}

type t = {
  schema_version : int;
  ts : string;
  keeper_name : string;
  agent_name : string option;
  trace_id : string;
  generation : int option;
  keeper_turn_id : int option;
  oas_turn_count : int option;
  logical_seq : int option;
  event : event_kind;
  cascade_name : string option;
  status : string;
  decision : Yojson.Safe.t;
  links : links;
}

type turn_context = {
  manifest_keeper_name : string;
  manifest_agent_name : string option;
  manifest_trace_id : string;
  manifest_generation : int option;
  manifest_keeper_turn_id : int option;
}

type payload_role =
  | Model_input
  | Operator_evidence
  | Checkpoint
  | Memory_store

val payload_role_to_string : payload_role -> string
val payload_role_of_string : string -> payload_role option

type source_clock =
  | Wall
  | Monotonic
  | Logical
  | Provider
  | Event_bus

val source_clock_to_string : source_clock -> string
val source_clock_of_string : string -> source_clock option
val source_clock_of_event : event_kind -> source_clock

val schema_version : int
val all_event_kinds : event_kind list
val event_kind_to_string : event_kind -> string
val event_kind_of_string : string -> event_kind option
val safe_segment : string -> string

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
  ?memory_injection_id:string ->
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

val tool_lineage :
  ?searched_tool_names:string list ->
  ?visible_tool_names:string list ->
  ?materialized_tool_names:string list ->
  ?emitted_tool_names:string list ->
  ?executed_tool_names:string list ->
  ?verified_tool_names:string list ->
  unit ->
  Yojson.Safe.t

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
  ?cascade_name:string ->
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
  ?cascade_name:string ->
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
val of_json : Yojson.Safe.t -> (t, string) result

val execution_receipt_path_for_today :
  Coord.config -> keeper_name:string -> string

(** [.masc/keepers/<keeper>/runtime-manifests]. *)
val base_dir : Coord.config -> keeper_name:string -> string

(** [.masc/keepers/<keeper>/runtime-manifests/<trace_id>.jsonl].
    [trace_id] is sanitized as a path segment. *)
val path_for_trace : Coord.config -> keeper_name:string -> trace_id:string -> string

val append_to_path : string -> t -> (unit, string) result
val append : Coord.config -> t -> (unit, string) result
val append_best_effort : ?site:string -> Coord.config -> t -> unit

val append_unfinished_provider_attempt_finished_best_effort :
  ?site:string ->
  Coord.config ->
  turn_context ->
  status:string ->
  error:string ->
  ?exception_kind:string ->
  unit ->
  unit

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
