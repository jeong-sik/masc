(** Atomic persistence for Keeper shutdown operations under the configured
    MASC base path. Reads and writes are serialized per operation path, while
    a per-Keeper inventory lock keeps directory scans from observing atomic
    writer temporaries. Unrelated Keepers never share either lock across
    filesystem I/O. *)

type error =
  | Already_exists of string
  | Not_found of string
  | Io_error of string
  | Decode_error of string
  | Invalid_operation of Keeper_shutdown_types.invariant_error
  | Identity_mismatch of string
  | Revision_conflict of
      { expected : int
      ; actual : int
      }
  | Supersession_phase_mismatch of Keeper_shutdown_types.t
  | Supersession_intent_mismatch of Keeper_shutdown_types.t
  | Invalid_supersession_actor of string
  | Invalid_supersession_reason of string

type persist_blocked_result =
  | State_preserved of Keeper_shutdown_types.t
  | Blocked_persisted of Keeper_shutdown_types.t

type supersede_blocked_result =
  | Superseded_persisted of Keeper_shutdown_types.t
  | Superseded_already_persisted of Keeper_shutdown_types.t

type reissue_blocked_purge_result =
  | Purge_reissue_persisted of Keeper_shutdown_types.t
  | Purge_reissue_already_persisted of Keeper_shutdown_types.t

type operator_metadata_supersession_token

type corrupt_record =
  { keeper_name : string
  ; operation_id : Keeper_shutdown_types.Operation_id.t
  ; path : string
  ; error : error
  }

type inventory_entry =
  | Operation of Keeper_shutdown_types.t
  | Corrupt_record of corrupt_record

(** Select one stable owner-addressable identity per Keeper with corrupt
    durable state. *)
val canonical_corrupt_operation_ids :
  inventory_entry list ->
  (string * Keeper_shutdown_types.Operation_id.t) list

val error_to_string : error -> string

val path :
  config:Workspace.config ->
  keeper_name:string ->
  Keeper_shutdown_types.Operation_id.t ->
  (string, error) result

val to_json : Keeper_shutdown_types.t -> Yojson.Safe.t
(** Decode the current schema. Any other version is an explicit decode failure. *)
val of_json : Yojson.Safe.t -> (Keeper_shutdown_types.t, error) result

val persist_new :
  config:Workspace.config ->
  Keeper_shutdown_types.t ->
  (unit, error) result

val replace :
  config:Workspace.config ->
  expected_revision:int ->
  Keeper_shutdown_types.t ->
  (unit, error) result

(** Bind the exact admission-owned operation identity and durable revision
    eligible for an explicit operator metadata update. Only [Blocked] with
    [Operator_stop_retain_meta], or an idempotent prior metadata supersession,
    can produce a token. *)
val prepare_operator_metadata_supersession :
  config:Workspace.config ->
  keeper_name:string ->
  operation_id:Keeper_shutdown_types.Operation_id.t ->
  actor:string ->
  (operator_metadata_supersession_token, error) result

val supersession_token_operation_id :
  operator_metadata_supersession_token ->
  Keeper_shutdown_types.Operation_id.t

(** After the operator metadata write has durably committed, CAS the token's
    exact [Blocked] revision to [Superseded]. Concurrent progress fails with a
    typed revision conflict. A prior metadata supersession is idempotent. *)
val supersede_blocked_operator_stop :
  config:Workspace.config ->
  token:operator_metadata_supersession_token ->
  now:(unit -> string) ->
  (supersede_blocked_result, error) result

(** CAS one exact [Blocked] dashboard purge back into [Joined_idle] while the
    same operation continues to own admission. The typed operator intent is
    persisted in [join_evidence] and remains through finalization. An exact
    retry observes the same intent and reconciles from the current phase. *)
val reissue_blocked_dashboard_purge :
  config:Workspace.config ->
  keeper_name:string ->
  operation_id:Keeper_shutdown_types.Operation_id.t ->
  expected_revision:int ->
  actor:string ->
  reason:string ->
  now:(unit -> string) ->
  (reissue_blocked_purge_result, error) result

(** Read the latest durable revision and persist [Blocked failure] while
    holding the operation's write lock. Existing [Finalized], [Blocked], and
    effect-unknown reconciliation states are preserved. [now] is sampled only
    after the lock is acquired and the latest revision is loaded. *)
val persist_blocked_latest :
  config:Workspace.config ->
  identity:Keeper_shutdown_types.t ->
  failure:Keeper_shutdown_types.failure ->
  now:(unit -> string) ->
  (persist_blocked_result, error) result

val load :
  config:Workspace.config ->
  keeper_name:string ->
  Keeper_shutdown_types.Operation_id.t ->
  (Keeper_shutdown_types.t, error) result

val list_for_keeper :
  config:Workspace.config ->
  keeper_name:string ->
  (Keeper_shutdown_types.t list, error) result

(** Return the deterministic owner-addressable identity for any corrupt
    record belonging to [keeper_name]. The lexicographically smallest typed
    operation id is selected so every recovery path restores the same fence. *)
val corrupt_operation_id_for_keeper :
  config:Workspace.config ->
  keeper_name:string ->
  (Keeper_shutdown_types.Operation_id.t option, error) result

(** Enumerate every owner-addressable operation independently. A corrupt
    payload remains associated with the Keeper and operation identities from
    its validated directory/file path, so boot can fence only that Keeper and
    continue recovering unrelated lanes. Store entries whose path does not
    encode both identities still fail the outer result because they cannot be
    isolated safely. *)
val scan_inventory :
  config:Workspace.config ->
  (inventory_entry list, error) result

module For_testing : sig
  val with_operation_write_lock :
    config:Workspace.config ->
    keeper_name:string ->
    Keeper_shutdown_types.Operation_id.t ->
    (unit -> 'a) ->
    ('a, error) result
end
