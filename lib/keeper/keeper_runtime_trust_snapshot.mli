val snapshot_json :
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta -> Yojson.Safe.t

val summary_json :
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta -> Yojson.Safe.t

val summary_json_with_profile_snapshot :
  profile_snapshot:Keeper_types_profile.keeper_profile_snapshot ->
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta -> Yojson.Safe.t
(** Like {!summary_json}, resolving effective profile defaults from
    [profile_snapshot] instead of re-reading TOML files from disk.
    Precondition: [profile_snapshot] was read from [config.base_path]. *)

val summary_observation :
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta ->
  Dashboard_projection_read.observation
(** One actual uncached summary read. Pending approval storage unavailability
    remains typed [Partial] beside the readable trust fields; other read
    exceptions propagate. Display-only causal ages create no timer. *)

val summary_observation_with_profile_snapshot :
  profile_snapshot:Keeper_types_profile.keeper_profile_snapshot ->
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta ->
  Dashboard_projection_read.observation
(** Like {!summary_observation}, resolving effective profile defaults from
    the caller's pre-loaded [profile_snapshot] instead of re-reading TOML
    files from disk. Precondition: [profile_snapshot] was read from
    [config.base_path]. *)

val latest_decision_result :
  config:Workspace.config -> keeper_name:string ->
  (Yojson.Safe.t option, Keeper_memory_recall_exn_class.t) result
(** The newest JSON object row within the last
    [Keeper_row_facts.decision_window_lines] lines and
    [Keeper_row_facts.decision_window_bytes] bytes of the Keeper's decision
    record, read from the file. [Ok None] when the window holds no such row
    or there is no file ([ENOENT]); an [Error] when the file could not be
    read. A row passed over (not JSON, or not an object) is reported as a
    read drop. *)

val latest_decision_json :
  config:Workspace.config -> keeper_name:string -> Yojson.Safe.t option
(** The decision row the trust snapshot shows: {!latest_decision_result}
    through the row kept in memory ([Keeper_row_facts.newest_decision]). In
    the process that writes the record the file is read once and the
    record's writer moves the kept row after that; any other process reads
    the file every time. A read that fails is reported and answers [None],
    and nothing is kept. *)

(** Trust fields for a row built without reading the Keeper, such as the
    dashboard row shown when a Keeper's row could not be built. The row needs
    attention. No receipt was read, so [operator_disposition] and
    [operator_disposition_reason] are [null]. The fields are the ones every
    trust projection writes, from the same serializer. *)
val unread_keeper_json :
  disposition:Keeper_trust_disposition.t ->
  disposition_reason:Keeper_runtime_trust_snapshot_core.disposition_reason ->
  attention_reason:Keeper_runtime_trust_snapshot_core.attention_reason ->
  next_human_action:string ->
  Yojson.Safe.t

module For_testing : sig


  val snapshot_json_inner_with_pending_reader :
    read_pending:
      (base_path:string ->
      (Yojson.Safe.t list, Keeper_approval_queue_result.storage_error) result) ->
    config:Workspace.config ->
    meta:Keeper_meta_contract.keeper_meta ->
    Yojson.Safe.t
end
