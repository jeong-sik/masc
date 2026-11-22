(** Channel 1 Human Action Queue.

    Aggregates items requiring an operator decision right now
    ({!Health.attention_kind}): held tool approvals, pending keeper asks,
    verified goals awaiting completion confirmation, and quarantined board
    candidates. Sorted strictly by operational urgency, powering both the
    persistent fast-path Approval Strip ([Y]/[N]) and rapid 1-key Ask triage. *)

open Masc_tui_core
open Masc_tui_protocol

type payload =
  | Payload_tool_approval of Wire_work.held_tool_approval
  | Payload_gate of Wire_work.gate_pending
  | Payload_ask of Wire_work.ask_row
  | Payload_goal_confirmation of Wire_work.goal
  | Payload_quarantine of Wire_knowledge.quarantine_candidate

type entry = {
  id : string;
  kind : Health.attention_kind;
  payload : payload;
  title : string;
  summary : string;
  keeper : string option;
  created_at_unix : float option;
}

type bucket_counts = {
  asks : int;
  approvals : int;
  confirmations_quarantine : int;
}

type t = {
  items : entry list;
  triage_index : int;
  auto_advance : bool;
  in_flight_ids : string list;
}

val empty : t

val urgency_rank : Health.attention_kind -> int
(** Higher values indicate higher operator urgency:
    [Held_tool_approval] > [Pending_ask] > [Goal_confirmation] >
    [Board_quarantine]. *)

val rebuild :
  asks:Wire_work.ask_row list ->
  tool_approvals:Wire_work.held_tool_approval list ->
  gate_pending:Wire_work.gate_pending list ->
  goals:Wire_work.goal list ->
  quarantines:Wire_knowledge.quarantine_candidate list ->
  t ->
  t
(** Rebuild the sorted queue from authoritative server slices while preserving
    [triage_index], [auto_advance], and [in_flight_ids] for still-present items. *)

val upsert_entry : entry -> t -> t
val remove_by_id : string -> t -> t

val top_fast_path : t -> entry option
(** Highest-urgency item not currently in flight, surfaced on the persistent
    Approval Strip. *)

val current_triage_item : t -> entry option
(** Currently focused item for rapid 1-key Inbox / Ask triage. *)

val move_triage : delta:int -> t -> t
val select_triage_index : int -> t -> t
val set_auto_advance : bool -> t -> t

val is_in_flight : id:string -> t -> bool
val mark_in_flight : id:string -> t -> t
val clear_in_flight : id:string -> t -> t

val advance_after_resolution : resolved_id:string -> t -> t
(** Remove [resolved_id], clear its in-flight flag, and clamp/advance
    [triage_index] cleanly when [auto_advance] is enabled. *)

val count : t -> int
val is_empty : t -> bool
val bucket_counts : t -> bucket_counts
val has_actionable_fast_path : t -> bool
