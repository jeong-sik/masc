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

(** Reserve a finite runtime fleet before forking normal discoverable post
    admission. Initial cursor candidates retain synchronous durability;
    established lanes are read and recorded off the producer fiber. Cursors
    still catch up independently using the same durable candidate identities. *)
val enqueue_discoverable_post :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  config:Workspace.config -> Board_dispatch.board_signal -> unit
