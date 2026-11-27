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
  let compare_anchor
      ((run_a : Exact_lane_run_registry.run), idx_a, _) time_a
      ((run_b : Exact_lane_run_registry.run), idx_b, _) time_b =
    let c = Float.compare time_a time_b in
    if c <> 0 then c
    else
      let c = String.compare run_a.run_id run_b.run_id in
      if c <> 0 then c
      else Int.compare idx_a idx_b
  in
  let keep_latest current candidate time =
    match current with
    | None -> Some (candidate, time)
    | Some (prev, prev_time) ->
      if compare_anchor candidate time prev prev_time > 0
      then Some (candidate, time)
      else current
  in
  let observed_json = function
    | None -> `Null
    | Some ((run:Exact_lane_run_registry.run),_,observation) ->
      `Assoc ["run_id",`String run.run_id;"observation",Observation.to_yojson observation] in
  `List (List.map (fun slot ->
    let kind = slot.kind and slot_id = slot.slot_id in
    let current_binding=match kind with
      | Official_client -> `Null
      | Http -> (match Hashtbl.find_opt current_bindings slot_id with
          | Some binding -> binding_json binding
          | None -> `Null) in
    let last_obs = ref None in
    let last_att = ref None in
    let last_ok = ref None in
    let last_fail = ref None in
    let undated = ref [] in
    (* Iterate in forward order by reversing once; compute all 5 projections in one pass. *)
    List.iter
      (fun ((_, _, (observation : Observation.t)) as candidate) ->
         let obs_time =
           match observation.finished_at with
           | Some _ as at -> at
           | None -> observation.started_at
         in
         (match obs_time with
          | Some time -> last_obs := keep_latest !last_obs candidate time
          | None -> ());
         (match observation.started_at with
          | Some time -> last_att := keep_latest !last_att candidate time
          | None -> ());
         (match observation.finished_at, observation.outcome with
          | Some time, Accepted ->
            last_ok := keep_latest !last_ok candidate time
          | Some time, (Semantic_rejected | Admission_rejected _ | Execution_failed _ | Cli_failed _) ->
            last_fail := keep_latest !last_fail candidate time
          | Some _, Unresolved -> ()
          | None, (Accepted | Semantic_rejected | Admission_rejected _ | Execution_failed _ | Cli_failed _) ->
            undated := observed_json (Some candidate) :: !undated
          | None, Unresolved -> ()))
      (List.rev slot.reversed_observations);
    `Assoc ["slot_id",`String slot_id;"lane_key",`String lane_key;"transport",`String (transport_string kind);
      "declared",`Bool slot.declared;"current_binding",current_binding;
      "ordering_scope",`String "dated_only";
      "last_observation",observed_json (Option.map fst !last_obs);
      "last_attempt",observed_json (Option.map fst !last_att);
      "last_success",observed_json (Option.map fst !last_ok);
      "last_failure",observed_json (Option.map fst !last_fail);
      "undated_outcomes",`List (List.rev !undated)]) (List.rev !reversed_slots))
