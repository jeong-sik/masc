(** Channel 1 Human Action Queue.

    Aggregates items requiring an operator decision right now
    ({!Health.attention_kind}): held tool approvals, pending keeper asks, and
    verified goals awaiting completion confirmation. Sorted strictly by operational urgency, powering both the
    persistent fast-path Approval Strip ([Y]/[N]) and rapid 1-key Ask triage. *)

open Masc_tui_core
open Masc_tui_protocol

type payload =
  | Payload_tool_approval of Wire_work.held_tool_approval
  | Payload_gate of Wire_work.gate_pending
  | Payload_ask of Wire_work.ask_row
  | Payload_goal_confirmation of Wire_work.goal

type entry = {
  id : string;
  kind : Health.attention_kind;
  payload : payload;
  title : string;
  summary : string;
  keeper : string option;
  created_at_unix : float option;
}

type t = {
  items : entry list;
  selected_id : string option;
      (** Selected entry, even while filtered out or absent from the queue.
          [None] before a selection allows the default to follow urgency. *)
  triage_index : int;
  triage_scroll_offset : int;
  auto_advance : bool;
  in_flight_ids : string list;
}

val empty : t

val urgency_rank : Health.attention_kind -> int
(** Higher values indicate higher operator urgency:
    [Held_tool_approval] > [Pending_ask] > [Goal_confirmation]. *)

val rebuild :
  asks:Wire_work.ask_row list ->
  tool_approvals:Wire_work.held_tool_approval list ->
  gate_pending:Wire_work.gate_pending list ->
  goals:Wire_work.goal list ->
  t ->
  t
(** Rebuild the sorted queue from authoritative server slices while preserving
    [selected_id] / [triage_index], [auto_advance], and [in_flight_ids] for
    still-present items. *)

val upsert_entry : entry -> t -> t
val remove_by_id : string -> t -> t

val top_fast_path : ?query:string -> t -> entry option
(** Highest-urgency item (within [filtered_items ~query t]) not currently in
    flight, surfaced on the persistent Approval Strip. *)

val current_triage_item : t -> entry option
(** Currently focused item for rapid 1-key Inbox / Ask triage. *)

val filtered_items : query:string -> t -> entry list
(** Filter queue entries case-insensitively by title, summary, keeper, or id. *)

val selected_index_in_filtered : query:string -> t -> int option
(** Zero-based position of the selected entry in {!filtered_items}. A hidden
    or missing selected identity has no highlighted or actionable row. *)

val current_filtered_item : query:string -> t -> entry option
(** Currently focused item within {!filtered_items}. *)

val sync_selection : query:string -> t -> t
(** Recompute the position for the current filter, preserving a hidden or
    missing identity. The highest-priority visible row remains the default until
    an item is selected. *)

val move_triage : ?query:string -> ?viewport_rows:int -> delta:int -> t -> t
val select_triage_index : ?query:string -> int -> t -> t
val set_auto_advance : bool -> t -> t

val is_in_flight : id:string -> t -> bool
val mark_in_flight : id:string -> t -> t
val clear_in_flight : id:string -> t -> t
val clear_all_in_flight : t -> t
(** Drop all in-flight markers when leaving an epoch whose replies are
    abandoned. *)
val advance_past_in_flight : ?query:string -> t -> t
(** When [auto_advance] is enabled and the highlighted triage item (within
    [filtered_items ~query t]) is in-flight, move [selected_id] and
    [triage_index] to the next non-in-flight filtered item so selection and
    strip advance together without ever silently jumping to an unrelated row. *)

val advance_after_resolution : ?query:string -> resolved_id:string -> t -> t
(** Advance from the highlighted item when it was resolved and [auto_advance]
    is enabled. If the resolved item is still selected, restore the default
    priority selection. Remove [resolved_id] and its in-flight flag. *)

val count : t -> int
val is_empty : t -> bool
val has_actionable_fast_path : t -> bool
