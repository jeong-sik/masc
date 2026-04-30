type t = {
  pools : Cascade_pool.t list;
  keeper_pool_map : (string, Cascade_pool.pool_id) Hashtbl.t;
}

let create () =
  let tier1 =
    Cascade_pool.create Cascade_pool.Tier1 ~provider_keys:["glm"; "kimi"; "claude"; "gemini"]
  in
  let tier2 =
    Cascade_pool.create Cascade_pool.Tier2 ~provider_keys:["ollama"]
  in
  let emergency =
    Cascade_pool.create Cascade_pool.Emergency ~provider_keys:[]
  in
  let pools = [tier1; tier2; emergency] in
  let keeper_pool_map = Hashtbl.create 64 in
  { pools; keeper_pool_map }

let resolve_pool t ~keeper_name =
  match Hashtbl.find_opt t.keeper_pool_map keeper_name with
  | Some pool_id -> pool_id
  | None -> Cascade_pool.Tier1

let execute_with_fallback t ~keeper_name f =
  let primary_id = resolve_pool t ~keeper_name in
  let ordered_ids =
    match primary_id with
    | Cascade_pool.Tier1 ->
        [Cascade_pool.Tier1; Cascade_pool.Tier2; Cascade_pool.Emergency]
    | Cascade_pool.Tier2 ->
        [Cascade_pool.Tier2; Cascade_pool.Tier1; Cascade_pool.Emergency]
    | Cascade_pool.Emergency ->
        [Cascade_pool.Emergency; Cascade_pool.Tier1; Cascade_pool.Tier2]
  in
  let rec try_pools ids reasons =
    match ids with
    | [] -> Error (`All_pools_exhausted (List.rev reasons))
    | pool_id :: rest ->
        let pool_opt =
          List.find_opt (fun p -> Cascade_pool.id p = pool_id) t.pools
        in
        match pool_opt with
        | None ->
            try_pools rest (("Pool not found: " ^ Cascade_pool.pool_id_to_string pool_id) :: reasons)
        | Some pool ->
            if Cascade_pool.all_in_cooldown pool then
              try_pools rest
                (("Pool in cooldown: " ^ Cascade_pool.pool_id_to_string pool_id) :: reasons)
            else
              let provider_keys = Cascade_pool.provider_keys pool in
              let available =
                List.find_opt
                  (fun key ->
                     not
                       (Cascade_health_tracker.is_in_cooldown
                          (Cascade_pool.health_tracker pool)
                          ~provider_key:key))
                  provider_keys
              in
              match available with
              | None ->
                  try_pools rest
                    (("Pool in cooldown: " ^ Cascade_pool.pool_id_to_string pool_id) :: reasons)
              | Some provider_key -> (
                  match f ~provider_key with
                  | Ok _ as ok -> ok
                  | Error _e ->
                      try_pools rest
                        (("Pool failed: " ^ Cascade_pool.pool_id_to_string pool_id) :: reasons))
  in
  try_pools ordered_ids []

let pools t = t.pools
