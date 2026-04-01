(** Tool_gate — algebraic tool set operations for zone boundaries.

    Phase 2A of Tool Gate architecture (#4381).
    Pure module: no side effects, no runtime state, no external deps.

    Transforms concrete tool name sets (string list), unlike
    [Tool_access_policy.selector] which operates as a membership predicate
    over a candidate universe. See #4381 for the distinction. *)

(** Operations that transform a tool name set. *)
type tool_op =
  | Keep_all                      (** Identity -- no change *)
  | Clear_all                     (** Empty the set *)
  | Add of string list            (** Set union: current U names *)
  | Remove of string list         (** Set difference: current \ names *)
  | Replace_with of string list   (** Replace entire set *)
  | Intersect_with of string list (** Set intersection: current ∩ names *)
  | Seq of tool_op list           (** Sequential composition (fold_left) *)

(** Result of computing an algebraic inverse. *)
type inverse_result =
  | Reversible of tool_op
  | Irreversible                  (** Original destroyed information *)

(** {1 Core Operations} *)

val apply : tool_op -> string list -> string list
(** Apply op to a tool set. Result is deduplicated, order-preserving. *)

val inverse : tool_op -> inverse_result
(** Compute algebraic inverse. Structural -- does NOT need the current set.

    {b Precondition for roundtrip correctness}: the op must have been
    effectively applied (not a no-op on the set). Specifically,
    [Remove names] roundtrip only holds if all [names] were in the set.
    If [Remove ["b"]] is applied to [["a"]] (no-op), the inverse
    [Add ["b"]] will ADD "b" -- a phantom addition / privilege escalation.
    Phase 2B's zone_tbl uses snapshot-based restore as SSOT;
    inverse is an optimization hint only.

    Inverse mapping:
    - [Keep_all] -> [Reversible Keep_all]
    - [Clear_all] -> [Irreversible]
    - [Add names] -> [Reversible (Remove names)]
    - [Remove names] -> [Reversible (Add names)]
    - [Replace_with _] -> [Irreversible]
    - [Intersect_with _] -> [Irreversible]
    - [Seq ops] -> [Reversible (Seq (rev-map inverse))] if ALL reversible *)

(** {1 Composition} *)

val compose : tool_op list -> tool_op
(** Smart [Seq] constructor.
    - [[]] -> [Keep_all]
    - [[x]] -> [x]
    - Nested [Seq] recursively flattened (arbitrary depth).
    - Identity ops ([Keep_all], [Add []], [Remove []]) eliminated. *)

(** {1 Predicates} *)

val is_identity : tool_op -> bool
(** [Keep_all], [Add []], [Remove []], [Seq] of all identities (recursive). *)

val is_irreversible : tool_op -> bool
(** [Clear_all], [Replace_with], [Intersect_with],
    or [Seq] containing any irreversible op. *)

(** {1 Serialization} *)

val to_yojson : tool_op -> Yojson.Safe.t
val inverse_result_to_yojson : inverse_result -> Yojson.Safe.t

(** {1 Comparison} *)

val equal : tool_op -> tool_op -> bool
(** Structural equality with name normalization (trim + sort + dedup).
    Compares normalized structure, NOT apply semantics.
    [Add ["a";"b"]] and [Add ["b";"a"]] are equal;
    [Add ["a"]] and [Seq [Add ["a"]]] are NOT. *)
