(** Workspace_holder — long-lived [Workspace.t] reference shared
    across keeper turn life-cycles and the dashboard HTTP surface.

    Cycle 27 / Tier K1.

    {1 What this module is}

    A process-wide store for the live [Workspace.t]. The keeper
    post-turn wire-in updates it via {!update}; the dashboard
    HTTP route (D1) reads it via {!get} through a callback bound
    in {!Server_routes_http_routes_multimodal.bind_workspace_getter}.

    {1 Why a separate module}

    Three callers need one consistent [Workspace.t] view:
    - {!Wirein_helpers.apply_multimodal_wirein} (keeper turn tail)
    - {!Server_routes_http_routes_multimodal.list_response} (HTTP read)
    - integration tests that exercise both halves

    Threading the workspace through every callsite is intrusive
    and breaks RFC-0002 (the keeper FSM cannot grow new fields).
    A module-level atomic immutable snapshot is the smallest seam
    that satisfies all three.

    {1 Concurrency}

    The [Atomic.t] works from any context — pre-Eio init, an Eio
    fiber, a unit-test main thread, or another domain. Reads
    ({!get}) return one immutable snapshot; updates ({!update})
    publish the result of a pure function through a compare-and-set
    retry loop. *)

val get : unit -> Workspace.t
(** Snapshot the current workspace value. *)

val update : (Workspace.t -> Workspace.t * 'a) -> 'a
(** [update transition] atomically publishes the first component returned by
    [transition current] and returns the second. [transition] must be pure:
    concurrent publication may evaluate it again against a newer snapshot.
    Exceptions propagate and leave the workspace unchanged. *)

module For_testing : sig
  val replace : Workspace.t -> unit
  val reset : unit -> unit
end
(** Explicit test-only whole-snapshot controls. Production callers update the
    workspace only through {!update}. *)
