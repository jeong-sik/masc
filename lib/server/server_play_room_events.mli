type room_scope = {
  play_client : string;
  machine : Machine_lane.t;
}

val room_scope_of_request_target : string -> (room_scope option, string) result
(** Decode a paired [play_client_id]/[play_machine] query. Absence of both is an
    ordinary Observer. A partial, duplicate, or invalid pair is rejected. *)

type connection_outcome = Connected | Stale

val connect :
  base_path:string -> agent_name:string -> role:Masc_domain.agent_role ->
  scope:room_scope -> sse_client_id:int -> (connection_outcome, Play_room.error) result
(** Join, then install the lease for this exact Observer [sse_client_id].
    An older connect returns [Stale] and cannot replace its successor. *)

val renew :
  base_path:string -> agent_name:string -> role:Masc_domain.agent_role ->
  scope:room_scope -> sse_client_id:int -> (unit, Play_room.error) result
(** Renew only the exact current lease. A stale id is an inert success. *)

val disconnect :
  base_path:string -> agent_name:string -> role:Masc_domain.agent_role ->
  scope:room_scope -> sse_client_id:int -> (unit, Play_room.error) result
(** Remove only the exact current lease and finish Leave under cancellation
    protection. A stale id is an inert success. *)

val perform_http :
  base_path:string -> agent_name:string -> role:Masc_domain.agent_role ->
  Play_room.action -> (Play_room.snapshot, Play_room.error) result
(** Join or Leave only without an active lease for the authenticated principal
    and client. A guarded action returns the current snapshot without writing.
    Read and Say use the ordinary transaction without owning membership. *)

module For_testing : sig
  val with_permission :
    (Masc_domain.agent_role -> Masc_domain.permission -> bool) ->
    (unit -> 'a) -> 'a

  val with_perform :
    (base_path:string -> who:string -> speaker:Play_room.speaker -> now:float ->
     Play_room.action -> (Play_room.snapshot * Play_room.change, Play_room.error) result) ->
    (unit -> 'a) -> 'a
end
