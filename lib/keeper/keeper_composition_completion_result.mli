(** Read the original terminal request for a completion wake. This projection
    does not replay work or manufacture a result from process-local state. *)
type t

val read :
  base_path:string -> keeper_name:string ->
  Keeper_event_queue.composition_completion -> t

val to_json : t -> Yojson.Safe.t
(** Include exact status lookup coordinates, source task/turn/run references,
    canonical status and selected exports. An export projection that exceeds
    the existing Agent-Core inline context boundary is represented by its
    exact request reference; JSON values are never clipped. Unavailable or
    inconsistent canonical records remain explicit in the projection. *)
