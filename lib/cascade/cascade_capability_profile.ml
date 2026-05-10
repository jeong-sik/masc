(** RFC-0058: Declarative capability profile (v2).

    Replaces the closed variant with config-driven profile lookup via
    {!Cascade_capability_schema}.  Profiles are string-named; capability
    requirements live in the schema registry.

    Migration note: callers that previously used [profile] variant values
    now use string profile names directly.  [catalog_entry] stores
    [required_capability_profile] as [string option]. *)

let profile_to_string name = name

let profile_of_string name =
  if Cascade_capability_schema.is_known_profile name then Some name else None

let all_profiles =
  Cascade_capability_schema.all_profile_names

let provider_satisfies_profile name (caps : Provider_tool_support.capabilities) =
  match Cascade_capability_schema.resolve_profile name with
  | Some spec ->
      Cascade_capability_schema.provider_satisfies_required
        caps
        spec.required_capabilities
  | None -> false

let safe_lane_cascade_name = "__safe_lane"

let is_system_cascade_name name =
  String.length name >= 2 && String.sub name 0 2 = "__"
