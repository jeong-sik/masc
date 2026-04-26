(** Dashboard Attention — Collect actionable items that require
    operator intervention.

    Pure functions. Scans {!Dashboard_labels.room_snapshot} values
    to produce a sorted list of items the operator should act on.
    Each item includes a suggested MCP tool name. *)

(** {1 Types} *)

type severity =
  | Critical
  | Warning
  | Info

type attention_item =
  { severity : severity
  ; category : string
  ; summary : string
  ; suggested_tool : string
  }

(** {1 Severity helpers} *)

val severity_to_string : severity -> string
val severity_icon : severity -> string

(** Coerce to canonical {!Severity.t} for cross-module communication. *)
val to_severity : severity -> Severity.t

(** {1 Collection} *)

(** [collect ~now snapshots] scans for stuck agents and idle-with-
    pending-work situations, returning the items sorted by severity
    (Critical first). *)
val collect : now:float -> Dashboard_labels.room_snapshot list -> attention_item list

(** {1 Presentation} *)

(** One rendered line per item, prefixed with {!severity_icon}. *)
val format_items : attention_item list -> string list

(** Compact single-line summary, e.g. ["[!] 2 critical, [~] 1 warning"].
    Empty items list returns the empty string. *)
val compact_summary : attention_item list -> string
