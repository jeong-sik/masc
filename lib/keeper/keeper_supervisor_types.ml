(** Keeper_supervisor_types — pure type definitions and helpers extracted
    from Keeper_supervisor (2632 LoC godfile).

    See keeper_supervisor_types.mli for rationale and contract. *)

open Keeper_types

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

let fresh_supervision_cohort_keepers ~base_path (cohort : supervision_cohort) =
  List.filter_map
    (fun (entry : Keeper_registry.registry_entry) ->
       Keeper_registry.get ~base_path entry.name)
    cohort.keepers
;;

let iter_supervision_cohorts ?(yield_between = Eio_guard.fair_yield) cohorts ~f =
  let rec loop = function
    | [] -> ()
    | [ cohort ] -> f cohort
    | cohort :: rest ->
      f cohort;
      yield_between ();
      loop rest
  in
  loop cohorts
;;

type persona_drift_log_level =
  | Persona_drift_warn
  | Persona_drift_error

let keeper_defaults_have_inline_identity
    (defaults : Keeper_types_profile.keeper_profile_defaults)
  =
  Option.is_some defaults.goal
  || Option.is_some defaults.short_goal
  || Option.is_some defaults.mid_goal
  || Option.is_some defaults.long_goal
  || Option.is_some defaults.will
  || Option.is_some defaults.needs
  || Option.is_some defaults.desires
  || Option.is_some defaults.instructions
  || defaults.mention_targets <> []
;;

let persona_drift_log_level_for_missing_profile (meta : keeper_meta) =
  match Keeper_types_profile.load_keeper_profile_defaults_result meta.name with
  | Ok defaults when keeper_defaults_have_inline_identity defaults ->
    Persona_drift_warn
  | Ok _ | Error _ -> Persona_drift_error
;;
