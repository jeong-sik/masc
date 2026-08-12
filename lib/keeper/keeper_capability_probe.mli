(** Capability probing that does not write into the keeper's conversation
    (RFC-0374).

    Asking "can keeper K reach tool T" used to cost a real turn, and a real
    turn is durable in the chat transcript, the checkpoint, and — through the
    librarian — the keeper's memory. Measurement therefore changed the thing
    it measured: on 2026-08-12 the librarian read accumulated probe traffic
    and committed a fact prescribing non-response to the probed tools, after
    which a zero result no longer distinguished "the runtime cannot reach the
    tool" from "the keeper declined" (masc#28414).

    This module answers the part of that question that needs no model at all.
    Whether MASC projects a tool into the surface it hands a client is decided
    by the descriptor table, so it is decidable offline, for free, and without
    touching any durable store.

    {1 What a positive answer does not mean}

    Projection is MASC's side of the wire; consumption is the client's. The
    two diverge — the antigravity bridge advertised 97 tools including every
    probed one, [initialize] and [tools/list] both answered, and the models
    still reported no masc tool present. So [Projected] means a turn is worth
    spending, and nothing more. Only observing an actual call establishes
    reachability, which is [probe_invocation]'s job (not yet implemented).

    @since 0.21.3 *)

(** Why a tool is or is not in the keeper-facing surface.

    The three negative cases are kept apart because they have different
    fixes: a name that does not exist is a caller error, an operator tool is
    working as designed, and an alias means the capability is present under
    a different name. Collapsing them into [false] is what made
    [masc_tasks] and [masc_status] look like the same failure during the
    2026-08-12 audit when they are not. *)
type verdict =
  | Projected of { model_facing_name : string }
      (** Reaches the model under this name. *)
  | Not_a_descriptor
      (** No descriptor declares this name, under any projection. *)
  | Operator_only
      (** Declared, but deliberately withheld from the autonomous model. *)
  | Aliased of { projected_by : string }
      (** Declared, but the capability reaches the model under another
          descriptor's name. Probing the requested name measures the alias
          policy rather than the runtime. *)
  | Withheld_by_schema_error of { errors : string list }
      (** Declared model-facing, but the surface drops it because its schema
          does not validate. Distinct from [Operator_only]: nobody chose this,
          and it is a defect in the descriptor rather than a policy. *)

val verdict_to_string : verdict -> string

(** Resolve [tool] against the keeper-facing tool surface.

    Pure: reads the descriptor table and nothing else. No provider call, no
    session, no filesystem write. Accepts either a public or an internal
    descriptor name, because both appear in operator-authored probe lists. *)
val probe_surface : tool:string -> verdict

(** Every name that reaches the keeper model, in descriptor order.

    Used to report what {e was} available when a probe asks for a name that is
    not, so the caller does not have to guess at a typo. *)
val model_facing_names : unit -> string list
