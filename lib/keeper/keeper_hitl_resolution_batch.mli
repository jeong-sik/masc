(** Ordered HITL intake compatibility, not authorization. The durable Gate
    journal still owns every exact one-shot grant. A singleton preserves the
    existing rejection, recovery and model-issued paths. Multiple members
    must be fresh approved nonterminal host replays with one reply partition.
    An unrouted partition has no reply destination; it invents none. *)

type t

type singleton_reason =
  | Rejected_resolution
  | Model_issued_operation of string
  | Terminal_operation of string
  | Recovery_resolution
  | Different_keeper of string
  | Grant_unavailable of Keeper_approval_queue_result.grant_error

type join_error =
  | Duplicate_resolution of string
  | Different_reply_partitions
  | Different_scope
  | Invalid_workspace of Config_dir_resolver.canonical_base_path_error
  | Single_only of { approval_id : string; reason : singleton_reason }

val join_error_to_string : join_error -> string

val empty : t
val singleton : Keeper_event_queue.hitl_resolution -> t
val resolutions : t -> Keeper_event_queue.hitl_resolution list
val singleton_resolution : t -> Keeper_event_queue.hitl_resolution option
(** Returns no representative for a multiple-resolution batch. In particular,
    it must never supply the first approval's grant to the provider. *)

val validate_scope :
  base_path:string -> keeper_name:string -> t -> (unit, join_error) result
(** Before any cohort effect, compare the executor to the frozen workspace
    and Keeper. Workspace aliases use the resolver's canonical identity.
    Empty and singleton inputs keep their existing Gate validation path. *)

val try_append :
  base_path:string -> keeper_name:string ->
  t -> Keeper_event_queue.hitl_resolution -> (t, join_error) result
(** Admission is ordered and uncapped here; the caller's configured source
    bound remains authoritative. A failed join retains the original batch.
    Fresh means unconsumed with no replay outcome in the actual Gate store.
    Existing cohort members are frozen before effects begin: runtime fallback
    recovers that same vector rather than selecting new members. *)

val of_resolutions :
  base_path:string -> keeper_name:string ->
  Keeper_event_queue.hitl_resolution list -> (t, join_error) result
(** Reconstruct compatibility from the exact admitted source vector before
    any effect. This reads each multiple member's authoritative request; an
    empty or singleton vector retains its ordinary path. *)
