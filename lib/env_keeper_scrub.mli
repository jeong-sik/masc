(** Host-to-Keeper subprocess environment boundary.

    Only an exact, closed set of process/runtime keys is inherited from the
    host. Additional environment material comes from
    {!Keeper_secret_projection}; this module performs no product or
    credential-name inference. *)

val is_allowed : string -> bool
(** [is_allowed key] returns [true] only for an exact inherited-host key. *)

val filter_environment : string array -> string array
(** Return a copy of the given [Unix.environment]-shaped array with only
    allowed keys retained, followed by [GIT_EDITOR=false] and
    [GIT_TERMINAL_PROMPT=0] so a command that would wait for a person fails
    instead -- nothing in this process can answer an editor or a credential
    prompt. Those two entries are appended last, so they win over any
    inherited value. Entries that do not contain ['='] are kept iff their key
    is allowed. *)
