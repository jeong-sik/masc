(** Which node tools a composition runs, for the callers that must judge a
    composition without executing it.

    A composition tool ([keeper_compose_<name>]) is materialised outside the
    keeper descriptor registry, so {!Keeper_tool_descriptor} has no record of
    it and anything that looks a tool up by descriptor sees nothing. The
    approval policy is one such caller: a name it cannot resolve is a name it
    cannot classify, so it asks. Every composition therefore asked, including
    one whose whole plan is reads.

    This index carries the one fact that answers the question — the tools the
    plan runs — and leaves the judging to whoever holds the policy. It stores
    names, not verdicts, so it does not depend on the policy and the policy
    does not depend on it in the other direction.

    The bundle builder knows each plan at construction time ([Catalog.entry]
    carries it), so the write happens once per turn rather than once per call.
    The index is owned by that turn's approval gate. It must not be shared:
    concurrent turns can materialize the same composition name from different
    workspace snapshots, and a process-global last writer would then decide
    the first turn using the second turn's plan. *)

type t

val create : unit -> t

val record : t -> composition:string -> node_tools:string list -> unit
(** Declare that [composition] runs exactly [node_tools], in plan order.

    Overwrites any previous row for the same name. An empty [node_tools] is
    recorded as such: a plan with no nodes is a real shape the catalog can
    hold, and it is not the same fact as "this name is not a composition". *)

val node_tools : t -> composition:string -> string list option
(** The tools [composition] runs, or [None] when this name was never
    recorded — which for a caller means "not a composition I know", not "a
    composition that runs nothing". *)
