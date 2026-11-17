(** A Codex System delivery plan. The full native configuration remains
    unchanged; an acknowledged Developer packet can refresh just the issued
    standing observations when the exact base is already held. A plan is not
    an acknowledgement or settlement. *)
type t = private {
  full_receipt : Keeper_official_client_session_store.held_context;
  developer_context : string list;
  observations_in_developer : Keeper_context_assembly.system_observation list;
  persistent_context : Keeper_official_client_session_store.held_context list;
  replaced_context : Keeper_official_client_session_store.carried_context list;
}

val prepare :
  full_system:string -> system_prompt:string -> posture_notes:string list ->
  assembly:Keeper_context_assembly.t option ->
  previously_held:Keeper_official_client_session_store.held_context list option -> t
(** [None] is a fresh thread. [Some held] is a resume's settled evidence.
    Only an exact issued System partition admits component delivery. Opaque
    overrides and unsupported standing observations keep full refresh.
    A component basis absent from [held] also requires full refresh. *)

val with_carried_context :
  t -> Keeper_official_client_session_store.held_context list ->
  Keeper_official_client_session_store.held_context list
(** Replace the plan's System receipts without retaining superseded digests.
    The caller may settle these only through its existing completed-turn
    transition, after all required Developer injections have acknowledged. *)
