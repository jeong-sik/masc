(** Ordered, process-local Memory decisions for a single selected read batch.
    No storage, cursor, consumption receipt or publication authority is minted. *)

type error =
  | Duplicate_current_identity of string
  | Keeper_mismatch of
      { expected : Keeper_identity.Keeper_id.t
      ; observed : Keeper_identity.Keeper_id.t
      }
  | Batch_turn_mismatch of { expected : Ids.Turn_ref.t; observed : Ids.Turn_ref.t }
  | Current_input_mismatch
  | Duplicate_step_run of string

val error_to_string : error -> string

type stage = private
  { step : Keeper_librarian_runtime.memory_step
  ; current : Keeper_librarian.current_selection
  ; invalidated : Keeper_memory_os_current.support_invalidation list
  ; claims_not_applied : Keeper_memory_os_types.fact list
  }
(** Each original source input and gated decision is retained, without merging
    or rewriting its identities/timestamps. [current] is after this step's
    premise support closure. It is not a stored Memory snapshot. *)

type t

val create
  :  keeper_id:Keeper_identity.Keeper_id.t
  -> turn_ref:Ids.Turn_ref.t
  -> snapshot:Keeper_memory_os_current.t option
  -> (t, error) result
(** [None] means no Memory snapshot was present when the batch began. Reject
    duplicate identities rather than choosing one payload for an identity. *)

val create_over
  :  keeper_id:Keeper_identity.Keeper_id.t
  -> turn_ref:Ids.Turn_ref.t
  -> current:Keeper_librarian.current_selection option
  -> (t, error) result
(** A plan that starts from the facts a batch was captured with, for a caller
    that no longer has the stored snapshot: a restarted floor chain rebuilds its
    plan from the facts its first step retained. [None] means the batch began
    with no facts. Reject duplicate identities as {!create} does. The plan has
    no stored snapshot to report: {!initial_snapshot} is [None]. *)

val initial_snapshot : t -> Keeper_memory_os_current.t option
(** The stored snapshot a plan made by {!create} started from. *)
val current : t -> Keeper_librarian.current_selection option
(** Input for the next inference. [None] means no initial snapshot and no
    accepted step; an accepted step yielding no facts is [Some {facts=[]}]. *)

val stages : t -> stage list
(** In inference order, retaining the exact selected input of every step.
    Matching the batch turn does not establish complete source-range coverage. *)

val append : t -> Keeper_librarian_runtime.memory_step -> (t, error) result
(** Accept only a gated Runtime step for this Keeper/batch and the staged
    current facts. Compare identities and full stored payloads, allowing a
    different input order for surrogate numbering while retaining that order
    in the original input. Reject duplicates first. Apply support closure now,
    before the next step, so a later premise re-addition cannot revive an
    earlier invalidated fact. The original plan remains usable on rejection.

    This ordered proof program cannot be flattened into one disposition or
    published by replacing Memory with [current]. Publication must replay the
    decisions under the store lock and validate their source/dependencies and
    terminal destinations against concurrent writes. *)
