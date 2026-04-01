(** Zone_tbl — per-keeper tool zone stack with O(1) membership check.

    Phase 2B of Tool Gate architecture (#4381).
    Pure functional module: no side effects, no mutable state.

    Manages a LIFO stack of zone frames. Each frame captures:
    - The [tool_op] that created the zone
    - A snapshot of the tool set before the op was applied
    - A pre-built O(1) lookup Hashtbl for the current tool set

    Zone enter: apply [Tool_gate.tool_op] to current set, push frame.
    Zone exit: pop frame, restore snapshot. Strict LIFO.

    Snapshot-based restore is SSOT (not inverse-based).
    See [Tool_gate.inverse] for the optimization-hint contract. *)

(** Opaque zone identifier. Returned by [enter], required by [exit].
    Prevents accidental LIFO violations at the type level. *)
type zone_id

(** The zone table state. Immutable — each operation returns a new value. *)
type t

(** {1 Creation} *)

val create : base_tools:string list -> t
(** Create from initial tool set. Normalizes names (trim, dedup).
    Returns a zone table at depth 0 (no zones entered). *)

(** {1 Zone Lifecycle} *)

val enter : op:Tool_gate.tool_op -> t -> zone_id * t
(** Push a new zone frame.
    Applies [op] to the current tool set via [Tool_gate.apply],
    builds a fresh O(1) lookup Hashtbl.
    Returns [(zone_id, new_t)]. The [zone_id] is needed for [exit]. *)

val exit : zone_id:zone_id -> t -> (t, string) result
(** Pop the top zone frame, restoring the previous tool set.
    Returns [Error] if:
    - [zone_id] does not match the top frame (LIFO violation)
    - the stack is empty (cannot exit base) *)

val exit_all : t -> t
(** Exit all zones. Returns to base tool set. Depth becomes 0. *)

(** {1 Query} *)

val current_tools : t -> string list
(** Current effective tool set (top frame, or base if no zones). *)

val base_tools : t -> string list
(** Original base tool set (before any zones). Immutable. *)

val is_tool_allowed : t -> string -> bool
(** O(1) Hashtbl membership check against current tool set. *)

val depth : t -> int
(** Number of active zone frames (0 = base, no zones entered). *)

val is_base : t -> bool
(** [depth t = 0]. No zones entered. *)

(** {1 Diagnostics} *)

val to_yojson : t -> Yojson.Safe.t
(** JSON snapshot for logging and dashboard display.
    Includes depth, base tool count, current tools, and zone stack. *)
