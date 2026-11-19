(** Pure current-schema wire codec for approval snapshots, append-log rows
    and the derived replay projection. It owns format revisions and validates
    decoded data before the effect owner can apply it. No filesystem, lock,
    mutable queue or dispatch state lives here. *)

open Keeper_approval_queue_rules_types
open Keeper_approval_queue_result

(* Whether the decision's [Resolved] row is known to be on the audit ledger
   (#38541). The delivery is journaled as [Ledger_append_pending] in the same
   write that removes the pending entry, so it is durable before the append
   is tried; it becomes [Ledger_recorded] only after an append or a retry's
   read confirms the row. Until then the delivery is the decision's only
   durable copy and is never removed. *)
type resolution_ledger =
  | Ledger_append_pending
  | Ledger_recorded

type persisted_delivery =
  { entry : pending_approval
  ; resolution_sequence : int
  ; decision : decision
  ; source : decision_source
  ; remember_rule : bool
  ; rule_expires_at : float option
  ; created_by : string option
  ; grant_consumed : bool
  ; replay_outcome : resolution_replay_outcome option
  ; resolved_at : float
      (* The [Resolved] row's own timestamp; it also names the day file that
         row is filed under, so a retry reads that one file. *)
  ; ledger : resolution_ledger
  }

type log_row =
  | Pending_upsert of pending_approval
  | Pending_remove of string
  | Delivery_upsert of persisted_delivery
  | Delivery_remove of string

type decoded_log_row =
  { row : log_row
  ; row_generation : int
  ; row_next_sequence : int
  }

val pending_entry_to_yojson :
  ?include_request_context:bool -> pending_approval -> Yojson.Safe.t
val persisted_delivery_to_yojson : persisted_delivery -> Yojson.Safe.t
val resolution_replay_outcome_to_yojson : resolution_replay_outcome -> Yojson.Safe.t
val map_values_for_base :
  base_path:string -> 'a Set_util.StringMap.t -> ('a -> pending_approval) -> 'a list
val first_shared_id :
  'a Set_util.StringMap.t -> 'b Set_util.StringMap.t -> string option
(** The first shared key in map order, or [None] when the states are disjoint. *)

val validate_snapshot_sequences :
  next_sequence:int -> pending_approval list -> persisted_delivery list -> (unit, string) result
(** Validate request and resolution identities after snapshot or append-log replay. *)

val snapshot_to_yojson :
  base_path:string -> next_sequence:int -> generation:int ->
  pending_map:pending_approval Set_util.StringMap.t ->
  delivery_map:persisted_delivery Set_util.StringMap.t -> Yojson.Safe.t
val replay_results_to_yojson :
  base_path:string -> delivery_map:persisted_delivery Set_util.StringMap.t -> Yojson.Safe.t
val log_row_to_yojson : generation:int -> next_sequence:int -> log_row -> Yojson.Safe.t

val pending_entry_of_yojson : base_path:string -> Yojson.Safe.t -> (pending_approval, string) result
val snapshot_of_yojson :
  base_path:string -> Yojson.Safe.t ->
  (pending_approval Set_util.StringMap.t * persisted_delivery Set_util.StringMap.t
   * int * int * string list, string) result
(** Maps, next sequence, generation, and rejected pending-entry evidence.
    Fatal invariants reject the whole snapshot; recoverable drops retain errors. *)
val validate_pending_snapshot : base_path:string -> Yojson.Safe.t -> (unit, string) result
(** Run the snapshot decode {!Keeper_approval_queue.install_persistence} runs on
    [gate/pending.json], without installing anything. [Error] carries the
    loader's own message: an unsupported [version] (which names the runtime
    reset), a malformed snapshot, or the first entry the loader would drop.
    The append log is not read. *)
val replay_results_of_yojson :
  Yojson.Safe.t -> (resolution_replay_outcome Set_util.StringMap.t, string) result
(** Private retained roots are strict normalized references with empty previews.
    An omitted list denotes an existing replay row that owned only its model
    projection. Malformed present lists fail the whole sidecar decode. *)
val log_row_of_yojson : base_path:string -> Yojson.Safe.t -> (decoded_log_row, string) result
val apply_log_row :
  pending_approval Set_util.StringMap.t * persisted_delivery Set_util.StringMap.t ->
  log_row -> pending_approval Set_util.StringMap.t * persisted_delivery Set_util.StringMap.t

val replay_log_lines :
  base_path:string -> snapshot_generation:int ->
  pending_map:pending_approval Set_util.StringMap.t ->
  delivery_map:persisted_delivery Set_util.StringMap.t -> next_sequence:int ->
  string list ->
  (pending_approval Set_util.StringMap.t * persisted_delivery Set_util.StringMap.t
   * int * int, string) result
(** Replay complete append-log lines with production generation and final
    sequence validation. Returns pending entries, deliveries, next sequence
    and applied-row count. Filesystem reads and incomplete-tail recovery
    belong to the caller; this function never repairs evidence. *)

val exact_attempt_quarantine_summary_status : exact_attempt_quarantine_cause -> summary_status
val validate_entry_exact_attempt :
  id:string -> input_hash:string -> sequence:int -> summary_status:summary_status ->
  summary_attempt_disposition:summary_attempt_disposition -> exact_attempt_state ->
  (unit, string) result
