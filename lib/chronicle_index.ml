(** Chronicle_index — index structure for navigating chronicle epochs.
    @since Project Chronicle Phase 1 *)

type epoch_summary =
  { id : string
  ; label : string
  ; start_date : string
  ; end_date : string
  ; status : Chronicle_types.epoch_status
  ; file_path : string
  ; conductivity : float
  }
[@@deriving yojson, show]

type index =
  { schema_version : int
  ; repo : string
  ; last_updated : string
  ; epochs : epoch_summary list
  ; last_commit_indexed : string
  }
[@@deriving yojson, show]

let current_schema_version = 1

type pheromone_policy =
  { tau_min : float
  ; tau_max : float
  ; base_evaporation : float
  ; stagnation_threshold : float
  ; stagnation_boost : float
  }

let default_pheromone_policy =
  { tau_min = 0.05
  ; tau_max = 1.0
  ; base_evaporation = 0.08
  ; stagnation_threshold = 0.65
  ; stagnation_boost = 0.22
  }

let clamp_float ~min_v ~max_v value =
  max min_v (min max_v value)

let policy_or_default = function
  | Some policy -> policy
  | None -> default_pheromone_policy

let empty ~repo ~now =
  { schema_version = current_schema_version
  ; repo
  ; last_updated = now
  ; epochs = []
  ; last_commit_indexed = ""
  }

let find_epoch (idx : index) epoch_id =
  List.find_opt (fun (s : epoch_summary) -> String.equal s.id epoch_id) idx.epochs

let active_epochs (idx : index) =
  List.filter (fun (s : epoch_summary) ->
    match s.status with
    | Chronicle_types.Active -> true
    | Chronicle_types.Completed | Chronicle_types.Abandoned -> false)
    idx.epochs

let add_or_replace_epoch (idx : index) (summary : epoch_summary) =
  let filtered =
    List.filter (fun (s : epoch_summary) -> not (String.equal s.id summary.id)) idx.epochs
  in
  { idx with epochs = summary :: filtered }

let bound_conductivity ?policy value =
  let policy = policy_or_default policy in
  clamp_float ~min_v:policy.tau_min ~max_v:policy.tau_max value

let active_trail_stagnation_score epochs =
  let active_conductivities =
    epochs
    |> List.filter_map (fun (s : epoch_summary) ->
           match s.status with
           | Chronicle_types.Active -> Some (max 0.0 s.conductivity)
           | Chronicle_types.Completed | Chronicle_types.Abandoned -> None)
  in
  match active_conductivities with
  | [] -> 0.0
  | [ only ] -> if only <= 0.0 then 0.0 else 1.0
  | conductivities ->
      let total = List.fold_left ( +. ) 0.0 conductivities in
      if total <= 0.0 then
        0.0
      else
        let max_share =
          (List.fold_left max 0.0 conductivities) /. total
        in
        let balanced_share =
          1.0 /. Float.of_int (List.length conductivities)
        in
        if max_share <= balanced_share then
          0.0
        else
          clamp_float ~min_v:0.0 ~max_v:1.0
            ((max_share -. balanced_share) /. (1.0 -. balanced_share))

let adaptive_evaporation_rate ?policy ~stagnation_score () =
  let policy = policy_or_default policy in
  let stagnation_score = clamp_float ~min_v:0.0 ~max_v:1.0 stagnation_score in
  let threshold = clamp_float ~min_v:0.0 ~max_v:1.0 policy.stagnation_threshold in
  let denominator = max 0.000_001 (1.0 -. threshold) in
  let boost_ratio =
    if stagnation_score <= threshold then
      0.0
    else
      (stagnation_score -. threshold) /. denominator
  in
  clamp_float ~min_v:0.0 ~max_v:1.0
    (policy.base_evaporation +. (policy.stagnation_boost *. boost_ratio))

let evaporate_conductivity ?policy ~stagnation_score conductivity =
  let rate = adaptive_evaporation_rate ?policy ~stagnation_score () in
  bound_conductivity ?policy (conductivity *. (1.0 -. rate))

let evaporate_active_epochs ?policy idx =
  let stagnation_score = active_trail_stagnation_score idx.epochs in
  let epochs =
    List.map
      (fun (summary : epoch_summary) ->
         match summary.status with
         | Chronicle_types.Active ->
             { summary with
               conductivity =
                 evaporate_conductivity ?policy ~stagnation_score
                   summary.conductivity
             }
         | Chronicle_types.Completed | Chronicle_types.Abandoned -> summary)
      idx.epochs
  in
  { idx with epochs }
