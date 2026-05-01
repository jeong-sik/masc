open Base
module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float
module Random = Stdlib.Random

(** Agent Registry Eio - Global agent identity tracking

    Actor model: all mutable state (identity registry, session→key map,
    resolved-name cache) is held in a single Mutex-protected record, removing
    the TOCTOU race in the previous three-Atomic-store design.

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

(** {1 Background Maintenance} *)

(** Start a periodic cleanup fiber.  Call once at server startup within an
    active Eio switch.  [interval] defaults to 300 seconds. *)
val start_cleanup_loop :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  ?interval:float ->
  unit -> unit

