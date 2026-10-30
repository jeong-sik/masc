open Keeper_registry_types

let threshold = 5
let window_sec = 60.0
let state : (int * float) StringMap.t Atomic.t = Atomic.make StringMap.empty

let record ~base_path name =
  let key = registry_key ~base_path name in
  let now = Time_compat.now () in
  let rec loop () =
    let current = Atomic.get state in
    let count, first_at, breached_now =
      match StringMap.find_opt key current with
      | Some (prev_count, prev_first_at) when now -. prev_first_at <= window_sec ->
        let new_count = prev_count + 1 in
        let breached = prev_count < threshold && new_count >= threshold in
        new_count, prev_first_at, breached
      | _ ->
        (* Fresh window: no prior state, or the prior window expired. *)
        1, now, false
    in
    let updated = StringMap.add key (count, first_at) current in
    if Atomic.compare_and_set state current updated then count, breached_now else loop ()
  in
  loop ()
;;

let clear ~base_path name =
  let key = registry_key ~base_path name in
  let rec loop () =
    let current = Atomic.get state in
    if StringMap.mem key current
    then (
      let updated = StringMap.remove key current in
      if not (Atomic.compare_and_set state current updated) then loop ())
  in
  loop ()
;;
