(** Dashboard Attention — Collect actionable items that require
    operator intervention.

    Pure functions. Scans {!Dashboard_labels.workspace_snapshot} values
    to produce a sorted list of attention items. Each item carries a suggested
    next step, often an MCP tool name.

    Keeper route observations arrive already projected in [operator_tasks].
    The projection uses the same registry and meta store as rejection delivery;
    an unavailable route does not establish that the task's owner has stopped
    or that an operator decision is needed. *)

(** {1 Types} *)

type severity = Critical | Warning | Info

type attention_item = {
  severity : severity;
  summary : string;
  suggested_tool : string;
}

(** {1 Collection} *)

(** [collect ~now ~operator_tasks snapshots] scans for stuck agents and
    idle-with-pending-work situations, folds in the operator task list, and
    returns the items sorted by severity (Critical first). *)
val collect :
  now:float ->
  operator_tasks:Operator_task_attention.item list ->
  Dashboard_labels.workspace_snapshot list ->
  attention_item list

val detect_operator_tasks :
  Operator_task_attention.item list -> attention_item list
(** An unavailable Keeper route and an unreadable Keeper record are both
    [Warning] observations. Neither proves the task is abandoned. A
    submission awaiting a verdict is [Info]. *)

(** {1 Presentation} *)

(** One rendered line per item, prefixed with {!severity_icon}, in item order.
    The suggested action follows a run of neighbouring items that share it,
    once, with the number of items above it when the run has more than one. *)
val format_items : attention_item list -> string list

(** Compact single-line summary, e.g. ["[!] 2 critical, [~] 1 warning"].
    Empty items list returns the empty string. *)
val compact_summary : attention_item list -> string
