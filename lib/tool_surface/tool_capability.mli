(** RFC-0084 §3.2 — Typed tool capability.

    The closed-sum [kind] and [Set]-based granted/required model reads
    capability truth from [Tool_catalog.metadata]. [Tool_dispatch]'s
    mutable capability sets have been removed; dispatch owns routing,
    not capability authority.

    The module is named [Tool_capability] to make its narrow tool-registration
    scope explicit. *)

type kind =
  | Read_only
  | Mcp_context_required
  | Idempotent

val to_string : kind -> string
val of_string : string -> kind option
val all_kinds : kind list

(** Ordered Set of capability kinds. *)
module Set : Stdlib.Set.S with type elt = kind

(** [has kind tool_name] returns [true] when [Tool_catalog.metadata]
    grants [kind] for [tool_name]. *)
val has : kind -> string -> bool

(** [granted tool_name] returns every capability kind currently granted
    to [tool_name] by catalog metadata. *)
val granted : string -> Set.t

(** [check ~required ~granted] returns [Ok ()] when [granted ⊇ required],
    [Error missing] (the difference set) otherwise. PR-7 wires this into
    [Tool_dispatch.guarded_dispatch] for keeper-originated calls. *)
val check : required:Set.t -> granted:Set.t -> (unit, Set.t) Stdlib.Result.t
