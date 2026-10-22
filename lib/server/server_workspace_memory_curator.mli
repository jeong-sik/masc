(** One serialized Addon-backed Curator owner per physical workspace. *)
val start : sw:Eio.Switch.t -> config:Workspace.config -> unit
(** Discover/recover original work before new capture. Existing accepted local
    settlement survives Off; new roots and successors use fresh configured
    Runtime authority. Classification and Briefing keep separate durable
    boundaries. Observer intents are retained independently; registry delivery
    is a separate integration boundary. *)
type refresh = Queued | No_owner | Unavailable of string
val request : base_path:string -> refresh
(** Signal the existing owner only; no storage or model work in the caller. *)
module For_testing : sig
  val is_idle : base_path:string -> bool
  val stop : base_path:string -> unit
end
