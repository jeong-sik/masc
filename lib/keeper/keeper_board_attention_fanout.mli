(** Event-scoped System One judgment. Candidates are durable before dispatch;
    partition claims fence concurrent workers and process recovery. *)
val dispatch :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  base_path:string ->
  Keeper_board_attention_candidate.candidate list -> unit
(** Fork one request for the eligible candidates whose partitions can be
    claimed. Excluded, contended and failed candidates remain with the ordinary
    worker. Relevant completions are delivered by the owner. *)
