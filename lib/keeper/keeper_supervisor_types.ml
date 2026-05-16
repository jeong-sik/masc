(** Keeper_supervisor_types — pure type definitions and helpers extracted
    from Keeper_supervisor (2632 LoC godfile).

    See keeper_supervisor_types.mli for rationale and contract. *)

let supervision_cohort_size = 8

type supervision_cohort =
  { cohort_id : int
  ; keepers : Keeper_registry.registry_entry list
  }

let supervision_cohorts
      ?(cohort_size = supervision_cohort_size)
      (entries : Keeper_registry.registry_entry list)
  =
  let cohort_size = max 1 cohort_size in
  let sorted =
    List.sort
      (fun (a : Keeper_registry.registry_entry) (b : Keeper_registry.registry_entry) ->
         String.compare a.name b.name)
      entries
  in
  let rec take n acc rest =
    match n, rest with
    | 0, rest -> List.rev acc, rest
    | _, [] -> List.rev acc, []
    | n, entry :: rest -> take (n - 1) (entry :: acc) rest
  in
  let rec loop cohort_id acc remaining =
    match remaining with
    | [] -> List.rev acc
    | _ ->
      let keepers, rest = take cohort_size [] remaining in
      loop (cohort_id + 1) ({ cohort_id; keepers } :: acc) rest
  in
  loop 0 [] sorted
;;
