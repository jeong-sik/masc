module Observation = Exact_lane_slot_observation
type transport = Http | Official_client
let transport = function Observation.Http _ | Http_unobserved -> Http
  | Official_client -> Official_client
let transport_string = function Http -> "http" | Official_client -> "official_client"
let binding_json (binding:Agent_core.Exact_output.binding_observation) =
  `Assoc ["provider_id",(match binding.provider_id with None -> `Null | Some id -> `String id);
    "model_id",`String binding.model_id;
    "provider_kind",`String (Llm_provider.Provider_config.string_of_provider_kind binding.provider_kind);
    "endpoint",`String binding.endpoint]
let slots_json ~current_http ~declared_http ~declared_cli ~runs =
  let retained=List.concat_map (fun (run:Exact_lane_run_registry.run) ->
    match run.slot_observations with None | Some (Error _) -> []
    | Some (Ok observations) -> List.mapi (fun index observation -> run,index,observation) observations) runs in
  let declared=List.map (fun id -> Http,id) declared_http
    @ List.map (fun id -> Official_client,id) declared_cli in
  let historical=List.map (fun (_,_,(observation:Observation.t)) ->
    transport observation.binding,observation.slot_id) retained in
  let slots=List.fold_left (fun seen key -> if List.mem key seen then seen else seen@[key])
    [] (declared@historical) in
  let latest ~attempt predicate observations =
    let at (observation:Observation.t) =
      if attempt then observation.started_at else
        match observation.finished_at with Some _ as at -> at | None -> observation.started_at in
    let anchor ((run:Exact_lane_run_registry.run),index,_) time = time,run.run_id,index in
    List.fold_left (fun latest ((_,_,observation) as candidate) ->
      match predicate observation,at observation with
      | false,_ | true,None -> latest
      | true,Some time -> (match latest with
          | None -> Some (candidate,time)
          | Some (previous,previous_time) ->
            if Stdlib.compare (anchor candidate time) (anchor previous previous_time)>0
            then Some (candidate,time) else latest)) None observations |> Option.map fst in
  let observed_json = function
    | None -> `Null
    | Some ((run:Exact_lane_run_registry.run),_,observation) ->
      `Assoc ["run_id",`String run.run_id;"observation",Observation.to_yojson observation] in
  `List (List.map (fun (kind,slot_id) ->
    let history=List.filter (fun (_,_,(observation:Observation.t)) ->
      observation.slot_id=slot_id && transport observation.binding=kind) retained in
    let current_binding=match kind,List.assoc_opt slot_id current_http with
      | Http,Some binding -> binding_json binding
      | Http,None | Official_client,(None | Some _) -> `Null in
    `Assoc ["slot_id",`String slot_id;"transport",`String (transport_string kind);
      "declared",`Bool (List.mem (kind,slot_id) declared);"current_binding",current_binding;
      "ordering_scope",`String "dated_only";
      "last_observation",observed_json (latest ~attempt:false (fun _ -> true) history);
      "last_attempt",observed_json (latest ~attempt:true (fun observation -> observation.Observation.started_at<>None) history);
      "last_success",observed_json (latest ~attempt:false (fun observation -> observation.Observation.finished_at<>None &&
        match observation.outcome with
        | Accepted -> true
        | Unresolved | Semantic_rejected | Admission_rejected _ | Execution_failed _ | Cli_failed _ -> false) history);
      "last_failure",observed_json (latest ~attempt:false (fun observation -> observation.Observation.finished_at<>None &&
        match observation.outcome with
        | Semantic_rejected | Admission_rejected _ | Execution_failed _ | Cli_failed _ -> true
        | Accepted | Unresolved -> false) history);
      "undated_outcomes",`List (List.filter_map (fun ((_,_,(observation:Observation.t)) as value) ->
        match observation.finished_at,observation.outcome with
        | None,(Accepted | Semantic_rejected | Admission_rejected _ | Execution_failed _ | Cli_failed _) ->
          Some (observed_json (Some value))
        | Some _,_ | None,Unresolved -> None) history)]) slots)
