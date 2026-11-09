type scope = {
  play_client : string;
  machine : Machine_lane.t;
}

type connection_outcome = Connected | Stale

val presence_action :
  Play_room.presence_operation -> scope -> (Play_room.action, Play_room.error) result
(** The Join or Leave action a scope stands for, parsed like any request: an
    invalid [play_client] is refused here. *)

val connect :
  base_path:string -> agent_name:string -> role:Masc_domain.agent_role ->
  scope:scope -> sse_client_id:int -> (connection_outcome, Play_room.error) result
(** Join, then install the lease for this exact Observer [sse_client_id].
    An older connect returns [Stale] and cannot replace its successor. *)

val renew :
  base_path:string -> agent_name:string -> role:Masc_domain.agent_role ->
  scope:scope -> sse_client_id:int -> (unit, Play_room.error) result
(** Renew only the exact current lease. A stale id is an inert success. *)

val disconnect :
  base_path:string -> agent_name:string -> role:Masc_domain.agent_role ->
  scope:scope -> sse_client_id:int -> (unit, Play_room.error) result
(** Remove only the exact current lease and finish Leave under cancellation
    protection. A stale id is an inert success. *)

val perform_with_change :
  base_path:string -> who:string -> speaker:Play_room.speaker ->
  Play_room.action -> (Play_room.snapshot * Play_room.change option, Play_room.error) result
(** Read and Say use the ordinary transaction without owning membership.
    Join and Leave execute only without an active lease for the authenticated
    principal and client. A guarded action returns the current snapshot and no
    change without writing. The caller supplies the verified principal and speaker. *)

val perform_http :
  base_path:string -> agent_name:string -> role:Masc_domain.agent_role ->
  Play_room.action -> (Play_room.snapshot, Play_room.error) result
(** Check CanPlayMachine and call {!perform_with_change} with Participant speech,
    then announce only the actual public transition. *)

module For_testing : sig
  val with_permission :
    (Masc_domain.agent_role -> Masc_domain.permission -> bool) ->
    (unit -> 'a) -> 'a

  val with_perform :
    (base_path:string -> who:string -> speaker:Play_room.speaker -> now:float ->
     Play_room.action -> (Play_room.snapshot * Play_room.change, Play_room.error) result) ->
    (unit -> 'a) -> 'a
end
