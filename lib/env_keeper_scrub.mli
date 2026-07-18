(** Host-to-Keeper subprocess environment boundary.

    Only an exact, closed set of process/runtime keys is inherited from the
    host. Additional environment material comes from
    {!Keeper_secret_projection}; this module performs no product or
    credential-name inference. *)

val is_allowed : string -> bool
(** [is_allowed key] returns [true] only for an exact inherited-host key —
    plus, when the current process is a test executable ([test_] basename),
    the fake-docker shim keys the sandbox suites observe from spawned
    subprocesses. A production process never inherits those. *)

val is_allowed_for : test_executable:bool -> string -> bool
(** [is_allowed] with the test-executable gate made explicit, so tests can
    assert both sides of the shim-key boundary. *)

val filter_environment : string array -> string array
(** Return a copy of the given [Unix.environment]-shaped array with only
    allowed keys retained. Entries that do not contain ['='] are kept iff
    their key is allowed. *)
