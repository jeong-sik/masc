(** RFC-0058: Config-driven capability profile schema.

    Replaces the closed variant {!Cascade_capability_profile.profile}
    with string-based profile lookup.  Profiles are initially populated
    from builtin definitions (matching the previous variant behavior)
    and will be loadable from TOML in Phase 1.

    Capability names are strings that map to
    {!Provider_tool_support.capabilities} fields.  Unknown capability
    names are a config error (fail-closed). *)

type capability_level = Verified | Declared | Unsupported

type profile_spec = {
  required_capabilities : string list;
  provider_filter : string option;
}

let known_capability_fields : (string * (Provider_tool_support.capabilities -> bool)) list =
  [
    ( "inline_tools",
      fun caps -> caps.supports_inline_tools );
    ( "inline_tool_choice",
      fun caps -> caps.supports_inline_tool_choice );
    ( "runtime_mcp_tools",
      fun caps -> caps.supports_runtime_mcp_tools );
    ( "runtime_tool_events",
      fun caps -> caps.supports_runtime_tool_events );
    ( "runtime_mcp_http_headers",
      fun caps -> caps.supports_runtime_mcp_http_headers );
  ]

let capability_field_of_string name =
  match List.find_opt (fun (n, _) -> String.equal n name) known_capability_fields with
  | Some (_, getter) -> Ok getter
  | None ->
      Error
        (Printf.sprintf
           "unknown capability name %S (known: %s)"
           name
           (known_capability_fields
            |> List.map fst
            |> String.concat ", "))

let provider_satisfies_required caps required_names =
  List.for_all
    (fun name ->
       match capability_field_of_string name with
       | Ok getter -> getter caps
       | Error _ -> false)
    required_names

let builtin_profiles : (string * profile_spec) list =
  [
    ( "tool_strict",
      {
        required_capabilities =
          [ "runtime_mcp_tools"; "runtime_tool_events"; "runtime_mcp_http_headers" ];
        provider_filter = None;
      } );
    ( "inline_tools",
      {
        required_capabilities = [ "inline_tools"; "inline_tool_choice" ];
        provider_filter = None;
      } );
    ( "lite",
      {
        required_capabilities = [ "runtime_mcp_tools"; "runtime_tool_events" ];
        provider_filter = None;
      } );
    ( "local_inline",
      { required_capabilities = [ "inline_tools" ]; provider_filter = None } );
    ( "local",
      { required_capabilities = []; provider_filter = None } );
  ]

let resolve_profile name =
  List.find_map
    (fun (n, spec) ->
       if String.equal n name then Some spec else None)
    builtin_profiles

let all_profile_names =
  builtin_profiles |> List.map fst

let is_known_profile name =
  List.exists (fun (n, _) -> String.equal n name) builtin_profiles

let is_subset_profile src_name dst_name =
  match resolve_profile src_name, resolve_profile dst_name with
  | Some src, Some dst ->
      List.for_all
        (fun cap -> List.mem cap dst.required_capabilities)
        src.required_capabilities
  | _, _ -> false
