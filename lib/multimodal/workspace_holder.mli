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
    A module-level ref guarded by a mutex is the smallest seam
    that satisfies all three.

    {1 Concurrency}

    The ref is protected by an internal {!Stdlib.Mutex} (not
    {!Eio.Mutex}) so that updates from any context — pre-Eio
    init, an Eio fiber, a unit-test main thread — work uniformly.
    Reads ({!get}) snapshot the workspace under the lock and
    return the immutable value; updates ({!update}) compose a
    function under the lock. There is no recursion or blocking
    I/O inside the critical section, so the mutex never becomes
    a contention hotspot. *)

val get : unit -> Workspace.t
(** Snapshot the current workspace value. *)

val update : (Workspace.t -> Workspace.t) -> unit
(** [update f] atomically replaces the held workspace with
    [f current]. The function should be pure — exceptions thrown
    inside [f] propagate and the workspace is left unchanged. *)

val replace : Workspace.t -> unit
(** Replace the held workspace value entirely. Primarily for
    test setup; production code should prefer {!update}. *)

val reset : unit -> unit
(** Reset to {!Workspace.empty}. Test helper; equivalent to
    [replace Workspace.empty]. *)
