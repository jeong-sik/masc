type outcome =
  | Turn_ok
  | Turn_rested
  | Turn_failed

let outcome_to_string = function
  | Turn_ok -> "ok"
  | Turn_rested -> "rested"
  | Turn_failed -> "failed"

let outcome_of_string = function
  | "ok" -> Some Turn_ok
  | "rested" -> Some Turn_rested
  | "failed" -> Some Turn_failed
  | _ -> None
;;

type sample =
  { at : float
  ; outcome : outcome
  }

type pulse =
  { samples : sample list
  ; truncated : bool
  }

let max_samples_per_keeper = 24

module Key = struct
  type t = string * string

  let compare (b1, k1) (b2, k2) =
    let c = String.compare b1 b2 in
    if c <> 0 then c else String.compare k1 k2
  ;;
end

module KeyMap = Map.Make (Key)

let state : pulse KeyMap.t Atomic.t = Atomic.make KeyMap.empty

let rec take n = function
  | [] -> []
  | _ when n <= 0 -> []
  | x :: xs -> x :: take (n - 1) xs
;;

let record ~base_path ~keeper_name ~at outcome =
  let key = base_path, keeper_name in
  let new_sample = { at; outcome } in
  let rec loop () =
    let current = Atomic.get state in
    let next_val =
      match KeyMap.find_opt key current with
      | None -> { samples = [ new_sample ]; truncated = false }
      | Some existing ->
        let combined = new_sample :: existing.samples in
        if List.length combined > max_samples_per_keeper
        then { samples = take max_samples_per_keeper combined; truncated = true }
        else { samples = combined; truncated = existing.truncated }
    in
    let next = KeyMap.add key next_val current in
    if Atomic.compare_and_set state current next then () else loop ()
  in
  loop ()
;;

let get ~base_path ~keeper_name =
  KeyMap.find_opt (base_path, keeper_name) (Atomic.get state)
;;

let seed ?(override = false) ~base_path ~keeper_name ~samples ~truncated () =
  let key = base_path, keeper_name in
  let rec loop () =
    let current = Atomic.get state in
    match KeyMap.find_opt key current with
    | Some _ when not override -> ()
    | _ ->
      let is_truncated = truncated || List.length samples > max_samples_per_keeper in
      let bounded_samples =
        if List.length samples > max_samples_per_keeper
        then take max_samples_per_keeper samples
        else samples
      in
      let next =
        KeyMap.add key { samples = bounded_samples; truncated = is_truncated } current
      in
      if Atomic.compare_and_set state current next then () else loop ()
  in
  loop ()
;;

let reset_for_tests () = Atomic.set state KeyMap.empty
