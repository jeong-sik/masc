(** Agent Registry Eio - Global agent identity tracking

    One immutable identity/session/cache snapshot is published through an
    atomic compare-and-set transition. Identity materialization and logging
    stay outside the retry loop; pure transitions close creation races.

    @since 0.5.0
*)

(** {1 Initialization} *)

val reset_for_testing : unit -> unit

(** {1 Identity Resolution} *)

val get_or_create_identity : ?mcp_session_id:string -> Yojson.Safe.t -> Client_identity.t

(** {1 Resolved Agent Name Cache}

    The cache carries the resolved name together with the ephemerality
    decided at mint time. Storing only the [string] previously laundered
    that origin away, forcing the auth-fallback consumer to re-derive it
    with a [String.starts_with name ~prefix:"agent-"] substring probe.
    Carrying the bit lets the consumer match on a typed origin instead. *)

val get_resolved_name : string -> (string * bool) option
(** [get_resolved_name sid] returns [Some (name, is_ephemeral)] for a
    cached MCP session, or [None]. [is_ephemeral] is [true] when the
    cached name was system-minted (own generated fallback or a
    [`System_fallback] identity), [false] for a caller-supplied or
    externally resolved name. *)

val set_resolved_name : string -> string -> is_ephemeral:bool -> unit
(** [set_resolved_name sid name ~is_ephemeral] caches [name] for [sid]
    along with the ephemerality decided at the call site (no substring
    re-derivation on read). *)

(** {1 Statistics} *)

val total_count : unit -> int

(** {1 Cleanup} *)

val clear_all : unit -> unit
(** Atomically closes the process registry and clears registered identities
    and MCP-session mappings. Once closed, later calls may still materialize
    an unregistered identity for their immediate request but cannot repopulate
    process state. Intended for process shutdown; individual sessions must use
    {!unregister_mcp_session}. *)

val unregister_mcp_session : string -> unit
(** Ends the registration owned by an MCP transport session. *)
