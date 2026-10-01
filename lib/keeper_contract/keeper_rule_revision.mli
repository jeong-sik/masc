(** Durable compare-and-set authority for an exact approval rule.
    Callers must allocate globally unique, never-reused revision and operation
    tokens once per mutation, before durably journaling its intent. Retries and
    restart recovery replay that exact stored intent rather than preparing a
    new one. Historical token uniqueness is a caller obligation: this pure
    module sees only the supplied current state and cannot detect historical
    reuse. Callers persist the resulting state atomically and retain deletion
    tombstones so an old revision cannot become current again.
    This module performs no IO and does not order decisions by time. *)

type presence = Active | Deleted

type state = private
  { revision : string
  ; rule : Keeper_approval_queue_rules_types.approval_rule
  ; presence : presence
  ; operation_id : string
  }

type intent = private
  { expected_revision : string option
  ; next : state
  }

type outcome =
  | Apply of state
  | Already_applied of state
  | Conflict of state option

val rule : state -> Keeper_approval_queue_rules_types.approval_rule option
val revision : state option -> string option
val identity_equal :
  Keeper_approval_queue_rules_types.approval_rule ->
  Keeper_approval_queue_rules_types.approval_rule -> bool

val prepare :
  current:state option -> revision:string -> operation_id:string ->
  presence:presence -> Keeper_approval_queue_rules_types.approval_rule ->
  (intent, string) result
(** Rejects mismatched identities, empty tokens, a revision equal to the current
    revision, or an operation ID equal to the current operation ID. It does not
    check tokens against historical states; callers must enforce the uniqueness
    contract above.
    Deletion requires the exact current active rule, retaining its identity
    as a tombstone. An intent is a durable command, not a successful write. *)

val decide : current:state option -> intent -> outcome
(** [Apply] is a proposed write. Only a successful authoritative save makes
    it committed. A stale replay conflicts after renewal or deletion. *)

val state_to_yojson : state -> Yojson.Safe.t
val state_of_yojson : Yojson.Safe.t -> (state, string) result
val intent_to_yojson : intent -> Yojson.Safe.t
val intent_of_yojson : Yojson.Safe.t -> (intent, string) result
