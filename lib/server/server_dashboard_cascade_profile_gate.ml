(** Dashboard cascade profile gate — determines which cascade profiles
    are assignable to a keeper, distinguishing
    {[
      valid_profiles
    ]} from
    {[
      invalid_profiles
    ]}
    and
    {[
      invalid_assignments
    ]}.

    Extracted from [server_routes_http_routes_dashboard.ml] (lines
    14-184) as part of the godfile decomp campaign. Owns the pure
    profile-classification pipeline that feeds the dashboard cascade
    assignment UI; runtime snapshot ([Cascade_catalog_runtime]) is
    consulted first, with a fallback to the on-disk validator
    ([Cascade_catalog_validator]) when the snapshot is unavailable. *)

type t = {
  valid_profiles : string list;
  invalid_profiles : (string * string list) list;
  invalid_assignments : (string * string list) list;
}

let compute () : t =
  let config_path = Cascade_runtime.cascade_config_path () in
  let keeper_assignable_profiles =
    Keeper_cascade_profile.keeper_catalog_names ?config_path ()
    |> List.sort_uniq String.compare
  in
  let keeper_assignable_profile profile =
    keeper_assignable_profiles = [] || List.mem profile keeper_assignable_profiles
  in
  let fallback_invalid_profiles =
    match config_path with
    | None -> []
    | Some path ->
        Cascade_catalog_validator.error_messages_by_profile
          ~config_path:path
  in
  match Cascade_catalog_runtime.known_profile_names () with
  | Ok raw_validated_profiles ->
      let validated_profiles =
        raw_validated_profiles |> List.sort_uniq String.compare
      in
      let invalid_profiles =
        (Cascade_catalog_runtime.invalid_profile_errors ()
         @ fallback_invalid_profiles)
        |> Dashboard_cascade.invalid_profiles_with_internal_names
      in
      let keeper_profiles =
        raw_validated_profiles
        |> List.filter keeper_assignable_profile
        |> List.sort_uniq String.compare
      in
      let candidate_profiles =
        if keeper_profiles = [] then validated_profiles else keeper_profiles
      in
      let known_internal_profiles =
        (match config_path with
         | None -> raw_validated_profiles
         | Some path ->
             Cascade_catalog_validator.discover_profiles_for_diagnostics
               ~config_path:path)
        |> List.sort_uniq String.compare
      in
      let invalid_assignments =
        Dashboard_cascade.invalid_assignments_for_public_profiles
          ~known_internal_profiles
          ~invalid_profiles candidate_profiles
      in
      let valid_profiles =
        candidate_profiles
        |> List.filter (fun profile ->
               List.mem profile validated_profiles
               && not (List.mem_assoc profile invalid_assignments))
      in
      { valid_profiles; invalid_profiles; invalid_assignments }
  | Error detail ->
      Log.Keeper.warn
        "cascade_profile_gate: validated runtime snapshot unavailable: %s"
        detail;
      let invalid_profiles =
        Dashboard_cascade.invalid_profiles_with_internal_names
          fallback_invalid_profiles
      in
      let known_internal_profiles =
        (match config_path with
         | None -> []
         | Some path ->
             Cascade_catalog_validator.discover_profiles_for_diagnostics
               ~config_path:path)
        |> List.sort_uniq String.compare
      in
      let keeper_profiles =
        known_internal_profiles
        |> List.filter keeper_assignable_profile
        |> List.sort_uniq String.compare
      in
      let candidate_profiles =
        if keeper_profiles = [] then known_internal_profiles else keeper_profiles
      in
      let invalid_assignments =
        Dashboard_cascade.invalid_assignments_for_public_profiles
          ~known_internal_profiles ~invalid_profiles candidate_profiles
      in
      let invalid_names = List.map fst invalid_assignments in
      let valid_profiles =
        candidate_profiles
        |> List.filter (fun profile -> not (List.mem profile invalid_names))
      in
      { valid_profiles; invalid_profiles; invalid_assignments }
;;

let available_profiles () : string list = (compute ()).valid_profiles
let invalid_profiles () : (string * string list) list = (compute ()).invalid_profiles

let invalid_assignment_profiles () : (string * string list) list =
  (compute ()).invalid_assignments
;;
