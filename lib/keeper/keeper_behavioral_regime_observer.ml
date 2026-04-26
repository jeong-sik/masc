(** Behavioral regime observer — pure projection from registry entry.
    See [.mli] for contract. *)

module R = Keeper_behavioral_regime
module KR = Keeper_registry

type snapshot = R.snapshot

let tool_aggregates_of_entry (entry : KR.registry_entry)
  : (string * R.tool_aggregate) list
  =
  KR.StringMap.fold
    (fun name (e : Keeper_types.tool_call_entry) acc ->
       (name, { R.count = e.count; failures = e.failures }) :: acc)
    entry.tool_usage
    []
;;

let input_of_entry (entry : KR.registry_entry) : R.input =
  { turn_consecutive_failures = entry.turn_consecutive_failures
  ; restart_count = entry.restart_count
  ; last_restart_ts = entry.last_restart_ts
  ; tool_aggregates = tool_aggregates_of_entry entry
  }
;;

let observe ?now (entry : KR.registry_entry) : snapshot =
  let now =
    match now with
    | Some t -> t
    | None -> Unix.gettimeofday ()
  in
  R.derive ~now (input_of_entry entry)
;;

let all_snapshots ~(base_path : string) () : snapshot list =
  KR.all ~base_path () |> List.map (fun entry -> observe entry)
;;

let snapshot_to_json = R.snapshot_to_json
