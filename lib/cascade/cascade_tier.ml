(* RFC-0055: Capability-tier monotonicity for cascade fallback chains.
   RFC-0058: String-based profile resolution (built-in + TOML-declared).

   A fallback edge source -> target is valid only if the target's
   capability profile is a superset of the source's profile.  This
   module provides the subset check used at config-load time.

   v2: Delegates to {!Cascade_capability_schema.is_subset_profile}
   for string-based profile comparison. *)

open Cascade_capability_profile

let is_subset_profile src_name dst_name =
  Cascade_capability_schema.is_subset_profile src_name dst_name

(* Support for TOML-declared profiles (RFC-0058 Phase 1). *)
let requirement_leq a b =
  match a, b with
  | Optional, _ -> true
  | Required, Required -> true
  | Required, Optional -> false

let is_subset_caps (s : required_capabilities) (d : required_capabilities) =
  requirement_leq s.inline_tools d.inline_tools
  && requirement_leq s.inline_tool_choice d.inline_tool_choice
  && requirement_leq s.runtime_mcp_tools d.runtime_mcp_tools
  && requirement_leq s.runtime_tool_events d.runtime_tool_events
  && requirement_leq s.runtime_mcp_http_headers d.runtime_mcp_http_headers

let is_subset_named_profile src_name dst_name =
  match
    ( resolve_required_capabilities src_name,
      resolve_required_capabilities dst_name )
  with
  | Some s, Some d -> is_subset_caps s d
  | _ -> false
