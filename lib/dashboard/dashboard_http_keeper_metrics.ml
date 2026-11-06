(** Counters for the keeper metrics window. *)

module Count_map = Map.Make (String)

let count_map_incr (map : int Count_map.t) (key : string) : int Count_map.t =
  let key = String.trim key in
  if String.equal key "" then map
  else
    let cur = Option.value ~default:0 (Count_map.find_opt key map) in
    Count_map.add key (cur + 1) map

let top_counts_map_json
    ?(limit = 5)
    ~(name_key : string)
    (map : int Count_map.t) : Yojson.Safe.t list =
  map
  |> Count_map.bindings
  |> List.sort (fun (ka, va) (kb, vb) ->
       let c = Int.compare vb va in
       if c <> 0 then c else String.compare ka kb)
  |> Keeper_types_profile.take limit
  |> List.map (fun (k, v) ->
       `Assoc [ (name_key, `String k); ("count", `Int v) ])

