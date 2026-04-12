(** Shared context for autoresearch tool handlers. *)

type t = {
  base_path : string;
  agent_name : string option;
  start_operation :
    (goal:string ->
    target_file:string ->
    (Yojson.Safe.t, string) Stdlib.result)
    option;
  config : Room.config option;
  sw : Eio.Switch.t option;
  clock : float Eio.Time.clock_ty Eio.Resource.t option;
}
