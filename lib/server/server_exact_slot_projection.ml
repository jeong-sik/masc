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

module Slot_key = struct
  type t = transport * string

  let equal (left_transport, left_id) (right_transport, right_id) =
    match left_transport, right_transport with
    | Http, Http | Official_client, Official_client -> String.equal left_id right_id
    | Http, Official_client | Official_client, Http -> false

  let hash = Hashtbl.hash
end

module Slot_table = Hashtbl.Make (Slot_key)

type slot_history =
  { kind : transport
  ; slot_id : string
  ; declared : bool
  ; mutable reversed_observations : (Exact_lane_run_registry.run * int * Observation.t) list
  }

let slots_json ~owner ~current_http ~declared_http ~declared_cli ~runs =
  match declared_http, declared_cli, runs with
  | [], [], [] -> `List []
  | (_ :: _, _, _) | ([], _ :: _, _) | ([], [], _ :: _) ->
  let lane_key = Runtime_schema.exact_lane_key owner in
  let declared=List.map (fun id -> Http,id) declared_http
    @ List.map (fun id -> Official_client,id) declared_cli in
  (* These records and tables belong to this call. The list alone determines
     output order: declared HTTP, declared CLI, then first-seen historical
     keys. Table iteration cannot reorder slots or same-key observations. *)
  let histories = Slot_table.create (List.length declared) in
  let reversed_slots = ref [] in
  let history ~declared ((kind, slot_id) as key) =
    match Slot_table.find_opt histories key with
    | Some history -> history
    | None ->
      let history = { kind; slot_id; declared; reversed_observations = [] } in
      Slot_table.add histories key history;
      reversed_slots := history :: !reversed_slots;
      history
  in
  List.iter (fun key -> ignore (history ~declared:true key)) declared;
  List.iter
    (fun (run : Exact_lane_run_registry.run) ->
       match run.slot_observations with
       | None | Some (Error _) -> ()
       | Some (Ok observations) ->
         List.iteri
           (fun index (observation : Observation.t) ->
              if observation.lane_key = Some lane_key then (
                let history = history ~declared:false
                    (transport observation.binding, observation.slot_id) in
                history.reversed_observations <-
                  (run, index, observation) :: history.reversed_observations))
           observations)
    runs;
  (* Duplicate declarations keep the first current binding, like assoc_opt. *)
  let current_bindings = Hashtbl.create (List.length current_http) in
  List.iter
    (fun (slot_id, binding) ->
       if not (Hashtbl.mem current_bindings slot_id) then
         Hashtbl.add current_bindings slot_id binding)
    current_http;
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
  `List (List.map (fun slot ->
    let kind = slot.kind and slot_id = slot.slot_id in
    let history = List.rev slot.reversed_observations in
    let current_binding=match kind with
      | Official_client -> `Null
      | Http -> (match Hashtbl.find_opt current_bindings slot_id with
          | Some binding -> binding_json binding
          | None -> `Null) in
    `Assoc ["slot_id",`String slot_id;"lane_key",`String lane_key;"transport",`String (transport_string kind);
      "declared",`Bool slot.declared;"current_binding",current_binding;
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
        | Some _,_ | None,Unresolved -> None) history)]) (List.rev !reversed_slots))
