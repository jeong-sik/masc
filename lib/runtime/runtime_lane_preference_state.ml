module By_lane = Map.Make (String)

type preference =
  { candidate : string
  ; noted_at : float
  }

type observation =
  | No_preference
  | Expired_preference
  | Active_preference of preference

type t = preference By_lane.t

let empty = By_lane.empty

let remember ~lane_id ~candidate ~noted_at state =
  match By_lane.find_opt lane_id state with
  | Some current when Float.compare current.noted_at noted_at > 0 -> state
  | Some _ | None -> By_lane.add lane_id { candidate; noted_at } state
;;

let observe ~now ~ttl_s ~lane_id state =
  match By_lane.find_opt lane_id state with
  | None -> state, No_preference
  | Some preference ->
    if Float.compare ttl_s 0.0 > 0
       && Float.compare (now -. preference.noted_at) ttl_s < 0
    then state, Active_preference preference
    else By_lane.remove lane_id state, Expired_preference
;;

let reorder observation candidates =
  match observation with
  | Active_preference { candidate; _ }
    when List.exists (String.equal candidate) candidates ->
    candidate :: List.filter (fun id -> not (String.equal id candidate)) candidates
  | No_preference | Expired_preference | Active_preference _ -> candidates
;;

let preferred = function
  | Active_preference { candidate; noted_at } -> Some (candidate, noted_at)
  | No_preference | Expired_preference -> None
;;
