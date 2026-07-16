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

val runtime_status : string -> runtime_snapshot

val start :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  config:Workspace.config ->
  masc_tools:Masc_domain.tool_schema list ->
  dispatch:(name:string -> args:Yojson.Safe.t -> Tool_result.result) ->
  build_facts:(unit -> Yojson.Safe.t) ->
  unit ->
  unit

val register_record_operator_judgment :
  (Workspace.config ->
   surface:string ->
   target_type_str:string ->
   target_id:string option ->
   summary:string ->
   confidence:float ->
   ?model_name:string ->
   ?recommended_action:Yojson.Safe.t ->
   evidence_refs:string list ->
   disagreement_with_truth:bool ->
   generated_at:string ->
   generated_at_unix:float ->
   fresh_until:string ->
   fresh_until_unix:float ->
   keeper_name:string ->
   unit ->
   unit) ->
  unit
