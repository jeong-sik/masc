(** Agent Registry Eio - Global agent identity tracking

    @since 0.5.0
*)

(** {1 Initialization} *)

val init : unit -> unit
val reset_for_testing : unit -> unit

(** {1 Identity Resolution} *)

val get_or_create_identity : ?mcp_session_id:string -> Yojson.Safe.t -> Agent_identity.t
val get_by_name : string -> Agent_identity.t option
val get_by_session : string -> Agent_identity.t option

(** {1 Resolved Agent Name Cache} *)

val get_resolved_name : string -> string option
val set_resolved_name : string -> string -> unit

(** {1 Statistics} *)

val active_count : ?within_seconds:float -> unit -> int
val total_count : unit -> int
val list_active : ?within_seconds:float -> unit -> Agent_identity.t list

(** {1 Cleanup} *)

val clear_session_caches : unit -> unit
val cleanup_stale_sessions : unit -> int
val unregister : string -> unit
