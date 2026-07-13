open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_supervisor_types

let keep_last_n n item lst =
  let full = item :: lst in
  if List.length full <= n then full else List.filteri (fun i _ -> i < n) full
;;

let persona_name_for_drift_check (meta : keeper_meta) =
  match Keeper_types_profile.load_keeper_profile_defaults_result meta.name with
  | Ok defaults ->
    Ok (Keeper_types_profile.resolved_persona_name ~keeper_name:meta.name defaults)
  | Error error -> Error error
;;

let persona_profile_path_for_drift_check ~base_path persona_name =
  match Config_dir_resolver.personas_dir_opt () with
  | Some dir -> Filename.concat (Filename.concat dir persona_name) "profile.json"
  | None ->
    Filename.concat
      (Filename.concat
         (Filename.concat (Common.masc_dir_from_base_path ~base_path) "personas")
         persona_name)
      "profile.json"
;;

let log_persona_drift_if_missing ~base_path (meta : keeper_meta) =
  match persona_name_for_drift_check meta with
  | Error error ->
    Log.Keeper.error
      "[#10993][persona_drift] keeper=%s config invalid; drift path not projected: \
       %s"
      meta.name
      (keeper_toml_load_error_to_string error)
  | Ok persona_name ->
    let searched = persona_profile_path_for_drift_check ~base_path persona_name in
    if Sys.file_exists searched
    then ()
    else (
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string PersonaDriftMissing)
        ~labels:[ "keeper", meta.name ]
        ();
      let msg =
        Printf.sprintf
          "[#10993][persona_drift] keeper=%s resolved=%s persona profile missing at %s"
          meta.name
          persona_name
          searched
      in
      match persona_drift_log_level_for_missing_profile meta with
      | Persona_drift_warn ->
        Log.Keeper.warn
          "%s — using keeper TOML metadata; operator action: add persona profile if \
           persona assets are required"
          msg
      | Persona_drift_error ->
        Log.Keeper.error
          "%s — runtime falls through to logging-only RFC P3-a path; operator action: \
           create persona profile or remove keeper from registry"
          msg)
;;
