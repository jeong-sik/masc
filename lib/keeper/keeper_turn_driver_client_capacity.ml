(** Keeper_turn_driver_client_capacity — Client-side capacity slot acquisition.

    Extracted from [keeper_turn_driver.ml] during godfile decomposition.

    @since God file decomposition *)

let acquire_client_capacity_slot candidate =
  let capacity_key =
    Cascade_runtime_candidate.capacity_key candidate |> String.trim
  in
  if String.equal capacity_key ""
  then `No_client_capacity
  else
    match Cascade_client_capacity.try_acquire capacity_key with
    | Unregistered -> `No_client_capacity
    | Acquired release -> `Acquired (capacity_key, release)
    | Full { retry_after_s } -> `Full (capacity_key, retry_after_s)
