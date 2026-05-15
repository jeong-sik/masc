(** RFC-0084 §3.2 — Typed tool dispatch capability.

    Replaces the five string-keyed [(string, unit) Hashtbl.t] capability
    sets at [Tool_dispatch.{read_only_set, requires_join_set,
    mcp_context_required_set, destructive_set, idempotent_set}]
    with a closed-sum [kind] and a [Set]-based granted/required model.

    PR-4 is *additive* — the legacy sets remain authoritative and this
    module bridges through [Tool_dispatch.is_*] queries. PR-7 wires
    [check] into [Tool_dispatch.guarded_dispatch] to enforce gating on
    keeper-originated calls. PR-11 removes the legacy sets.

    The module is named [Tool_capability] (not [Capability]) because
    [lib/exec/capability.ml] already owns the [Capability] name for the
    shell-command capability domain (Read_path / Write_path / Exec_bin /
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

(** [has kind tool_name] returns [true] when [tool_name] is registered
    in the legacy [Tool_dispatch] set corresponding to [kind].

    Bridges through [Tool_dispatch.is_read_only] / [is_join_required] /
    [is_mcp_context_required] / [is_destructive] / [is_idempotent]. *)
val has : kind -> string -> bool

(** [granted tool_name] returns every capability kind currently granted
    to [tool_name] by the legacy sets. *)
val granted : string -> Set.t

(** [check ~required ~granted] returns [Ok ()] when [granted ⊇ required],
    [Error missing] (the difference set) otherwise. PR-7 wires this into
    [Tool_dispatch.guarded_dispatch] for keeper-originated calls. *)
val check : required:Set.t -> granted:Set.t -> (unit, Set.t) Stdlib.Result.t
