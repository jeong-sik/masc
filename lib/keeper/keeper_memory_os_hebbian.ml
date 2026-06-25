(* Keeper_memory_os_hebbian — derive the cross-keeper Hebbian synapse view from
   shared facts.

   This is domain logic: it reads the shared fact store and produces a dashboard-
   neutral JSON value. The HTTP serializer in [Server_dashboard_http_memory_subsystems]
   only renders the result; it does not own the derivation (RFC boundary). *)

(* The Hebbian synapse weight is a DISPLAY-only saturation scale for the
   dashboard graph, not a learned or normalized synaptic strength: a keeper pair
   reaches [max_synapse_weight] once they co-observe [synapse_saturation_facts]
   shared facts, scaling linearly below that. Named so the scale is explicit and
   reviewable rather than an unexplained literal (it drives no behavior — purely
   how thick the dashboard edge renders). *)
let max_synapse_weight = 1.0
let synapse_saturation_facts = 10.0

(* RFC-0244 Tier 2: derive the Hebbian synapse view from cross-keeper
   corroboration. Each shared fact that was observed by multiple keepers
   becomes one or more synapses; [last_consolidation] is the most recent
   verification timestamp of any shared fact. Before this, the dashboard field
   was a hardcoded placeholder that always reported an empty graph and
   last_consolidation=0.0, so recorded memory appeared unviewable. *)
let compute ~base_path ~now () =
  try
    let keepers_dir =
      Config_dir_resolver.keepers_dir_for_base_path ~base_path
    in
    let shared_facts =
      Keeper_memory_os_io.read_facts_all_for_keepers_dir
        ~keepers_dir
        ~keeper_id:Keeper_memory_os_types.shared_store_id
      |> List.filter (Keeper_memory_os_types.fact_is_current ~now)
    in
    (* [last_consolidation] is the most recent [last_verified_at] of any
       current shared fact, not the timestamp of the last consolidator run.
       The name matches the dashboard schema; the value is fact-derived because
       the shared store is the SSOT for cross-keeper corroboration. *)
    let last_consolidation =
      shared_facts
      |> List.filter_map (fun (f : Keeper_memory_os_types.fact) -> f.last_verified_at)
      |> List.fold_left Float.max 0.0
    in
    let synapse_counts : ((string * string), int) Hashtbl.t = Hashtbl.create 16 in
    shared_facts
    |> List.iter (fun (fact : Keeper_memory_os_types.fact) ->
      (* Dedupe within a single fact so a duplicate observer cannot inflate the
         synapse count, and convert to an array for O(1) pairwise indexing. *)
      let keepers =
        fact.observed_by
        |> List.sort_uniq String.compare
        |> Array.of_list
      in
      let n = Array.length keepers in
      for i = 0 to n - 1 do
        for j = i + 1 to n - 1 do
          let a = keepers.(i) in
          let b = keepers.(j) in
          let key = if String.compare a b <= 0 then a, b else b, a in
          let prev = Option.value (Hashtbl.find_opt synapse_counts key) ~default:0 in
          Hashtbl.replace synapse_counts key (prev + 1)
        done
      done);
    let synapses =
      Hashtbl.fold
        (fun (a, b) count acc ->
           let weight =
             Float.min max_synapse_weight (float_of_int count /. synapse_saturation_facts)
           in
           `Assoc
             [ "from_agent", `String a
             ; "to_agent", `String b
             ; "weight", `Float weight
             ]
           :: acc)
        synapse_counts
        []
    in
    `Assoc [ "synapses", `List synapses; "last_consolidation", `Float last_consolidation ]
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    (* Log rather than silently swallow: a persistent fact-store read failure
       must be distinguishable from a genuinely empty graph, otherwise it
       presents as the same last_consolidation=0.0 "unviewable" state this
       function was added to fix. *)
    Log.Server.warn
      "compute_hebbian: synapse view derivation failed, returning empty graph: %s"
      (Printexc.to_string exn);
    `Assoc [ "synapses", `List []; "last_consolidation", `Float 0.0 ]
;;