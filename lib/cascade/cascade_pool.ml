type pool_id =
  | Tier1
  | Tier2
  | Emergency

type t = {
  id : pool_id;
  provider_keys : string list;
  health_tracker : Cascade_health_tracker.t;
}

let pool_id_to_string = function
  | Tier1 -> "Tier1"
  | Tier2 -> "Tier2"
  | Emergency -> "Emergency"

let pool_id_of_string = function
  | "Tier1" -> Some Tier1
  | "Tier2" -> Some Tier2
  | "Emergency" -> Some Emergency
  | _ -> None

let create pool_id ~provider_keys =
  if provider_keys = [] then
    raise (Invalid_argument
             (Printf.sprintf "Cascade_pool.create: provider_keys must not be empty for %s pool"
                (pool_id_to_string pool_id)))
  ;
  {
    id = pool_id;
    provider_keys;
    health_tracker = Cascade_health_tracker.create ();
  }

let id t = t.id

let provider_keys t = t.provider_keys

let health_tracker t = t.health_tracker

let all_in_cooldown t =
  List.for_all
    (fun key -> Cascade_health_tracker.is_in_cooldown t.health_tracker ~provider_key:key)
    t.provider_keys

let summary t =
  let id_str = pool_id_to_string t.id in
  let count = List.length t.provider_keys in
  let cooldown_count =
    List.fold_left
      (fun acc key ->
         if Cascade_health_tracker.is_in_cooldown t.health_tracker ~provider_key:key then
           acc + 1
         else
           acc)
      0
      t.provider_keys
  in
  Printf.sprintf "Pool(%s, providers=%d, in_cooldown=%d/%d)"
    id_str count cooldown_count count
