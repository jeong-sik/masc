(** RFC-0084 §3.2 — Typed tool capability.

    The closed-sum [kind] and [Set]-based granted/required model reads
    capability truth from [Tool_catalog.metadata]. [Tool_dispatch]'s
    mutable capability sets remain only for older runtime gates that have
    not yet been cut over; they are no longer authoritative here.

    The module is named [Tool_capability] (not [Capability]) because
    [lib/exec/capability.ml] already owns the [Capability] name for the
    shell-command capability domain (Read_path / Write_path / Exec_program /
    Git / Env_set / Pipeline_fold), an orthogonal concern. *)

type kind =
  | Read_only
  | Requires_join
  | Mcp_context_required
  | Destructive
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
