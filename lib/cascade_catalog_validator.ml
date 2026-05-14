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

type declarative_diagnostics = {
  snapshot : Cascade_declarative_hotpath.decl_snapshot option;
  parse_errors : Cascade_declarative_parser.parse_error list;
  adapter_errors : Cascade_declarative_adapter.adapter_error list;
}

let declarative_diagnostics_for_config_path config_path =
  match Cascade_declarative_parser.parse_file config_path with
  | Error errors -> { snapshot = None; parse_errors = errors; adapter_errors = [] }
  | Ok cfg ->
      let catalog = Cascade_declarative_adapter.adapt_config cfg in
      {
        snapshot =
          Cascade_declarative_hotpath.adapted_catalog_to_snapshot
            ~source_path:config_path catalog;
        parse_errors = [];
        adapter_errors = catalog.errors;
      }

let parse_error_issues ~config_path errors =
  errors
  |> List.map
       (fun (error : Cascade_declarative_parser.parse_error) ->
          Printf.sprintf "%s: %s" error.path error.message)
  |> List.sort_uniq String.compare
  |> List.map (fun message ->
         {
           profile = None;
           severity = Catalog_error;
           message =
             Printf.sprintf
               "Declarative cascade parse error in %s: %s"
               config_path message;
         })

let adapter_error_issues ~config_path errors =
  errors
  |> List.map Cascade_declarative_adapter.show_adapter_error
  |> List.sort_uniq String.compare
  |> List.map (fun message ->
         {
           profile = None;
           severity = Catalog_error;
           message =
             Printf.sprintf
               "Declarative cascade adapter error in %s: %s"
               config_path message;
         })

let assoc_opt key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let json_string_list_member key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`List values) ->
          List.filter_map
            (function
              | `String value ->
                  let value = String.trim value in
                  if String.equal value "" then None else Some value
              | _ -> None)
            values
      | _ -> [])
  | _ -> []

let profile_names_from_namespace ~prefix = function
  | Some (`Assoc fields) ->
    fields
    |> List.filter_map (fun (name, _value) ->
           let name = String.trim name in
           if String.equal name ""
           then None
           else Some (Printf.sprintf "%s.%s" prefix name))
  | _ -> []

let discover_profiles_from_materialized_json json =
  profile_names_from_namespace ~prefix:"tier" (assoc_opt "tier" json)
  @ profile_names_from_namespace ~prefix:"tier-group"
      (assoc_opt "tier-group" json)
  |> List.sort_uniq String.compare

let discover_profiles_impl ~emit_telemetry ~config_path =
  let load_catalog_source =
    if emit_telemetry
    then Cascade_config_loader.load_catalog_source
    else Cascade_config_loader.load_catalog_source_for_diagnostics
  in
  match load_catalog_source config_path with
  | Ok json -> discover_profiles_from_materialized_json json
  | Error _ -> []

let discover_profiles ~config_path =
  discover_profiles_impl ~emit_telemetry:true ~config_path

let discover_profiles_for_diagnostics ~config_path =
  discover_profiles_impl ~emit_telemetry:false ~config_path

let materialized_tier_members json tier_name =
  match
    Option.bind (assoc_opt "tier" json) (fun tiers_json ->
        assoc_opt tier_name tiers_json)
  with
  | Some tier_json -> json_string_list_member "members" tier_json
  | None -> []

let materialized_tier_group_tiers json group_name =
  match
    Option.bind (assoc_opt "tier-group" json) (fun groups_json ->
        assoc_opt group_name groups_json)
  with
  | Some group_json -> json_string_list_member "tiers" group_json
  | None -> []

let materialized_model_specs_for_profile json profile =
  let tier_group_prefix = "tier-group." in
  let tier_prefix = "tier." in
  if String.starts_with ~prefix:tier_group_prefix profile then
    let group_name =
      String.sub profile (String.length tier_group_prefix)
        (String.length profile - String.length tier_group_prefix)
    in
    materialized_tier_group_tiers json group_name
    |> List.concat_map (materialized_tier_members json)
  else if String.starts_with ~prefix:tier_prefix profile then
    let tier_name =
      String.sub profile (String.length tier_prefix)
        (String.length profile - String.length tier_prefix)
    in
    materialized_tier_members json tier_name
  else []

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

(* Catalog warn: a cascade carrying [codex_cli] with no
   bound-actor-tolerant fallback will reject every keeper-bound
   dispatch at runtime (oas_worker_named.ml:109).  Surface this at
   validation time so the operator sees it before each turn pays the
   cost.  Severity is [Catalog_warn] for now — the operator may have
   private cascade configs that legitimately omit bound-actor support
   (private operator-only profiles, for example offline scoring).  Strict-mode
   ([Catalog_error]) gating is left to a follow-up that knows which
   profiles are keeper-assignable. *)
let codex_with_bound_actor_only_issue ~profile model_specs =
  let module PK = Llm_provider.Provider_kind in
  let kinds =
    model_specs
    |> Cascade_config.expand_auto_models
    |> List.filter_map split_provider_model
    |> List.filter_map (fun (provider_name, _model_id) ->
           PK.of_string provider_name)
  in
  (* "Has any kind that needs per-keeper bridging?" — Codex CLI is the
     current canonical case; reading the capability flag keeps this
     check open for future adapters that share the cached-login quirk
     without rewriting the validator. RFC-0058 §2.4: capability, not match. *)
  let has_bridging_required_kind =
    List.exists
      Provider_adapter
      .requires_per_keeper_bridging_for_bound_actor_tools_for_kind
      kinds
  in
  (* The legacy whitelist hard-coded PK.Glm as tolerant, but
     [adapter_of_provider_kind PK.Glm = None] (Glm/OpenAI_compat have no
     single canonical adapter), so the capability-driven helper returns
     [false] for it.  This is intentional: GLM has no CLI surface today and
     therefore no per-keeper bound-actor auth path. If and when one lands,
     the corresponding adapter's [tolerates_bound_actor_fallback] capability
     becomes the SSOT — no validator edit required.
     RFC-0058 §2.4: capability flag, not a vendor match. *)
  let has_bound_actor_tolerant_fallback =
    List.exists
      Provider_adapter.tolerates_bound_actor_fallback_for_kind
      kinds
  in
  if has_bridging_required_kind && not has_bound_actor_tolerant_fallback then
    Some
      {
        profile = Some profile;
        severity = Catalog_warn;
        message =
          Printf.sprintf
            "Cascade preset %s carries codex_cli with no \
             bound-actor-tolerant fallback \
             (claude_code|gemini_cli|kimi_cli|ollama|glm). codex_cli \
             cannot route keeper-bound runtime MCP tools (masc_*, \
             decision.*); every keeper-bound dispatch on this preset \
             will be rejected at oas_worker_named.ml. Add at least \
             one tolerant provider or remove codex_cli."
            profile;
      }
  else None

(* RFC-0027 PR-3: capability lint severity is operator-controlled via
   MASC_CAPABILITY_LINT.  Default [warn] keeps rollout safe — operators
   see drift in logs without breaking startup until they explicitly opt
   in to enforcement.  [off] is provided so emergency operators can
   silence the lint without removing the [required_capability_profile]
   field. *)
let capability_lint_severity () : severity option =
  match Sys.getenv_opt "MASC_CAPABILITY_LINT" with
  | Some "off" -> None
  | Some "error" -> Some Catalog_error
  | _ -> Some Catalog_warn

let capability_mismatch_issues ~profile ~required_profile model_specs =
  match capability_lint_severity () with
  | None -> []
  | Some severity ->
      let mismatches =
        model_specs
        |> Cascade_config.expand_auto_models
        |> List.filter_map (fun spec ->
               match Cascade_config.parse_model_string_result spec with
               | Ok cfg ->
                   let caps = Provider_tool_support.capabilities_of_config cfg in
                   if Cascade_capability_profile.provider_satisfies_named_profile
                        required_profile caps
                   then None
                   else Some spec
               | Error _ -> None)
      in
      if mismatches = [] then []
      else
        [
          {
            profile = Some profile;
            severity;
            message =
              Printf.sprintf
                "Cascade preset %s declares required_capability_profile=%S \
                 but %d model(s) do not satisfy it: %s"
                profile
                required_profile
                (List.length mismatches)
                (String.concat ", " mismatches);
          };
        ]

let snapshot_profile_for ~config_path ~profile =
  match Cascade_catalog_runtime.inspect_active () with
  | Error _ -> None
  | Ok state ->
    let snap_opt =
      match state with
      | Cascade_catalog_runtime.Validated snapshot -> Some snapshot
      | Validated_with_rejections { snapshot; _ } -> Some snapshot
      | Serving_last_known_good { snapshot; _ } -> Some snapshot
    in
    (match snap_opt with
     | Some snapshot when String.equal snapshot.source_path config_path ->
       List.find_opt
         (fun (p : Cascade_catalog_runtime.profile_build) ->
           String.equal p.name profile)
         snapshot.profiles
     | _ -> None)

let runtime_profile_of_declarative_profile
    (p : Cascade_declarative_hotpath.profile) =
  let candidates =
    List.map
      (fun (candidate : Cascade_declarative_hotpath.candidate) ->
         { Cascade_catalog_runtime.model_string = candidate.model_string
         ; provider_cfg = candidate.provider_cfg
         })
      p.candidates
  in
  { Cascade_catalog_runtime.name = p.name
  ; weighted_entries = p.weighted_entries
  ; inference_params = p.inference_params
  ; api_key_env_overrides = []
  ; strategy = p.strategy
  ; ollama_max_concurrent = p.ollama_max_concurrent
  ; cli_max_concurrent = p.cli_max_concurrent
  ; candidates
  ; probes = []
  ; required_capability_profile = None
  }

let profile_from_declarative_snapshot snapshot ~profile =
  List.find_opt
    (fun (p : Cascade_declarative_hotpath.profile) ->
       String.equal p.name profile)
    snapshot.Cascade_declarative_hotpath.profiles
  |> Option.map runtime_profile_of_declarative_profile

let diagnose_profile ~materialized_json ~declarative_snapshot ~emit_telemetry
    ~config_path ~profile =
  let (_ : bool) = emit_telemetry in
  let snapshot_profile =
    match snapshot_profile_for ~config_path ~profile with
    | Some _ as value -> value
    | None ->
      (match declarative_snapshot with
       | Some snapshot -> profile_from_declarative_snapshot snapshot ~profile
       | None ->
           let diagnostics = declarative_diagnostics_for_config_path config_path in
           Option.bind diagnostics.snapshot (fun snapshot ->
             profile_from_declarative_snapshot snapshot ~profile))
  in
  let model_specs =
    match snapshot_profile with
    | Some (p : Cascade_catalog_runtime.profile_build) ->
      List.map
        (fun (entry : Cascade_config_loader.weighted_entry) -> entry.model)
        p.weighted_entries
    | None -> materialized_model_specs_for_profile materialized_json profile
  in
  let candidate_model_strings =
    match snapshot_profile with
    | Some (p : Cascade_catalog_runtime.profile_build) ->
      List.map
        (fun (candidate : Cascade_catalog_runtime.candidate_runtime) ->
          candidate.model_string)
        p.candidates
    | None -> []
  in
  let required_profile_opt =
    match snapshot_profile with
    | Some (p : Cascade_catalog_runtime.profile_build) ->
      p.required_capability_profile
    | None -> None
  in
  let capability_issues =
    match required_profile_opt with
    | None -> []
    | Some required_profile ->
        capability_mismatch_issues ~profile ~required_profile model_specs
  in
  let invalid_specs =
    model_specs
    |> Cascade_config.expand_auto_models
    |> List.filter_map (fun spec ->
           match Cascade_config.parse_model_string_result spec with
           | Ok _ -> None
           | Error msg when is_provider_unavailable_error msg -> None
           (* Declarative provider bindings can materialize to runtime-only
              provider keys that are already represented by validated
              provider_cfg candidates. Do not reclassify those as invalid. *)
           | Error _
             when List.exists (String.equal spec) candidate_model_strings ->
               None
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
  let bound_actor_issue =
    codex_with_bound_actor_only_issue ~profile model_specs
  in
  let issues =
    [ invalid_model_issue; bound_actor_issue ]
    |> List.filter_map (fun issue -> issue)
  in
  issues @ capability_issues

let diagnose_catalog_impl ~emit_telemetry ~config_path =
  let load_catalog_source =
    if emit_telemetry
    then Cascade_config_loader.load_catalog_source
    else Cascade_config_loader.load_catalog_source_for_diagnostics
  in
  match load_catalog_source config_path with
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
      let declarative_diagnostics =
        declarative_diagnostics_for_config_path config_path
      in
      let profile_issues =
        discover_profiles_from_materialized_json json
        |> List.concat_map (fun profile ->
          diagnose_profile
            ~materialized_json:json
            ~declarative_snapshot:declarative_diagnostics.snapshot
            ~emit_telemetry ~config_path ~profile)
      in
      parse_error_issues ~config_path declarative_diagnostics.parse_errors
      @
      adapter_error_issues
        ~config_path declarative_diagnostics.adapter_errors
      @ profile_issues

let diagnose_catalog ~config_path =
  diagnose_catalog_impl ~emit_telemetry:true ~config_path

let diagnose_catalog_for_diagnostics ~config_path =
  diagnose_catalog_impl ~emit_telemetry:false ~config_path

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
