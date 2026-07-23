(** Submit one Fusion computation through the common durable Keeper async
    lifecycle. The returned [run_id] is the canonical async request id. *)
val handle :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  base_dir:string ->
  keeper:string ->
  now_unix:float ->
  policy:Fusion_policy.t ->
  ?continuation_channel:Keeper_continuation_channel.t ->
  args:Yojson.Safe.t ->
  unit ->
  string

val handle_result :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  base_dir:string ->
  keeper:string ->
  now_unix:float ->
  policy:Fusion_policy.t ->
  ?continuation_channel:Keeper_continuation_channel.t ->
  args:Yojson.Safe.t ->
  unit ->
  Tool_result.result

module For_test : sig
  type compute_runner =
    sw:Eio.Switch.t ->
    net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
    policy:Fusion_policy.t ->
    topology:Fusion_types.fusion_topology ->
    request:Fusion_types.fusion_request ->
    unit ->
    Fusion_orchestrator.compute_outcome

  val handle_with_compute :
    compute:compute_runner ->
    sw:Eio.Switch.t ->
    net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
    base_dir:string ->
    keeper:string ->
    now_unix:float ->
    policy:Fusion_policy.t ->
    ?continuation_channel:Keeper_continuation_channel.t ->
    args:Yojson.Safe.t ->
    unit ->
    string
end
