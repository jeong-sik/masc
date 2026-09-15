(** Dashboard Attention — Collect actionable items that require
    operator intervention.

    Pure functions. Scans {!Dashboard_labels.workspace_snapshot} values
    to produce a sorted list of items the operator should act on.
    Each item carries what ends the wait — usually an MCP tool name, and for a
    stop the operator signs, the surface that takes the signature.

    Tasks that only an operator can move arrive already projected, in
    [operator_tasks]. Deciding whether an agent can still act needs the Keeper
    registry and the meta store, which a pure module cannot read; the
    projection answers it the same way the rejection delivery does, so the
    dashboard and the delivery cannot disagree about the same agent. *)

(** {1 Types} *)

type severity = Critical | Warning | Info

type attention_item = {
  severity : severity;
  category : string;
  summary : string;
  suggested_tool : string;
}

(** {1 Severity helpers} *)

(** {1 Collection} *)

(** [collect ~now ~operator_tasks snapshots] scans for stuck agents and
    idle-with-pending-work situations, folds in the tasks only the operator can
    move, and returns the items sorted by severity (Critical first). *)
val collect :
  now:float ->
  operator_tasks:Operator_task_attention.item list ->
  Dashboard_labels.workspace_snapshot list ->
  attention_item list

val detect_operator_tasks :
  Operator_task_attention.item list -> attention_item list
(** A stop waiting for a signature and work held by nobody are the operator's
    to end and are [Critical]; a Keeper record that does not decode is a
    repair, and the task moves again once it is fixed, so it is [Warning]. *)

(** {1 Presentation} *)

(** One rendered line per item, prefixed with {!severity_icon}. *)
val format_items : attention_item list -> string list

(** Compact single-line summary, e.g. ["[!] 2 critical, [~] 1 warning"].
    Empty items list returns the empty string. *)
val compact_summary : attention_item list -> string
