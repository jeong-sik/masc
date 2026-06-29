type runtime_snapshot = {
  enabled : bool;
  judge_online : bool;
  refreshing : bool;
  generated_at : string option;
  expires_at : string option;
  model_used : string option;
  keeper_name : string;
  last_error : string option;
}

val start :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  base_path:string ->
  build_facts:(unit -> Yojson.Safe.t) ->
  unit

val runtime_status : string -> runtime_snapshot

val fresh_interactions_json : base_path:string -> Yojson.Safe.t

val notify_activity : base_path:string -> unit
