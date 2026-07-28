(** Keeper_librarian_recognition — the librarian's store-aware write contract.

    masc#26122: storage is recognition. The librarian reads the conversation
    window together with the keeper's current fact store (rendered with
    0-based indices by {!Keeper_memory_os_consolidation.render_numbered_facts})
    and returns typed operations. Whether something is already known is the
    model's judgment — no hash, byte comparison, or similarity threshold
    participates in the write decision. This module owns the operation domain
    and the pure application; wire parsing lives in [Keeper_librarian],
    IO/locking/CAS in [Keeper_librarian_runtime]. *)

open Keeper_memory_os_types

type valid_until_update =
  | Keep_valid_until
  (** [valid_for_days] was absent: preserve the existing expiry. *)
  | Clear_valid_until
  (** [valid_for_days: null]: make the revised claim durable. *)
  | Set_valid_for_days of int
  (** [valid_for_days: n]: derive a new expiry from [n]. *)

type operation =
  | Add of fact
    (** New knowledge, fully authored by the librarian. *)
  | Reinforce of
      { index : int
      ; source_turn : int
      }
    (** The claim at [index] was re-recognized in this window: the row keeps
        its identity; [last_verified_at] and [reinforcement_count] move. The
        re-observation provenance is ledger evidence, not row state. *)
  | Merge of Keeper_memory_os_consolidation.merge_group
    (** Two or more existing rows state the same knowledge; the librarian
        wrote the consolidated claim. Structural gates as in consolidation. *)
  | Revise of
      { index : int
      ; claim : string
      ; category : category option (** [None] keeps the row's category. *)
      ; claim_id : string option (** [None] keeps the row's claim_id. *)
      ; valid_until_update : valid_until_update
      }
    (** The claim at [index] is superseded by a corrected statement. *)
  | Forget of
      { index : int
      ; reason : string
      }
    (** The claim at [index] no longer holds; [reason] is ledger evidence. *)

(** The wire token of an operation ([wire_op_add] .. [wire_op_forget]). *)
val operation_label : operation -> string

(** Typed application outcomes. Rejections are representability/referencing
    failures or explicit recall-injection provenance; none is a heuristic
    identity judgment. *)
type disposition =
  | Applied
  | Rejected_target_overlap
  | Rejected_index_out_of_bounds
  | Rejected_target_consumed
  | Rejected_kind_mismatch
  | Rejected_valid_until_mismatch
  | Rejected_too_few_members
  | Rejected_recalled_echo

val disposition_label : disposition -> string

(** [operations_have_overlapping_targets operations] is true when two distinct
    operations address the same input-snapshot index (including a Merge member).
    This is structural wire invalidity, not a model identity judgment. *)
val operations_have_overlapping_targets : operation list -> bool

type apply_result =
  { facts : fact list
    (** The new store: surviving rows in original order (a merged row takes
        its earliest member's slot), added rows appended at the end. *)
  ; recognized_facts : fact list
    (** Rows created or rewritten by this pass (Add/Merge/Revise output), in
        operation order — the episode's [claims]. Reinforce is excluded. *)
  ; dispositions : disposition list
    (** Positionally 1:1 with the input operations. *)
  }

(** Apply recognition operations to the store snapshot the librarian saw.
    Overlapping targets fail closed as one malformed operation set, so ordering
    cannot choose a destructive result. Non-overlapping indices refer to the
    input snapshot; a later direct-call reference to a row already consumed by
    a Merge is rejected. The store can shrink: Forget removes rows and Merge
    collapses them — no monotonic-growth invariant. *)
val apply :
  ?recalled_reinforcement_indices:int list ->
  now:float ->
  operations:operation list ->
  fact list ->
  apply_result
(** [recalled_reinforcement_indices] is exact provenance from the recall
    injection boundary. A Reinforce operation against one of those snapshot
    rows is rejected rather than treated as fresh evidence. *)

(** JSON projection of one operation for the recognition evidence ledger. *)
val operation_to_json : operation -> Yojson.Safe.t
