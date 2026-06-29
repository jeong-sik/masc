type judge_response
type lifecycle_status
type lifecycle_next_action
type lifecycle_event

type runtime_snapshot = {
  enabled : bool;
  judge_online : bool;
  refreshing : bool;
  status : lifecycle_status;
  generated_at : string option;
  expires_at : string option;
  model_used : string option;
  keeper_name : string;
  last_error : string option;
  next_action : lifecycle_next_action option;
  last_event : lifecycle_event option;
}

val parse_judge_response : Yojson.Safe.t -> (judge_response, string) result

val start :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  base_path:string ->
  build_facts:(unit -> Yojson.Safe.t) ->
  unit

val runtime_status : string -> runtime_snapshot

val fresh_interactions_json : base_path:string -> Yojson.Safe.t
