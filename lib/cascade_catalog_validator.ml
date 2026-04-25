type severity =
  | Catalog_warn
  | Catalog_error

type issue = {
  profile : string option;
  severity : severity;
  message : string;
}

module StringMap = Map.Make (String)

let contains_substring ~needle s =
  (* Empty needle returns false here, distinct from String_util.contains_substring's
     Re-compatible empty=true.  Guard preserves the original validator contract. *)
  String.length needle > 0 && String_util.contains_substring s needle

let has_suffix ~suffix s =
  (* Original strict-greater length: rejects [s = suffix] case where the
     entire string is the suffix.  String.ends_with admits equality, so
     guard preserves the prior validator contract. *)
  String.length s > String.length suffix && String.ends_with ~suffix s

let is_provider_unavailable_error msg =
  contains_substring ~needle:"unavailable" msg

let split_provider_model (s : string) : (string * string) option =
  match String.index_opt s ':' with
  | None -> None
  | Some idx ->
      if idx = 0 || idx >= String.length s - 1 then
        None
      else
        let provider_name =
          String.sub s 0 idx |> String.trim |> String.lowercase_ascii
        in
        let model_id =
          String.sub s (idx + 1) (String.length s - idx - 1)
          |> String.trim
        in
        if model_id = "" then None else Some (provider_name, model_id)

let discover_profiles_in_json = function
  | `Assoc fields ->
      fields
      |> List.filter_map (fun (key, value) ->
             match value with
             | `List _ when has_suffix ~suffix:"_models" key ->
                 let suffix_len = String.length "_models" in
                 Some (String.sub key 0 (String.length key - suffix_len))
             | _ -> None)
      |> List.sort_uniq String.compare
  | _ -> []

let discover_profiles ~config_path =
  match Cascade_config_loader.load_json config_path with
  | Ok json -> discover_profiles_in_json json
  | Error _ -> []

let model_ids_of_specs (specs : string list) : string list =
  specs
  |> Cascade_config.expand_auto_models
  |> List.filter_map (fun spec ->
         match split_provider_model spec with
         | Some (_, model_id) when model_id <> "" -> Some model_id
         | _ -> None)
  |> List.sort_uniq String.compare

let format_spec_errors specs =
  specs
  |> List.map (fun (spec, msg) -> Printf.sprintf "%S (%s)" spec msg)
  |> String.concat ", "

let priority_tier_issue ~profile configured_specs raw_tiers =
  let configured_model_ids = model_ids_of_specs configured_specs in
  if configured_model_ids = [] then
    Some
      {
        profile = Some profile;
        severity = Catalog_error;
        message =
          Printf.sprintf
            "Cascade preset %s uses priority_tier but has no configured \
             models to validate."
            profile;
      }
  else
    let normalized =
      raw_tiers
      |> List.filter_map (fun tier ->
             let tier_model_ids =
               model_ids_of_specs tier
               |> List.filter (fun model_id ->
                      List.mem model_id configured_model_ids)
             in
             if tier_model_ids = [] then None else Some tier_model_ids)
    in
    if normalized = [] then
      Some
        {
          profile = Some profile;
          severity = Catalog_error;
          message =
            Printf.sprintf
              "Cascade preset %s uses priority_tier, but every tier \
               collapses after model-id normalization; runtime will fall \
               back to failover."
              profile;
        }
    else if List.length normalized < List.length raw_tiers then
      Some
        {
          profile = Some profile;
          severity = Catalog_warn;
          message =
            Printf.sprintf
              "Cascade preset %s uses priority_tier, but %d/%d tier(s) \
               collapse after model-id normalization."
              profile
              (List.length raw_tiers - List.length normalized)
              (List.length raw_tiers);
        }
    else
      None

let diagnose_profile ~config_path ~profile =
  let model_specs =
    Cascade_config_loader.load_profile_weighted ~config_path ~name:profile
    |> List.map (fun (entry : Cascade_config_loader.weighted_entry) ->
           entry.model)
  in
  let invalid_specs =
    model_specs
    |> Cascade_config.expand_auto_models
    |> List.filter_map (fun spec ->
           match Cascade_config.parse_model_string_result spec with
           | Ok _ -> None
           | Error msg when is_provider_unavailable_error msg -> None
           | Error msg -> Some (spec, msg))
  in
  let invalid_model_issue =
    if invalid_specs = [] then
      None
    else
      Some
        {
          profile = Some profile;
          severity = Catalog_error;
          message =
            Printf.sprintf
              "Cascade preset %s has %d hard-invalid model spec(s): %s"
              profile
              (List.length invalid_specs)
              (format_spec_errors invalid_specs);
        }
  in
  let strategy_cfg =
    Cascade_config_loader.resolve_strategy_config ~config_path ~name:profile
  in
  let strategy_issue =
    match strategy_cfg.kind with
    | None -> None
    | Some raw_kind -> (
        match Cascade_strategy.parse_kind raw_kind with
        | Error msg ->
            Some
              {
                profile = Some profile;
                severity = Catalog_error;
                message =
                  Printf.sprintf
                    "Cascade preset %s has unknown strategy %S: %s"
                    profile raw_kind msg;
              }
        | Ok Cascade_strategy.Priority_tier -> (
            match strategy_cfg.tiers with
            | None ->
                Some
                  {
                    profile = Some profile;
                    severity = Catalog_error;
                    message =
                      Printf.sprintf
                        "Cascade preset %s uses priority_tier without a \
                         valid non-empty <name>_tiers configuration."
                        profile;
                  }
            | Some raw_tiers ->
                priority_tier_issue ~profile model_specs raw_tiers)
        | Ok _ -> None)
  in
  [ invalid_model_issue; strategy_issue ]
  |> List.filter_map (fun issue -> issue)

let diagnose_catalog ~config_path =
  match Cascade_config_loader.load_json config_path with
  | Error msg ->
      [
        {
          profile = None;
          severity = Catalog_error;
          message =
            Printf.sprintf
              "Cascade catalog %s could not be loaded: %s"
              config_path msg;
        };
      ]
  | Ok json ->
      discover_profiles_in_json json
      |> List.concat_map (fun profile -> diagnose_profile ~config_path ~profile)

let dedupe_keep_order values =
  let seen = Hashtbl.create (List.length values) in
  List.filter
    (fun value ->
      if value = "" || Hashtbl.mem seen value then
        false
      else (
        Hashtbl.replace seen value ();
        true))
    values

let error_messages_by_profile ~config_path =
  diagnose_catalog ~config_path
  |> List.fold_left
       (fun acc (issue : issue) ->
          match issue.profile, issue.severity with
          | Some profile, Catalog_error ->
              let prior =
                match StringMap.find_opt profile acc with
                | Some messages -> messages
                | None -> []
              in
              StringMap.add profile (prior @ [ issue.message ]) acc
          | _ -> acc)
       StringMap.empty
  |> StringMap.bindings
  |> List.map (fun (profile, messages) ->
         (profile, dedupe_keep_order messages))
