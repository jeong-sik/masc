(** Room_protocol exposes the read-side room boundary used by HTTP routes.

    It keeps route modules from depending directly on the Coord implementation
    hub while preserving the existing response shape. *)

type status = {
  cluster : string;
  project : string;
  tempo_interval_s : float;
  paused : bool;
}

val status : Coord.config -> status

val tasks :
  ?status_filter:string ->
  ?include_done:bool ->
  ?include_cancelled:bool ->
  Coord.config ->
  Masc_domain.task list

val task_assignee : Masc_domain.task -> string option

val agents :
  ?status_filter:string ->
  Coord.config ->
  Masc_domain.agent list

val messages :
  ?agent_filter:string ->
  since_seq:int ->
  limit:int ->
  Coord.config ->
  Masc_domain.message list
